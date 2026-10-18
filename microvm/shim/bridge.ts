// The MCP bridge. KAS reaches the company's tools at http://127.0.0.1:8090/mcp/…
// (listed in each case's custom agent); the shim relays every HTTP request over
// a WebSocket that Phoenix opens to :8080/bridge — the same direction as ACP,
// so there is no public MCP endpoint and no secret in the VM.
//
// Frames on the bridge are JSON-RPC 2.0: the shim sends
//   {id, method: "bridge/http", params: {method, path, headers, body}}
// and Phoenix answers {id, result: {status, headers, body}}.
// Phoenix may also ask the shim to stage a case's inputs:
//   {id, method: "bridge/stage", params: {from: ["/work/cases/SC-1/a.md"], to: "/work/cases/SC-2/inputs/SC-1"}}
// → {id, result: {copied: [...], missing: [...]}}; both sides must be under /work/cases.
// No bridge connected → 503, so KAS reports the tool as unavailable.
// Only the agent server process may call (caller.ts): a shell in the VM that
// copied a case's URL and token out of a session file gets 403.

import type { Server, ServerWebSocket } from "bun";
import { callerAllowed, callerGuard } from "./caller.ts";
import { cp, mkdir, readdir, readFile, stat } from "node:fs/promises";
import { basename, relative, resolve as resolvePath } from "node:path";

export const CASES_ROOT = process.env.CASES_ROOT ?? "/work/cases";

export const MCP_PORT = Number(process.env.MCP_BRIDGE_PORT ?? "8090");
const TIMEOUT_MS = 120_000;
// authorization carries the per-case token Phoenix checks (Wraith.Kiro.Bridge)
const FORWARD_HEADERS = ["authorization", "content-type", "accept", "mcp-session-id", "mcp-protocol-version", "last-event-id"];

type Reply = { status: number; headers?: Record<string, string>; body?: string };
type Pending = { resolve: (r: Reply) => void; timer: ReturnType<typeof setTimeout> };

let socket: ServerWebSocket<unknown> | null = null;
let nextId = 1;
const pending = new Map<number, Pending>();

export const bridgeState = {
  connected: false,
  relayed: 0,
  failed: 0,
  connected_at: null as string | null,
  // callers that were not the agent server process (caller.ts)
  get refused_callers() {
    return callerGuard.refused;
  },
};

// What the shim tells Phoenix when a bridge opens (the KAS bundle the image ships).
export const bridgeHello: { kas_bundle: string } = { kas_bundle: "unknown" };

// The bridge is bound to the house that started this VM: Phoenix passes a
// `bridge_key` in the /run payload and dials `/bridge?key=<it>`. A dial without
// the right key is refused instead of displacing the live connection — so a
// second house (or anything else that can reach :8080) cannot take the bridge.
// null = no key configured (an image build / validate run): any dial is accepted.
export const bridgeBinding: { key: string | null } = { key: null };

/** Upgrade `GET /bridge` on the hooks server (call from its fetch). */
export function upgradeBridge(req: Request, server: Server, log?: (line: string) => void): Response | undefined {
  const given = new URL(req.url).searchParams.get("key");
  if (bridgeBinding.key !== null && !constantTimeEqual(given ?? "", bridgeBinding.key)) {
    log?.("bridge.refused: wrong or missing key");
    return new Response("bridge is bound to another house", { status: 403 });
  }
  const offered = req.headers.get("sec-websocket-protocol") ?? "";
  const headers = offered.includes("lambda-microvms") ? { "Sec-WebSocket-Protocol": "lambda-microvms" } : undefined;
  if (server.upgrade(req, { headers, data: { kind: "bridge" } })) return undefined;
  return new Response("websocket upgrade required", { status: 426 });
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function bridgeWebSocket(log: (line: string) => void) {
  return {
    open(ws: ServerWebSocket<unknown>) {
      // one bridge at a time: the newest connection wins
      if (socket && socket !== ws) {
        try {
          socket.close(1000, "replaced");
        } catch {}
      }
      socket = ws;
      bridgeState.connected = true;
      bridgeState.connected_at = new Date().toISOString();
      log("bridge.open");
      ws.send(JSON.stringify({ jsonrpc: "2.0", method: "bridge/hello", params: bridgeHello }));
    },
    message(ws: ServerWebSocket<unknown>, data: string | Buffer) {
      let msg: { id?: number; method?: string; params?: unknown; result?: Reply; error?: { message?: string } };
      try {
        msg = JSON.parse(String(data));
      } catch {
        return;
      }
      if (typeof msg.id !== "number") return;
      // a request from Phoenix (today: staging a case's inputs)
      if (msg.method === "bridge/stage") {
        stage(msg.params as { from?: unknown; to?: unknown })
          .then((result) => ws.send(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result })))
          .catch((e) => ws.send(JSON.stringify({ jsonrpc: "2.0", id: msg.id, error: { code: -32000, message: String(e?.message ?? e) } })));
        log(`bridge.stage`);
        return;
      }
      // the Director reads a case's files (list a directory, read one file)
      if (msg.method === "bridge/files") {
        files(msg.params as { dir?: unknown; file?: unknown })
          .then((result) => ws.send(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result })))
          .catch((e) => ws.send(JSON.stringify({ jsonrpc: "2.0", id: msg.id, error: { code: -32000, message: String(e?.message ?? e) } })));
        return;
      }
      if (msg.method) {
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: `unknown method ${msg.method}` } }));
        return;
      }
      const p = pending.get(msg.id);
      if (!p) return;
      pending.delete(msg.id);
      clearTimeout(p.timer);
      p.resolve(msg.result ?? { status: 502, body: msg.error?.message ?? "bridge error" });
    },
    close(ws: ServerWebSocket<unknown>) {
      if (socket !== ws) return;
      socket = null;
      bridgeState.connected = false;
      for (const [id, p] of pending) {
        clearTimeout(p.timer);
        p.resolve({ status: 503, body: "bridge closed" });
        pending.delete(id);
      }
      log("bridge.close");
    },
  };
}

