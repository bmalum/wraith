// Wraith studio shim — runs inside a Lambda MicroVM (ported from shadow_corp).
//
// Three jobs:
//   1. Answer the Lambda MicroVM lifecycle hooks on :8080
//      (/aws/lambda-microvms/runtime/v1/{ready,validate,run,suspend,resume,terminate}).
//   2. Supervise the Kiro Agent Server (KAS) on :8082 (ACP over WebSocket) and
//      keep a ring buffer of its stdout/stderr so the Director can see inside.
//   3. Bridge KAS's MCP calls to the company tools (127.0.0.1:8090) over the
//      /bridge WebSocket Phoenix opens (bridge.ts).
//
// Everything Phoenix talks to goes through the MicroVM's HTTPS endpoint:
//   X-aws-proxy-port: 8080 → this shim   (GET /health, GET /log, wss /bridge)
//   X-aws-proxy-port: 8082 → KAS         (wss, ACP JSON-RPC)
//
// Auth: over the WS transport every ACP client is an *observer*; KAS only asks
// the *primary* (stdio) client for tokens, so `--auth=acp-callback` cannot work
// here. The credential must live in the VM: either KIRO_API_KEY (an operative's
// own key, TokenType API_KEY) or a Kiro sign-in token file that KAS refreshes
// itself. Both arrive in the /run hook payload; KAS is (re)started with them.

import { existsSync, readFileSync } from "node:fs";
import { ship, restore, newestMtime, describeCredentials, type JournalConfig } from "./journal.ts";
import { bridgeBinding, bridgeHello, bridgeState, bridgeWebSocket, startMcpServer, upgradeBridge } from "./bridge.ts";
import { bindCaller } from "./caller.ts";

const HOOK_PREFIX = "/aws/lambda-microvms/runtime/v1";
const KAS_PORT = Number(process.env.ACP_WS_PORT ?? "8082");
const KAS_ENTRY =
  process.env.KAS_ENTRY ??
  "/opt/kas/node_modules/@kiro/agent/dist/server/acp-server.js";
const WORK_DIR = process.env.WORK_DIR ?? "/work";
const HOME_DIR = process.env.OPERATIVE_HOME ?? "/home/operative";
const LOG_LINES = 2000;

type RunPayload = {
  operative_id?: string;
  company_id?: string;
  company?: string;
  repo_url?: string;
  branch?: string;
  /**
   * S3 journal. Prefix defaults to companies/<company_id> — the company's one
   * shared memory. A detached "field op" VM must pass its own `prefix`
   * (e.g. fieldops/<op_id>) so it never writes over the company journal.
   */
  journal?: { bucket: string; region: string; prefix?: string };
  /** Binds the bridge to the house that started the VM (see bridge.ts). Never written to disk. */
  bridge_key?: string;
  /** Operative's own Kiro API key (ksk_…). Preferred. */
  kiro_api_key?: string;
  /** Dev fallback: a Kiro sign-in token file + its client registration. */
  kiro_token?: { token: Record<string, unknown>; registration?: Record<string, unknown> };
};

type KasAuth = { kind: "none" } | { kind: "api-key"; apiKey: string } | { kind: "token-file" };

// The KAS bundle this image was built from (microvm/KAS_VERSION, copied by build.sh).
const KAS_BUNDLE = (() => {
  try {
    return readFileSync("/opt/kas/VERSION", "utf8").trim() || "unknown";
  } catch {
    return "unknown";
  }
})();

bridgeHello.kas_bundle = KAS_BUNDLE;

const state = {
  booted_at: new Date().toISOString(),
  kas_bundle: KAS_BUNDLE,
  microvm_id: null as string | null,
  payload: null as Omit<RunPayload, "kiro_api_key"> | null,
  kas: { pid: null as number | null, restarts: 0, auth: "none" as string },
  journal: null as null | { bucket: string; prefix: string; last_ship: string | null; credentials: string },
  events: [] as { at: string; event: string; detail?: unknown }[],
};

