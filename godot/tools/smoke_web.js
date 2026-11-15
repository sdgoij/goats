#!/usr/bin/env node
//
// Headless smoke test for the Godot client in the browser (`godot/WEB.md`).
//
// It serves a packaged build, opens the shell page in headless Chrome or Edge,
// and watches the console for the two things that only a browser can answer:
// whether the GDExtension loaded, and whether the scene's scripts parsed and ran.
// Both of them failed at once when the extension crossed Chromium's 8 MB
// synchronous-compile limit and nothing else in CI noticed -- the export was
// green, the package was complete, and the page was a black frame.
//
// Usage:  sh godot/tools/package_web.sh      # once, into target/godot-web
//         node godot/tools/smoke_web.js      # or: node godot/tools/smoke_web.js dist-web
//
// Environment:
//   BROWSER           path to Chrome/Edge (otherwise auto-detected)
//   SMOKE_PORT        static server port                  (default 8125)
//   SMOKE_DEBUG_PORT  DevTools port                       (default 9224)
//   SMOKE_TIMEOUT     seconds to wait for the boot        (default 90)
//   SMOKE_SHOT        screenshot path (default target/godot-web-smoke.png)
//   SMOKE_LOG         console log path (default target/godot-web-smoke.log)
//
// Exits 0 only when the extension loaded, the scene started (when the browser
// had a renderer at all), no script failed to load, and no exception was thrown.