/** Copy files from one case's directory into another's inputs/. Paths outside CASES_ROOT are refused. */
/** Formats a typed output may declare; the check is extension plus a content sniff. */
export const FORMATS = ["md", "csv", "json", "txt"] as const;
export type Format = (typeof FORMATS)[number];

/** Why a file is not the format its step declared, or null when it passes. */
export function formatMismatch(path: string, format: Format, head: Buffer): string | null {
  const ext = (path.split(".").pop() || "").toLowerCase();
  const okExt: Record<Format, string[]> = { md: ["md", "markdown"], csv: ["csv"], json: ["json"], txt: ["txt", "text"] };
  if (!okExt[format].includes(ext)) return `extension .${ext} is not ${format}`;
  if (head.includes(0)) return "binary content";
  const text = head.toString("utf8").trim();
  if (text.length === 0) return "empty file";
  if (format === "json") {
    try { JSON.parse(head.length >= 65536 ? text.slice(0, 1) : text); } catch { if (!/^[\[{]/.test(text)) return "content is not JSON"; }
  }
  if (format === "csv") {
    const lines = text.split(/\r?\n/).filter((l) => l.length > 0);
    if (lines.length < 1 || !lines[0].includes(",")) return "first line has no comma-separated columns";
  }
  if (format === "md" && /^[\[{]/.test(text) && /[}\]]\s*$/.test(text)) return "content looks like JSON, not markdown";
  return null;
}

export async function stage(params: { from?: unknown; to?: unknown }): Promise<{ copied: string[]; missing: string[]; rejected: { path: string; reason: string }[] }> {
  const root = resolvePath(CASES_ROOT) + "/";
  const inside = (p: string) => resolvePath(p).startsWith(root);
  const to = typeof params.to === "string" ? params.to : "";
  // an entry is a path, or {path, format} for a typed output
  const from: { path: string; format: Format | null }[] = Array.isArray(params.from)
    ? params.from.flatMap((f) => {
        if (typeof f === "string") return [{ path: f, format: null }];
        if (f && typeof f === "object" && typeof (f as { path?: unknown }).path === "string") {
          const fmt = (f as { format?: unknown }).format;
          return [{ path: (f as { path: string }).path, format: typeof fmt === "string" && (FORMATS as readonly string[]).includes(fmt) ? (fmt as Format) : null }];
        }
        return [];
      })
    : [];
  if (!inside(to) || !resolvePath(to).includes("/inputs")) throw new Error(`stage: destination must be a case's inputs/ directory under ${CASES_ROOT}`);
  for (const f of from) if (!inside(f.path)) throw new Error(`stage: ${f.path} is outside ${CASES_ROOT}`);
  await mkdir(to, { recursive: true });
  const copied: string[] = [];
  const missing: string[] = [];
  const rejected: { path: string; reason: string }[] = [];
  for (const f of from) {
    let s;
    try {
      s = await stat(f.path);
    } catch {
      missing.push(f.path);
      continue;
    }
    if (f.format && s.isFile()) {
      const buf = await readFile(f.path);
      const why = formatMismatch(f.path, f.format, buf.subarray(0, 65536));
      if (why) {
        rejected.push({ path: f.path, reason: `declared ${f.format}: ${why}` });
        continue;
      }
    }
    await cp(f.path, `${to}/${basename(f.path)}`, { recursive: s.isDirectory(), force: true });
    copied.push(`${to}/${basename(f.path)}`);
  }
  return { copied, missing, rejected };
}

/** Largest file the Director may read inline (bytes). */
const MAX_READ = 512 * 1024;

/**
 * List a case directory (recursively, files only, with sizes) or read one file
 * as text. Paths outside CASES_ROOT are refused; binaries are flagged, not sent.
 */
export async function files(params: { dir?: unknown; file?: unknown }): Promise<
  { entries: { path: string; size: number; mtime: string }[] } | { content: string; size: number; truncated: boolean; binary: boolean }
> {
  const root = resolvePath(CASES_ROOT) + "/";
  const inside = (p: string) => resolvePath(p).startsWith(root);
  if (typeof params.file === "string") {
    if (!inside(params.file)) throw new Error(`files: ${params.file} is outside ${CASES_ROOT}`);
    const s = await stat(params.file);
    if (!s.isFile()) throw new Error("files: not a file");
    const buf = await readFile(params.file);
    const head = buf.subarray(0, Math.min(buf.length, 8000));
    const binary = head.includes(0);
    const slice = buf.subarray(0, MAX_READ);
    return { content: binary ? "" : slice.toString("utf8"), size: s.size, truncated: s.size > MAX_READ, binary };
  }
  const dir = typeof params.dir === "string" ? params.dir : "";
  if (!inside(dir)) throw new Error(`files: ${dir} is outside ${CASES_ROOT}`);
  const entries: { path: string; size: number; mtime: string }[] = [];
  const walk = async (d: string, depth: number): Promise<void> => {
    if (depth > 6 || entries.length >= 500) return;
    let names: import("node:fs").Dirent[];
    try {
      names = await readdir(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of names) {
      const p = `${d}/${e.name}`;
      if (e.name === "node_modules" || e.name === ".git") continue;
      if (e.isDirectory()) await walk(p, depth + 1);
      else if (e.isFile()) {
        const s = await stat(p);
        entries.push({ path: relative(dir, p), size: s.size, mtime: s.mtime.toISOString() });
      }
    }
  };
  await walk(dir, 0);
  entries.sort((a, b) => a.path.localeCompare(b.path));
  return { entries };
}

function relay(params: { method: string; path: string; headers: Record<string, string>; body: string }): Promise<Reply> {
  const ws = socket;
  if (!ws) return Promise.resolve({ status: 503, body: "bridge not connected" });
  const id = nextId++;
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      resolve({ status: 504, body: "bridge timeout" });
    }, TIMEOUT_MS);
    pending.set(id, { resolve, timer });
    ws.send(JSON.stringify({ jsonrpc: "2.0", id, method: "bridge/http", params }));
  });
}

