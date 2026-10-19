#!/usr/bin/env node
//
// Headless smoke test for the browser client (WASM.md, "The smoke test").
//
// It serves `web/dist`, opens the built client in headless Chrome or Edge, and
// drives the exported `goats_frame` over the DevTools protocol. It does not rely
// on `requestAnimationFrame`: a headless page has no compositor, so rAF never
// ticks, and the scene's loader advances exactly one step per frame -- the page
// would stop after `makeEyeTextures()` and look hung. Timers are throttled for
// the same reason, so this drives one frame per CDP call instead.
//
// Usage:  web/build.sh client release     # once, with emsdk active
//         web/build.sh smoke              # or: node web/smoke.js
//
// Environment:
//   BROWSER           path to Chrome/Edge (otherwise auto-detected)
//   SMOKE_PORT        static server port            (default 8124)
//   SMOKE_DEBUG_PORT  DevTools port                 (default 9223)
//   SMOKE_READY       console line that means ready (default "sky: shader")
//   SMOKE_SHOT        screenshot path (default target/wasm-smoke.png)
//   SMOKE_LOG         console log path (default target/wasm-smoke.log)
//
// Exits 0 only when the ready line is seen and no uncaught exception, no
// sky/mip fallback, and a screenshot was written.

const http = require("http");
const fs = require("fs");
const path = require("path");
const { spawn, spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const DIST = path.join(ROOT, "web", "dist");
const PORT = Number(process.env.SMOKE_PORT || 8124);
const DEBUG_PORT = Number(process.env.SMOKE_DEBUG_PORT || 9223);
const READY = process.env.SMOKE_READY || "sky: shader";
const SHOT = path.resolve(ROOT, process.env.SMOKE_SHOT || "target/wasm-smoke.png");
const LOG = path.resolve(ROOT, process.env.SMOKE_LOG || "target/wasm-smoke.log");
const PROFILE = path.join(ROOT, "target", "smoke-profile-" + process.pid);
const HARNESS = path.join(DIST, "test.html");
const MIP_WARNING = "cumulus mips did not build";

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".data": "application/octet-stream",
  ".png": "image/png",
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function findBrowser() {
  if (process.env.BROWSER) return process.env.BROWSER;
  const candidates = [];
  if (process.platform === "win32") {
    candidates.push(
      "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
      "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
      "C:/Program Files/Google/Chrome/Application/chrome.exe",
      "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe"
    );
  } else if (process.platform === "darwin") {
    candidates.push(
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
    );
  } else {
    candidates.push(
      "/usr/bin/google-chrome",
      "/usr/bin/chromium",
      "/usr/bin/chromium-browser",
      "/usr/bin/microsoft-edge"
    );
  }
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) return candidate;
  }
  // Last resort: a name on PATH.
  const tool = process.platform === "win32" ? "where" : "which";
  const names =
    process.platform === "win32"
      ? ["msedge", "chrome"]
      : ["google-chrome", "chromium", "chromium-browser", "microsoft-edge"];
  for (const name of names) {
    const found = spawnSync(tool, [name], { encoding: "utf8" });
    if (found.status === 0 && found.stdout.trim()) {
      return found.stdout.trim().split(/\r?\n/)[0];
    }
  }
  throw new Error("no Chrome/Edge found; set BROWSER to the executable");
}

function serve() {
  const server = http.createServer((req, res) => {
    const url = decodeURIComponent(req.url.split("?")[0]);
    const file = path.join(DIST, url === "/" ? "index.html" : url.replace(/^\/+/, ""));
    if (!file.startsWith(DIST) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      res.writeHead(404);
      res.end("not found");
      return;
    }
    res.writeHead(200, {
      "Content-Type": MIME[path.extname(file).toLowerCase()] || "application/octet-stream",
      "Cache-Control": "no-store",
    });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(PORT, () => resolve(server));
  });
}