const http = require("http");
const fs = require("fs");
const path = require("path");
const { spawn, spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..", "..");
const DIST = path.resolve(ROOT, process.argv[2] || path.join("target", "godot-web"));
const PORT = Number(process.env.SMOKE_PORT || 8125);
const DEBUG_PORT = Number(process.env.SMOKE_DEBUG_PORT || 9224);
const TIMEOUT = Number(process.env.SMOKE_TIMEOUT || 90) * 1000;
const SHOT = path.resolve(ROOT, process.env.SMOKE_SHOT || "target/godot-web-smoke.png");
const LOG = path.resolve(ROOT, process.env.SMOKE_LOG || "target/godot-web-smoke.log");
const PROFILE = path.join(ROOT, "target", "smoke-godot-" + process.pid);

// The extension's own first line. Printed by godot-rust before the engine starts,
// so it survives a headless box with no renderer.
const EXTENSION_READY = "Initialize godot-rust";
// The scene's first line, from `main.gd`. Reaching it means every script that
// names `Flight` parsed -- which is exactly what an unloaded extension breaks.
const SCENE_READY = "play alone:";
// The renderer's line. Without it nothing is drawn, and the scene never runs.
const RENDERER_READY = "OpenGL API";

// Failures that mean the page is broken even though it is "running". The first is
// the 8 MB limit; the rest are what a missing extension cascades into.
const FATAL = [
  /WebAssembly\.Compile is disallowed/,
  /Can't open GDExtension dynamic library/,
  /Could not open dynamic library/,
  /Could not find type "Flight"/,
  /Failed to load script/,
];

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".pck": "application/octet-stream",
  ".png": "image/png",
  ".worklet.js": "text/javascript; charset=utf-8",
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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
  // `goats_godot.wasm` at the package root is the shell's copy of the extension
  // (`package_web.sh`); without it the page boots an engine with no `Flight`.
  for (const name of [
    "index.html",
    "goats_godot.wasm",
    path.join("client", "index.js"),
    path.join("client", "index.pck"),
    path.join("client", "goats_godot.wasm"),
  ]) {
    if (!fs.existsSync(path.join(DIST, name))) {
      throw new Error(`${path.relative(ROOT, path.join(DIST, name))} is missing; run: sh godot/tools/package_web.sh`);
    }
  }

  fs.mkdirSync(path.dirname(LOG), { recursive: true });
  fs.mkdirSync(path.dirname(SHOT), { recursive: true });
  fs.mkdirSync(PROFILE, { recursive: true });

  const browser = findBrowser();
  const lines = [];
  const note = (text) => {
    lines.push(text);
    console.log(text);
  };

  const server = await serve();
  note("smoke: browser " + browser);
  note("smoke: serving " + path.relative(ROOT, DIST));
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
      // A container has a small /dev/shm, and Godot's heap is not.
      "--disable-dev-shm-usage",
      // Software WebGL 2: the same ES 3.0 surface the client targets on phones.
      "--enable-unsafe-swiftshader",
      "--use-angle=swiftshader",
      "--window-size=1120,630",
      "--mute-audio",
      `--remote-debugging-port=${DEBUG_PORT}`,
      `--user-data-dir=${PROFILE}`,
      "about:blank",
    ],
    { stdio: ["ignore", "pipe", "pipe"] }
  );
  child.on("error", (error) => note("[browser] spawn failed: " + error.message));
  child.stderr.on("data", (chunk) => {
    for (const line of chunk.toString().split(/\r?\n/)) {
      if (/CONSOLE|ERROR/.test(line)) note("[browser] " + line.trim());
    }
  });

  let ws;
  let target;
  try {
    await waitForDebug();
    const created = await fetch(
      `http://127.0.0.1:${DEBUG_PORT}/json/new?${encodeURIComponent(`http://localhost:${PORT}/index.html`)}`,
      { method: "PUT" }
    );
    target = await created.json();

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
        const details = message.params.exceptionDetails;
        note("[page] EXCEPTION " + ((details.exception && details.exception.description) || details.text));
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

    // Wait for the boot rather than for a delay: the extension line, then the
    // scene's own first line when this browser gave the page a renderer.
    const deadline = Date.now() + TIMEOUT;
    const seen = (needle) => lines.some((line) => line.includes(needle));
    let extension = false;
    let scene = false;
    let renderer = false;
    while (Date.now() < deadline) {
      extension = extension || seen(EXTENSION_READY);
      renderer = renderer || seen(RENDERER_READY);
      scene = scene || seen(SCENE_READY);
      if (extension && scene) break;
      await sleep(250);
    }

    // A few seconds more so the frame loop draws something worth screenshotting.
    await sleep(3000);
    const capture = await send("Page.captureScreenshot", { format: "png" });
    fs.writeFileSync(SHOT, Buffer.from(capture.data, "base64"));

    const fatal = lines.filter((line) => FATAL.some((pattern) => pattern.test(line)));
    // The scene line is only required when the engine got a renderer; on a box
    // with no WebGL the engine stops before the scene, and the extension line is
    // then the whole of what this test can see.
    const sceneRequired = renderer && !scene;
    const pass = extension && !sceneRequired && fatal.length === 0 && exceptions === 0;

    note(
      `smoke: ${pass ? "PASS" : "FAIL"}` +
        ` (extension=${extension}, renderer=${renderer}, scene=${scene}, ` +
        `fatal=${fatal.length}, exceptions=${exceptions})`
    );
    for (const line of fatal) note("smoke: fatal: " + line);
    note("smoke: screenshot " + path.relative(ROOT, SHOT));
    note("smoke: log        " + path.relative(ROOT, LOG));
    process.exitCode = pass ? 0 : 1;

    await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/close/${target.id}`).catch(() => {});
  } finally {
    if (ws) ws.close();
    server.close();
    killBrowser(child);
    // The profile is disposable; a leftover directory must not turn a passing
    // boot into a red exit. Wait for the handle, then retry.
    await sleep(500);
    try {
      fs.rmSync(PROFILE, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    } catch (error) {
      note(`smoke: left ${path.relative(ROOT, PROFILE)} (${error.code})`);
    }
    fs.writeFileSync(LOG, lines.join("\n"));
  }
}

main().catch((error) => {
  console.error("smoke: " + (error.stack || error));
  process.exit(1);
});
