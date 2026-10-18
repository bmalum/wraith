// Journal: the safehouse's durable memory.
//
// A MicroVM's disk dies with it (Close, the 8 h lifetime, a crash). Everything
// the operatives must not forget lives in two places — $HOME/.kiro (KAS
// sessions, memories.db, settings) and /work — and is shipped to S3 as two
// tarballs under companies/<company_id>/, restored in /run before KAS starts,
// written on /suspend, /terminate and a debounced timer while things change.
//
// Credentials come from the MicroVM execution role; we discover them the way
// an SDK would (env vars → container credentials endpoint → IMDS) and sign
// requests ourselves (SigV4) so the image needs no SDK or CLI.

import { createHash, createHmac } from "node:crypto";
import { statSync, existsSync } from "node:fs";

export type JournalConfig = { bucket: string; prefix: string; region: string };

type Creds = { accessKeyId: string; secretAccessKey: string; sessionToken?: string; expiration?: string; source: string };

let cached: Creds | null = null;

export async function credentials(): Promise<Creds> {
  if (cached && (!cached.expiration || Date.parse(cached.expiration) - Date.now() > 5 * 60_000)) return cached;
  const env = process.env;
  if (env.AWS_ACCESS_KEY_ID && env.AWS_SECRET_ACCESS_KEY) {
    return (cached = {
      accessKeyId: env.AWS_ACCESS_KEY_ID,
      secretAccessKey: env.AWS_SECRET_ACCESS_KEY,
      sessionToken: env.AWS_SESSION_TOKEN,
      source: "env",
    });
  }
  const url =
    env.AWS_CONTAINER_CREDENTIALS_FULL_URI ??
    (env.AWS_CONTAINER_CREDENTIALS_RELATIVE_URI ? `http://169.254.170.2${env.AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}` : null);
  if (url) {
    const headers: Record<string, string> = {};
    if (env.AWS_CONTAINER_AUTHORIZATION_TOKEN) headers.Authorization = env.AWS_CONTAINER_AUTHORIZATION_TOKEN;
    else if (env.AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE) headers.Authorization = (await Bun.file(env.AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE).text()).trim();
    const r = await fetch(url, { headers, signal: AbortSignal.timeout(3000) });
    if (!r.ok) throw new Error(`container credentials ${r.status}`);
    const j = (await r.json()) as any;
    return (cached = {
      accessKeyId: j.AccessKeyId,
      secretAccessKey: j.SecretAccessKey,
      sessionToken: j.Token,
      expiration: j.Expiration,
      source: "container-endpoint",
    });
  }
  // IMDSv2
  try {
    const tok = await fetch("http://169.254.169.254/latest/api/token", {
      method: "PUT",
      headers: { "X-aws-ec2-metadata-token-ttl-seconds": "300" },
      signal: AbortSignal.timeout(1500),
    }).then((r) => r.text());
    const h = { "X-aws-ec2-metadata-token": tok };
    const role = await fetch("http://169.254.169.254/latest/meta-data/iam/security-credentials/", { headers: h, signal: AbortSignal.timeout(1500) }).then((r) => r.text());
    const j = (await fetch(`http://169.254.169.254/latest/meta-data/iam/security-credentials/${role.trim()}`, { headers: h, signal: AbortSignal.timeout(1500) }).then((r) => r.json())) as any;
    return (cached = { accessKeyId: j.AccessKeyId, secretAccessKey: j.SecretAccessKey, sessionToken: j.Token, expiration: j.Expiration, source: "imds" });
  } catch (e) {
    throw new Error(`no AWS credentials found (env, container endpoint, IMDS): ${(e as Error).message}`);
  }
}

// ---------------------------------------------------------------- SigV4 (S3)

const sha256 = (d: string | Uint8Array) => createHash("sha256").update(d).digest("hex");
const hmac = (k: Uint8Array | string, d: string) => createHmac("sha256", k).update(d).digest();

async function s3(cfg: JournalConfig, method: "GET" | "PUT" | "HEAD", key: string, body?: Uint8Array): Promise<Response> {
  const c = await credentials();
  const host = `${cfg.bucket}.s3.${cfg.region}.amazonaws.com`;
  const path = "/" + key.split("/").map(encodeURIComponent).join("/");
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, "");
  const date = amzDate.slice(0, 8);
  const payloadHash = body ? sha256(body) : sha256("");
  const headers: Record<string, string> = {
    host,
    "x-amz-content-sha256": payloadHash,
    "x-amz-date": amzDate,
  };
  if (c.sessionToken) headers["x-amz-security-token"] = c.sessionToken;
  if (body) headers["content-type"] = "application/gzip";
  const signedHeaders = Object.keys(headers).sort();
  const canonical = [
    method,
    path,
    "",
    ...signedHeaders.map((h) => `${h}:${headers[h].trim()}`),
    "",
    signedHeaders.join(";"),
    payloadHash,
  ].join("\n");
  const scope = `${date}/${cfg.region}/s3/aws4_request`;
  const toSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256(canonical)].join("\n");
  const kSigning = hmac(hmac(hmac(hmac(`AWS4${c.secretAccessKey}`, date), cfg.region), "s3"), "aws4_request");
  const signature = createHmac("sha256", kSigning).update(toSign).digest("hex");
  headers.authorization = `AWS4-HMAC-SHA256 Credential=${c.accessKeyId}/${scope}, SignedHeaders=${signedHeaders.join(";")}, Signature=${signature}`;
  delete headers.host;
  return fetch(`https://${host}${path}`, { method, headers, body: body as any, signal: AbortSignal.timeout(50_000) });
}

