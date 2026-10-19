// Capture every public view of the running Wraith site via headless Chrome
// (CDP). Usage: node capture.mjs <theme> [port]
// Writes priv/screenshots/<theme>/<view>.png
import { writeFileSync, mkdirSync } from "node:fs";
import { spawn } from "node:child_process";

const theme = process.argv[2] || "paper";
const port = process.argv[3] || "4011";
const base = `http://localhost:${port}`;
const outDir = new URL(`./${theme}/`, import.meta.url);
mkdirSync(outDir, { recursive: true });

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const chrome = spawn(
  CHROME,
  [
    "--headless=new",
    "--disable-gpu",
    "--remote-debugging-port=9333",
    "--user-data-dir=/tmp/chrome-prof",
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
const send = (method, params = {}) =>
  new Promise((res) => {
    const i = ++id;
    pending[i] = res;
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

for (const [name, path, h] of views) {
  await send("Emulation.setDeviceMetricsOverride", {
    width: 1400,
    height: h,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await send("Page.navigate", { url: base + path });
  // wait for the LiveView to connect and widgets to settle
  await new Promise((r) => setTimeout(r, 2200));
  const { data } = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(new URL(`./${name}.png`, outDir), Buffer.from(data, "base64"));
  console.log(`  ${theme}/${name}.png`);
}

chrome.kill();
process.exit(0);
