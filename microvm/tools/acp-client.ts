#!/usr/bin/env bun
// Drive a Kiro Agent Server over ACP (JSON-RPC 2.0 over WebSocket).
//
//   bun acp-client.ts ws://localhost:18082 "say hello"
//   bun acp-client.ts wss://<mvm>.lambda-microvm.eu-central-1.on.aws "say hello" \
//        --token <jwe> --port 8082
//
// Auth for the agent itself: answers `_kiro/auth/getAccessToken` with either
// $KIRO_API_KEY (authMethod api_key) or the Director's own Kiro sign-in from
// ~/.aws/sso/cache/kiro-auth-token.json.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const [, , urlArg, ...rest] = process.argv;
if (!urlArg) {
  console.error("usage: acp-client.ts <ws-url> <prompt> [--token JWE] [--port N] [--cwd DIR]");
  process.exit(2);
}
const opts: Record<string, string> = {};
const words: string[] = [];
for (let i = 0; i < rest.length; i++) {
  if (rest[i].startsWith("--")) opts[rest[i].slice(2)] = rest[++i];
  else words.push(rest[i]);
}
const prompt = words.join(" ") || "Introduce yourself in one sentence, then list the files in the current directory.";
const cwd = opts.cwd ?? "/work";

const protocols: string[] = [];
if (opts.token) {
  protocols.push("lambda-microvms", `lambda-microvms.authentication.${opts.token}`);
  protocols.push(`lambda-microvms.port.${opts.port ?? "8082"}`);
}

function credential() {
  if (process.env.KIRO_API_KEY) {
    return {
      accessToken: process.env.KIRO_API_KEY,
      expiresAt: new Date(Date.now() + 365 * 86400_000).toISOString(),
      authMethod: "api_key",
    };
  }
  const f = `${homedir()}/.aws/sso/cache/kiro-auth-token.json`;
  const t = JSON.parse(readFileSync(f, "utf8"));
  return {
    accessToken: t.accessToken,
    expiresAt: t.expiresAt,
    authMethod: t.authMethod,
    provider: t.provider,
    ...(t.profileArn ? { profileArn: t.profileArn } : {}),
  };
}

const t0 = Date.now();
const ts = () => `+${((Date.now() - t0) / 1000).toFixed(2)}s`;
const ws = protocols.length ? new WebSocket(urlArg, protocols) : new WebSocket(urlArg);
const deadline = Number(opts.timeout ?? 180);
setTimeout(() => { console.error(`${ts()} timeout after ${deadline}s`); process.exit(3); }, deadline * 1000);
let nextId = 1;
const pending = new Map<number, (r: any) => void>();

function call(method: string, params: unknown): Promise<any> {
  const id = nextId++;
  ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
  return new Promise((res) => pending.set(id, res));
}
function reply(id: unknown, result: unknown) {
  ws.send(JSON.stringify({ jsonrpc: "2.0", id, result }));
}

let sessionId: string | null = null;

ws.onopen = async () => {
  console.error(`${ts()} connected`);
  const init = await call("initialize", {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
    clientInfo: { name: "shadow-corp", version: "0.1" },
  });
  console.error(`${ts()} initialize → agent ${init.result?.agentInfo?.name ?? "?"} ${init.result?.agentInfo?.version ?? ""}`);
  const sess = await call("session/new", { cwd, mcpServers: [] });
  if (sess.error) {
    console.error(`${ts()} session/new failed`, JSON.stringify(sess.error));
    process.exit(1);
  }
  sessionId = sess.result.sessionId;
  console.error(`${ts()} session ${sessionId}`);
  const turn = await call("session/prompt", {
    sessionId,
    prompt: [{ type: "text", text: prompt }],
  });
  console.error(`\n${ts()} turn done: ${JSON.stringify(turn.result ?? turn.error)}`);
  ws.close();
  process.exit(turn.error ? 1 : 0);
};

ws.onmessage = (m) => {
  const msg = JSON.parse(String(m.data));
  // response
  if (msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined) && pending.has(msg.id)) {
    pending.get(msg.id)!(msg);
    pending.delete(msg.id);
    return;
  }
  // agent → client request
  if (msg.method && msg.id !== undefined) {
    switch (msg.method) {
      case "_kiro/auth/getAccessToken":
        console.error(`${ts()} ← auth callback`);
        reply(msg.id, credential());
        return;
      case "session/request_permission": {
        const opt = (msg.params.options ?? []).find((o: any) => /allow/i.test(o.kind ?? o.optionId)) ?? msg.params.options?.[0];
        console.error(`${ts()} ← permission: ${msg.params.toolCall?.title ?? ""} → ${opt?.optionId}`);
        // Over the WS transport we are an "observer" client: KAS discards a plain
        // JSON-RPC reply and expects the explicit respond method instead.
        call("_kiro/permission/respond", { toolCallId: msg.params.toolCall?.toolCallId, optionId: opt?.optionId }).then(
          (r) => r.error && console.error(`${ts()} permission respond failed ${JSON.stringify(r.error)}`),
        );
        return;
      }
      default:
        console.error(`${ts()} ← ${msg.method} (unhandled) ${JSON.stringify(msg.params).slice(0, 200)}`);
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "not supported" } }));
        return;
    }
  }
  // notification
  if (msg.method === "session/update") {
    const u = msg.params.update;
    switch (u.sessionUpdate) {
      case "agent_message_chunk":
        if (u.content?.type === "text") process.stdout.write(u.content.text);
        break;
      case "agent_thought_chunk":
        break;
      case "tool_call":
        console.error(`\n${ts()} ⚙ ${u.title ?? u.kind} [${u.status}]`);
        break;
      case "tool_call_update":
        if (u.status) console.error(`${ts()} ⚙ ${u.toolCallId} → ${u.status}`);
        break;
      default:
        console.error(`${ts()} · ${u.sessionUpdate}`);
    }
    return;
  }
  if (msg.method) {
    console.error(`${ts()} · ${msg.method} ${JSON.stringify(msg.params ?? {}).slice(0, 160)}`);
  }
};
ws.onerror = (e) => console.error(`${ts()} ws error`, (e as any).message ?? e);
ws.onclose = (e) => console.error(`${ts()} closed ${e.code} ${e.reason}`);
