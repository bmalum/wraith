// Capture every public view of the running Wraith site via headless Chrome
// (CDP). Usage: node capture.mjs <theme> [port]
// Writes priv/screenshots/<theme>/<view>.png
import { writeFileSync, mkdirSync, rmSync } from "node:fs";
import { spawn } from "node:child_process";

const theme = process.argv[2] || "paper";
const port = process.argv[3] || "4011";
const base = `http://localhost:${port}`;
const outDir = new URL(`./${theme}/`, import.meta.url);
mkdirSync(outDir, { recursive: true });

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
// a fresh profile per run: a reused dir with a stale SingletonLock can stall
const profile = `/tmp/wraith-chrome-${process.pid}`;
const chrome = spawn(
  CHROME,
  [
    "--headless=new",
    "--disable-gpu",
    "--remote-debugging-port=9333",
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--hide-scrollbars",
    "--force-color-profile=srgb",
    "about:blank",
  ],
  { stdio: "ignore" }
);
await new Promise((r) => setTimeout(r, 1800));

const target = await (
  await fetch(`http://127.0.0.1:9333/json/new?about:blank`, { method: "PUT" })
).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0;
const pending = {};
ws.onmessage = (m) => {
  const d = JSON.parse(m.data);
  if (d.id && pending[d.id]) {
    pending[d.id](d.result || {});
    delete pending[d.id];
  }
};
const send = (method, params = {}, ms = 15000) =>
  new Promise((res, rej) => {
    const i = ++id;
    const t = setTimeout(() => { delete pending[i]; rej(new Error(`${method} timed out`)); }, ms);
    pending[i] = (r) => { clearTimeout(t); res(r); };
    ws.send(JSON.stringify({ id: i, method, params }));
  });

await send("Page.enable");
await send("Runtime.enable");

// view name → path, viewport height
const views = [
  ["home", "/", 1500],
  ["post", "/writing-at-2-a-m", 1900],
  ["post-members", "/for-members-only", 1100],
  ["tag", "/tag/essays", 1200],
  ["author", "/author/ada-lovelace", 1200],
  ["search", "/search?q=ghosts", 1000],
  ["subscribe", "/subscribe", 900],
  ["signin", "/members", 900],
];

// one shot = set viewport, navigate, wait for LiveView + widgets, capture.
// a failure (timeout, navigation error) is logged and skipped — never fatal.
async function shoot(name, path, { width, height, scale = 1, mobile = false, after } = {}) {
  try {
    await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: scale, mobile });
    await send("Page.navigate", { url: base + path });
    await new Promise((r) => setTimeout(r, 2200));
    if (after) await after();
    const { data } = await send("Page.captureScreenshot", { format: "png" });
    writeFileSync(new URL(`./${name}.png`, outDir), Buffer.from(data, "base64"));
    console.log(`  ${theme}/${name}.png`);
  } catch (e) {
    console.log(`  !! ${theme}/${name}: ${e.message}`);
  }
}

for (const [name, path, h] of views) {
  await shoot(name, path, { width: 1400, height: h });
}

// mobile: the front page closed, then with the nav open
await shoot("mobile", "/", { width: 390, height: 844, scale: 2, mobile: true });
await shoot("mobile-nav", "/", {
  width: 390, height: 844, scale: 2, mobile: true,
  after: async () => {
    await send("Runtime.evaluate", { expression: `document.querySelector('.nav-toggle')?.click()` });
    await new Promise((r) => setTimeout(r, 600));
  },
});

chrome.kill();
try { rmSync(profile, { recursive: true, force: true }); } catch (_) {}
process.exit(0);