const log: string[] = [];
function push(line: string) {
  log.push(`${new Date().toISOString()} ${line}`);
  if (log.length > LOG_LINES) log.splice(0, log.length - LOG_LINES);
}
function event(name: string, detail?: unknown) {
  state.events.push({ at: new Date().toISOString(), event: name, detail });
  if (state.events.length > 200) state.events.shift();
  push(`[shim] ${name}${detail ? " " + JSON.stringify(detail) : ""}`);
}

// ---------------------------------------------------------------- KAS supervisor

let kas: ReturnType<typeof Bun.spawn> | null = null;
let kasEnv: Record<string, string> = {};
let stopping = false;

function pipe(stream: ReadableStream<Uint8Array> | null, tag: string) {
  if (!stream) return;
  (async () => {
    const reader = stream.getReader();
    const dec = new TextDecoder();
    let buf = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        push(`[${tag}] ${buf.slice(0, i)}`);
        buf = buf.slice(i + 1);
      }
    }
    if (buf) push(`[${tag}] ${buf}`);
  })();
}

let currentAuth: KasAuth = { kind: "none" };

function startKas(auth: KasAuth = currentAuth) {
  stopping = false;
  currentAuth = auth;
  kasEnv = {
    ...process.env,
    HOME: HOME_DIR,
    ACP_WS_PORT: String(KAS_PORT),
    KIRO_CLI: "wraith",
    KIRO_LOG_LEVEL: process.env.KIRO_LOG_LEVEL ?? "info",
    KIRO_CUSTOM_USER_AGENT: "WraithStudio/0.1",
    ...(auth.kind === "api-key" ? { KIRO_API_KEY: auth.apiKey } : {}),
  };
  delete (kasEnv as Record<string, unknown>).KAS_ENTRY;
  const args = [
    "bun",
    KAS_ENTRY,
    "--transport=ws",
    "--sandbox=none",
    `--home-dir=${HOME_DIR}`,
    // "none": no credential yet (image build / validate) — initialize still
    // works, prompts would fail. "api-key": env var wins over --auth.
    // "token-file": default --auth=user reads $HOME/.aws/sso/cache/kiro-auth-token.json.
    ...(auth.kind === "none" ? ["--auth=acp-callback"] : ["--auth=user"]),
  ];
  kas = Bun.spawn(args, {
    cwd: WORK_DIR,
    env: kasEnv,
    stdout: "pipe",
    stderr: "pipe",
  });
  state.kas.pid = kas.pid;
  state.kas.auth = auth.kind;
  // only this process may call the bridge (caller.ts)
  bindCaller(kas.pid);
  event("kas.start", { pid: kas.pid, auth: auth.kind });
  pipe(kas.stdout as ReadableStream<Uint8Array>, "kas");
  pipe(kas.stderr as ReadableStream<Uint8Array>, "kas!");
  kas.exited.then((code) => {
    event("kas.exit", { code });
    state.kas.pid = null;
    bindCaller(null);
    if (!stopping) {
      state.kas.restarts += 1;
      setTimeout(() => startKas(auth), Math.min(1000 * state.kas.restarts, 10_000));
    }
  });
}