async function waitForDebug() {
  for (let i = 0; i < 150; i++) {
    try {
      const response = await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/version`);
      if (response.ok) return response.json();
    } catch {}
    await sleep(200);
  }
  throw new Error(`DevTools port ${DEBUG_PORT} never opened`);
}

function killBrowser(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  if (process.platform === "win32") {
    // Edge leaves renderer children holding the profile; kill the tree.
    spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore" });
  } else {
    child.kill("SIGKILL");
  }
}

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.onopen = () => resolve(ws);
    ws.onerror = (event) => reject(new Error("websocket: " + (event.message || event.type)));
  });
}

async function main() {
  if (typeof WebSocket !== "function") {
    throw new Error("Node 22+ is required (built-in WebSocket)");
  }
  for (const name of ["index.html", "goats.js", "goats.wasm"]) {
    if (!fs.existsSync(path.join(DIST, name))) {
      throw new Error(`web/dist/${name} is missing; run: web/build.sh client release`);
    }
  }

  fs.mkdirSync(path.dirname(LOG), { recursive: true });
  fs.mkdirSync(path.dirname(SHOT), { recursive: true });
  fs.mkdirSync(PROFILE, { recursive: true });

  const browser = findBrowser();

  // The page's own rAF loop is replaced so it cannot silently stop the loader
  // before the CDP driver starts. It also keeps running on timers where they do
  // tick, which only makes the smoke test finish sooner.
  const source = fs.readFileSync(path.join(DIST, "index.html"), "utf8");
  const harness = source.replace(
    /requestAnimationFrame\(function tick\(\) \{\s*if \(frame\(\)\) requestAnimationFrame\(tick\);\s*\}\);/,
    "(function tick() { if (frame()) setTimeout(tick, 16); })();"
  );
  if (harness === source) throw new Error("frame-loop driver not found in web/dist/index.html");
  fs.writeFileSync(HARNESS, harness);

  const lines = [];
  const note = (text) => {
    lines.push(text);
    console.log(text);
  };

  const server = await serve();
  note("smoke: browser " + browser);
  const child = spawn(
    browser,
    [
      "--headless=new",
      "--no-sandbox",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-extensions",
      "--disable-sync",
      "--disable-restore-session-state",
      // Software WebGL 2: the same ES 3.0 surface the client targets on phones.
      "--enable-unsafe-swiftshader",
      "--use-angle=swiftshader",
      "--window-size=1280,720",
      `--remote-debugging-port=${DEBUG_PORT}`,
      `--user-data-dir=${PROFILE}`,
      "about:blank",
    ],
    { stdio: ["ignore", "pipe", "pipe"] }
  );
  child.on("error", (error) => note("[browser] spawn failed: " + error.message));
  child.stderr.on("data", (chunk) => {
    for (const line of chunk.toString().split(/\r?\n/)) {
      if (/CONSOLE|ERROR|WARNING/.test(line)) note("[browser] " + line.trim());
    }
  });

  let ws;
  try {
    await waitForDebug();
    const created = await fetch(
      `http://127.0.0.1:${DEBUG_PORT}/json/new?${encodeURIComponent(`http://localhost:${PORT}/test.html`)}`,
      { method: "PUT" }
    );
    const target = await created.json();

    ws = await connect(target.webSocketDebuggerUrl);
    let nextId = 1;
    let exceptions = 0;
    const pending = new Map();
    ws.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (message.id && pending.has(message.id)) {
        pending.get(message.id)(message);
        pending.delete(message.id);
        return;
      }
      if (message.method === "Runtime.consoleAPICalled") {
        const text = message.params.args
          .map((arg) => (arg.value !== undefined ? arg.value : arg.description || ""))
          .join(" ");
        note("[page] " + text);
      } else if (message.method === "Runtime.exceptionThrown") {
        exceptions++;
        note("[page] EXCEPTION " + JSON.stringify(message.params.exceptionDetails));
      }
    };
    const send = (method, params = {}) =>
      new Promise((resolve, reject) => {
        const id = nextId++;
        pending.set(id, (message) =>
          message.error ? reject(new Error(`${method}: ${JSON.stringify(message.error)}`)) : resolve(message.result)
        );
        ws.send(JSON.stringify({ id, method, params }));
      });

    await send("Runtime.enable");
    await send("Page.enable");

    // Wait for the module's export rather than guessing at a boot delay.
    let exported = false;
    for (let i = 0; i < 150; i++) {
      const probe = await send("Runtime.evaluate", {
        expression:
          "typeof Module !== 'undefined' && typeof (Module._goats_frame || Module.goats_frame) === 'function'",
        returnByValue: true,
      });
      if (probe.result && probe.result.value === true) {
        exported = true;
        break;
      }
      await sleep(200);
    }
    if (!exported) throw new Error("goats_frame was never exported");

    const frame = "(Module._goats_frame || Module.goats_frame)()";
    let ready = lines.some((line) => line.includes(READY));
    let frames = 0;
    const deadline = Date.now() + 30000;
    while (!ready && Date.now() < deadline && frames < 400) {
      const step = await send("Runtime.evaluate", { expression: frame, returnByValue: true });
      frames++;
      if (!step.result || step.result.value === 0) break;
      ready = lines.some((line) => line.includes(READY));
      if (!ready) await sleep(40);
    }
    note(`smoke: ${frames} frame(s), ready=${ready}`);

    // A few drawn frames so the screenshot is not the first painted one.
    for (let i = 0; i < 10; i++) {
      await send("Runtime.evaluate", { expression: frame, returnByValue: true });
      await sleep(100);
    }
    const capture = await send("Page.captureScreenshot", { format: "png" });
    fs.writeFileSync(SHOT, Buffer.from(capture.data, "base64"));

    const fellBack = lines.some((line) => line.includes(MIP_WARNING));
    const pass = ready && !fellBack && exceptions === 0;
    note(
      `smoke: ${pass ? "PASS" : "FAIL"}` +
        ` (ready=${ready}, mipFallback=${fellBack}, exceptions=${exceptions})`
    );
    note("smoke: screenshot " + path.relative(ROOT, SHOT));
    note("smoke: log        " + path.relative(ROOT, LOG));
    process.exitCode = pass ? 0 : 1;

    await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/close/${target.id}`).catch(() => {});
  } finally {
    if (ws) ws.close();
    server.close();
    killBrowser(child);
    // The profile is disposable; a leftover directory under target/ must not
    // turn a passing boot into a red exit. Wait for the handle, then retry.
    await sleep(500);
    try {
      fs.rmSync(PROFILE, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    } catch (error) {
      note(`smoke: left ${path.relative(ROOT, PROFILE)} (${error.code})`);
    }
    fs.rmSync(HARNESS, { force: true });
    fs.writeFileSync(LOG, lines.join("\n"));
  }
}

main().catch((error) => {
  console.error("smoke: " + (error.stack || error));
  process.exit(1);
});