// ---------------------------------------------------------------- tarballs

export type Volume = { name: string; dir: string; excludes: string[]; maxBytes: number };

export const VOLUMES: Volume[] = [
  // sessions, memories.db, settings — the operatives' minds
  { name: "home", dir: process.env.OPERATIVE_HOME ?? "/home/operative", excludes: [".kiro/logs", ".cache", ".bun", ".npm"], maxBytes: 200 * 1024 * 1024 },
  // the safehouse desk — a git repository (KAS scopes SEMANTIC memories to a
  // repo), shipped whole: dropping .git/objects would restore a broken repo.
  // Build output and dependency caches are left behind.
  { name: "work", dir: process.env.WORK_DIR ?? "/work", excludes: ["node_modules", "_build", "deps", ".venv", "target"], maxBytes: 200 * 1024 * 1024 },
];

const stamps = new Map<string, string>(); // volume → sha256 of last shipped tarball

async function pack(v: Volume): Promise<Uint8Array | null> {
  if (!existsSync(v.dir)) return null;
  const ex = v.excludes.flatMap((e) => ["--exclude", `./${e}`]);
  const out = await Bun.$`tar -C ${v.dir} ${ex} -czf - .`.quiet().arrayBuffer();
  const bytes = new Uint8Array(out);
  if (bytes.byteLength > v.maxBytes) throw new Error(`${v.name}: ${bytes.byteLength} bytes exceeds cap ${v.maxBytes}`);
  return bytes;
}

export async function ship(cfg: JournalConfig, log: (l: string) => void, reason: string): Promise<void> {
  for (const v of VOLUMES) {
    try {
      const bytes = await pack(v);
      if (!bytes) continue;
      const digest = sha256(bytes);
      if (stamps.get(v.name) === digest) continue; // unchanged since last ship
      const r = await s3(cfg, "PUT", `${cfg.prefix}/${v.name}.tar.gz`, bytes);
      if (!r.ok) throw new Error(`PUT ${r.status} ${(await r.text()).slice(0, 200)}`);
      stamps.set(v.name, digest);
      log(`journal: shipped ${v.name} (${(bytes.byteLength / 1024).toFixed(0)} KB, ${reason})`);
    } catch (e) {
      log(`journal: ship ${v.name} failed: ${(e as Error).message}`);
    }
  }
}

export async function restore(cfg: JournalConfig, log: (l: string) => void): Promise<void> {
  for (const v of VOLUMES) {
    try {
      const r = await s3(cfg, "GET", `${cfg.prefix}/${v.name}.tar.gz`);
      if (r.status === 404) {
        log(`journal: no ${v.name} on file — fresh start`);
        continue;
      }
      if (!r.ok) throw new Error(`GET ${r.status} ${(await r.text()).slice(0, 200)}`);
      const bytes = new Uint8Array(await r.arrayBuffer());
      await Bun.$`mkdir -p ${v.dir}`.quiet();
      await Bun.$`tar -C ${v.dir} -xzf - < ${new Response(bytes)}`.quiet();
      stamps.set(v.name, sha256(bytes));
      log(`journal: restored ${v.name} (${(bytes.byteLength / 1024).toFixed(0)} KB)`);
    } catch (e) {
      log(`journal: restore ${v.name} failed: ${(e as Error).message}`);
    }
  }
}

/** Newest mtime under the volumes (cheap change detector for the timer). */
export function newestMtime(): number {
  let newest = 0;
  for (const v of VOLUMES) {
    if (!existsSync(v.dir)) continue;
    try {
      const out = Bun.spawnSync(["sh", "-c", `find ${v.dir} ${v.excludes.map((e) => `-path '${v.dir}/${e}' -prune -o`).join(" ")} -type f -printf '%T@\\n' 2>/dev/null | sort -rn | head -1`]);
      const t = parseFloat(out.stdout.toString().trim() || "0");
      if (t > newest) newest = t;
    } catch {}
  }
  return newest;
}

export async function describeCredentials(): Promise<string> {
  try {
    const c = await credentials();
    return `${c.source} (${c.accessKeyId.slice(0, 4)}…, expires ${c.expiration ?? "n/a"})`;
  } catch (e) {
    return `none: ${(e as Error).message}`;
  }
}

export function fileSize(p: string): number {
  try {
    return statSync(p).size;
  } catch {
    return -1;
  }
}