/** The loopback MCP endpoint KAS talks to. */
export function startMcpServer(log: (line: string) => void) {
  Bun.serve({
    port: MCP_PORT,
    hostname: "127.0.0.1",
    idleTimeout: 255,
    async fetch(req, server) {
      const url = new URL(req.url);
      if (!callerAllowed(server.requestIP(req)?.port)) {
        log(`bridge.refused caller is not the agent server: ${req.method} ${url.pathname}`);
        // Phoenix puts it on the paper trail (Safehouses.Server, "bridge/refused")
        socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "bridge/refused", params: { method: req.method, path: url.pathname } }));
        return new Response("the bridge answers the agent server only", { status: 403 });
      }
      const headers: Record<string, string> = {};
      for (const h of FORWARD_HEADERS) {
        const v = req.headers.get(h);
        if (v) headers[h] = v;
      }
      const body = req.method === "POST" ? await req.text() : "";
      const reply = await relay({ method: req.method, path: url.pathname + url.search, headers, body });
      if (reply.status >= 500) bridgeState.failed += 1;
      else bridgeState.relayed += 1;
      if (reply.status >= 500) log(`bridge.relay ${req.method} ${url.pathname} → ${reply.status} ${reply.body ?? ""}`);
      const empty = reply.status === 202 || reply.status === 204 || reply.status === 304;
      return new Response(empty ? null : (reply.body ?? ""), { status: reply.status, headers: reply.headers ?? {} });
    },
  });
  log(`bridge.mcp listening on 127.0.0.1:${MCP_PORT}`);
}
