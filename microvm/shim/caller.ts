// Who is calling the bridge? Only the agent server may.
//
// Every custom agent in a shared safehouse lists its bridge URL and bearer in
// KAS's session files (~/.kiro/sessions/*/session.json), readable by every
// operative's shell (same uid). A token alone therefore cannot keep case A's
// shell off case B's tools or a connection's route. What a shell cannot
// forge is *which process* opened the TCP connection: the shim knows the
// KAS pid it spawned, and Linux tells it, for the peer port of a request,
// the socket inode (/proc/net/tcp) and whether that inode is open in
// /proc/<kas pid>/fd. A shell is a child of KAS with its own pid — refused.
//
// Honest limit: same uid + ptrace_scope 0 means a determined shell could still
// attach to the KAS process. This raises "copy a string from a file" to
// "debug the agent"; the per-company boundary (the VM) stays the real one.
//
// Without a registered pid (image build, tests off-Linux) every caller is
// admitted, so the guard never breaks a dev loop.

import { readFileSync, readdirSync, readlinkSync } from "node:fs";

export const callerGuard = { kasPid: null as number | null, refused: 0, checks: 0 };

/** Register (or clear) the only process allowed to call the bridge. */
export function bindCaller(pid: number | null) {
  callerGuard.kasPid = pid;
}

/** Is a loopback connection from `peerPort` owned by the bound process? */
export function callerAllowed(peerPort: number | undefined): boolean {
  const pid = callerGuard.kasPid;
  if (pid === null || peerPort === undefined) return true;
  callerGuard.checks += 1;
  const inode = socketInode(peerPort);
  if (inode === null) return false;
  const ok = processHoldsInode(pid, inode);
  if (!ok) callerGuard.refused += 1;
  return ok;
}

// /proc/net/tcp rows: "sl local_address rem_address st … uid timeout inode";
// addresses are hex IP:PORT. We want the row whose *local* side is the peer
// (the client socket) — its inode is what the client process holds.
function socketInode(peerPort: number): number | null {
  const want = peerPort.toString(16).toUpperCase().padStart(4, "0");
  for (const file of ["/proc/net/tcp", "/proc/net/tcp6"]) {
    let text: string;
    try {
      text = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    for (const line of text.split("\n").slice(1)) {
      const cols = line.trim().split(/\s+/);
      if (cols.length < 10) continue;
      const [, local, , , , , , , , inode] = cols;
      const port = local.split(":")[1];
      if (port === want) return Number(inode);
    }
  }
  return null;
}

function processHoldsInode(pid: number, inode: number): boolean {
  const target = `socket:[${inode}]`;
  let fds: string[];
  try {
    fds = readdirSync(`/proc/${pid}/fd`);
  } catch {
    return false;
  }
  for (const fd of fds) {
    try {
      if (readlinkSync(`/proc/${pid}/fd/${fd}`) === target) return true;
    } catch {
      // the fd closed under us; keep looking
    }
  }
  return false;
}