// /work is the company's desk: a git repository, so operatives can commit
// durable work and KAS can scope SEMANTIC memories to it. Created once; a
// restored journal brings the existing repo back.
//
// KAS derives a repository's memory scope from its `origin` remote, so the
// desk gets a stable, company-specific one (it is never pushed to): SEMANTIC
// memories then survive VM replacement and stay with the company.
async function ensureDesk(company: string, companyId?: string) {
  const git = (args: string[]) => Bun.$`git -C ${WORK_DIR} ${args}`.quiet().nothrow();
  const origin = `https://studio.wraith.invalid/companies/${companyId ?? "unknown"}.git`;
  if (existsSync(`${WORK_DIR}/.git`)) {
    const has = await git(["remote", "get-url", "origin"]);
    if (has.exitCode !== 0) await git(["remote", "add", "origin", origin]);
    return;
  }
  await git(["init", "-q", "-b", "main"]);
  await git(["config", "user.name", "Wraith studio"]);
  await git(["config", "user.email", "studio@wraith.invalid"]);
  await Bun.write(`${WORK_DIR}/.gitignore`, ".wraith.json\nnode_modules/\n_build/\ndeps/\n");
  await Bun.write(`${WORK_DIR}/README.md`, `# ${company}\n\nThe safehouse desk. Operatives keep durable work here.\n`);
  await git(["add", "-A"]);
  await git(["commit", "-q", "-m", "Open the safehouse desk"]);
  await git(["remote", "add", "origin", origin]);
  event("desk.created", { company, origin });
}

async function installTokenFile(t: NonNullable<RunPayload["kiro_token"]>) {
  const dir = `${HOME_DIR}/.aws/sso/cache`;
  await Bun.$`mkdir -p ${dir}`.quiet();
  await Bun.write(`${dir}/kiro-auth-token.json`, JSON.stringify(t.token));
  const hash = (t.token as { clientIdHash?: string }).clientIdHash;
  if (t.registration && hash) await Bun.write(`${dir}/${hash}.json`, JSON.stringify(t.registration));
  await Bun.$`chmod 600 ${dir}/*.json`.quiet();
}

async function stopKas() {
  if (!kas) return;
  stopping = true;
  const p = kas;
  kas = null;
  p.kill("SIGTERM");
  await Promise.race([p.exited, Bun.sleep(3000)]);
  if (p.exitCode === null) p.kill("SIGKILL");
}

// Probe KAS by completing an ACP `initialize` round-trip.
async function kasReady(timeoutMs = 2500): Promise<boolean> {
  return new Promise((resolve) => {
    let done = false;
    const finish = (ok: boolean) => {
      if (done) return;
      done = true;
      try {
        ws.close();
      } catch {}
      resolve(ok);
    };
    const t = setTimeout(() => finish(false), timeoutMs);
    let ws: WebSocket;
    try {
      ws = new WebSocket(`ws://127.0.0.1:${KAS_PORT}`);
    } catch {
      clearTimeout(t);
      return resolve(false);
    }
    ws.onopen = () =>
      ws.send(
        JSON.stringify({
          jsonrpc: "2.0",
          id: 0,
          method: "initialize",
          params: {
            protocolVersion: 1,
            clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
            clientInfo: { name: "wraith-shim", version: "0.1" },
          },
        }),
      );
    ws.onmessage = (m) => {
      try {
        const j = JSON.parse(String(m.data));
        if (j.id === 0 && j.result) {
          clearTimeout(t);
          finish(true);
        } else if (j.method && j.id !== undefined) {
          // Be a polite client: reject anything KAS asks us for.
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: j.id, error: { code: -32000, message: "probe client: not available" } }));
        }
      } catch {}
    };
    ws.onerror = () => {
      clearTimeout(t);
      finish(false);
    };
  });
}

// ---------------------------------------------------------------- journal

let journal: JournalConfig | null = null;
let lastShippedMtime = 0;
const JOURNAL_EVERY_MS = 60_000;

async function shipNow(reason: string) {
  if (!journal) return;
  await ship(journal, (l) => push(`[shim] ${l}`), reason);
  state.journal && (state.journal.last_ship = new Date().toISOString());
}

// Ship when something changed and has been quiet for a minute. KAS writes its
// session journal and memories.db as it goes; a timer is what survives a crash.
setInterval(async () => {
  if (!journal) return;
  const m = newestMtime();
  if (m > lastShippedMtime && Date.now() / 1000 - m > 20) {
    lastShippedMtime = m;
    await shipNow("timer");
  }
}, JOURNAL_EVERY_MS);

// ---------------------------------------------------------------- hooks

async function hook(name: string, req: Request): Promise<Response> {
  switch (name) {
    case "ready":
    case "validate": {
      const ok = await kasReady();
      event(`hook.${name}`, { ok });
      return new Response(ok ? "ok" : "warming", { status: ok ? 200 : 503 });
    }
    case "run": {
      let body: { microvmId?: string; runHookPayload?: string } = {};
      try {
        body = await req.json();
      } catch {}
      state.microvm_id = body.microvmId ?? null;
      let payload: RunPayload = {};
      if (body.runHookPayload) {
        try {
          payload = JSON.parse(body.runHookPayload);
        } catch {
          payload = { operative_id: body.runHookPayload };
        }
      }
      const { kiro_api_key, kiro_token, bridge_key, ...safe } = payload;
      state.payload = safe;
      bridgeBinding.key = bridge_key ?? null;
      if (bridge_key) event("bridge.bound");
      event("hook.run", { microvmId: state.microvm_id, payload: safe, credential: kiro_api_key ? "api-key" : kiro_token ? "token-file" : "none" });

      // KAS must not be running while its state is replaced underneath it.
      await stopKas();

      if (payload.journal?.bucket && payload.company_id) {
        journal = {
          bucket: payload.journal.bucket,
          region: payload.journal.region ?? "eu-central-1",
          prefix: payload.journal.prefix ?? `companies/${payload.company_id}`,
        };
        state.journal = { bucket: journal.bucket, prefix: journal.prefix, last_ship: null, credentials: await describeCredentials() };
        event("journal.config", state.journal);
        await restore(journal, (l) => push(`[shim] ${l}`));
        lastShippedMtime = newestMtime();
      }

      await Bun.write(`${WORK_DIR}/.wraith.json`, JSON.stringify({ microvm_id: state.microvm_id, ...safe }, null, 2));
      await ensureDesk(safe.company ?? "the company", safe.company_id);
      if (kiro_token) await installTokenFile(kiro_token);
      startKas(kiro_api_key ? { kind: "api-key", apiKey: kiro_api_key } : kiro_token ? { kind: "token-file" } : { kind: "none" });
      return new Response("ok");
    }
    case "resume": {
      if (!state.kas.pid) startKas();
      event("hook.resume");
      return new Response("ok");
    }
    case "suspend": {
      event("hook.suspend");
      await shipNow("suspend");
      return new Response("ok");
    }
    case "terminate": {
      event("hook.terminate");
      // 30 s budget (terminateTimeoutInSeconds); KAS gets a moment to flush.
      await stopKas();
      await shipNow("terminate");
      return new Response("ok");
    }
    default:
      return new Response("unknown hook", { status: 404 });
  }
}

// ---------------------------------------------------------------- HTTP

Bun.serve({
  port: 8080,
  hostname: "0.0.0.0",
  websocket: bridgeWebSocket((l) => event(l)),
  async fetch(req, server) {
    const url = new URL(req.url);
    if (url.pathname === "/bridge") return upgradeBridge(req, server, (l) => push(`[shim] ${l}`));
    if (url.pathname.startsWith(HOOK_PREFIX + "/")) {
      return hook(url.pathname.slice(HOOK_PREFIX.length + 1), req);
    }
    if (url.pathname === "/health") {
      return Response.json({ ...state, bridge: bridgeState, kas_ready: await kasReady(800) });
    }
    // Phoenix can ask for a checkpoint (before Close) without waiting for hooks.
    if (url.pathname === "/journal/ship" && req.method === "POST") {
      await shipNow("request");
      return Response.json(state.journal);
    }
    if (url.pathname === "/log") {
      const n = Math.min(Number(url.searchParams.get("n") ?? 200), LOG_LINES);
      return new Response(log.slice(-n).join("\n") + "\n", {
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }
    return new Response("wraith studio shim", { status: 200 });
  },
});

event("shim.listening", { port: 8080, kas_port: KAS_PORT });
startMcpServer((l) => push(`[shim] ${l}`));
startKas();
