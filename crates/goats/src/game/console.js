// Part 13/14 of the goat scene: the in-game console.
// ---- console --------------------------------------------------------------
//
// An overlay, not a menu. A menu is a `uiScreen` value, which freezes the world
// by forcing the frame's `dt` to 0 (see goat.js); the console must not, because
// it has to stay usable while the game keeps running -- and, once multiplayer
// lands, one player opening their console must not pause everyone else.
//
// Backquote toggles it. While it is open it swallows the gameplay keys, so
// typing never moves the goat: `ctlKeyDown` (ctl.js) and `press` (menu.js) both
// check `consoleOpen`, and the frame loop gives the console first refusal on
// Escape. Submitting a line routes it through the same `sceneCommand`
// dispatcher the stdin channel uses, so every command the host and the harness
// already drive works here unchanged.
//
// The scrollback keeps local command replies visually distinct from network and
// system lines -- that is where the session events (M10/M11) will land, via
// `consoleNet` / `consoleSystem`.

// Backquote. The engine exports KEY_GRAVE; an engine without it falls back to
// the raylib scancode, the same guard the keymap uses for KEY_F11.
const CONSOLE_KEY = typeof rl.KEY_GRAVE === "number" ? rl.KEY_GRAVE : 96;
const CONSOLE_MAX_LINES = 200;
const CONSOLE_HISTORY = 32;

const CONSOLE_COLORS = {
    echo: rl.color(148, 150, 158, 255),    // what the player typed
    local: rl.color(184, 220, 184, 255),   // a command reply
    net: rl.color(150, 200, 255, 255),     // a network/system line (M10+)
    system: rl.color(216, 190, 140, 255),
    input: rl.color(236, 236, 236, 255),
};

let consoleOpen = false;
let consoleInput = "";
let consoleCaret = 0;
let consoleLines = [];          // { text, kind }
let consoleHistory = [];
let consoleHistoryAt = 0;
let consoleSeen = false;

// Append a line, dropping the oldest once the ring is full.
function consolePush(text, kind) {
    consoleLines.push({ text: String(text), kind: kind || "local" });
    if (consoleLines.length > CONSOLE_MAX_LINES) {
        consoleLines.splice(0, consoleLines.length - CONSOLE_MAX_LINES);
    }
}

// A line from the session (M10/M11): chat, joins, errors.
function consoleNet(text) {
    consolePush(text, "net");
}

// A line the scene itself is reporting.
function consoleSystem(text) {
    consolePush(text, "system");
}

function consoleClose() {
    consoleOpen = false;
}

function consoleToggle() {
    consoleOpen = !consoleOpen;
    if (!consoleOpen) return;
    // raylib queues a character for every printable key, whether or not anyone
    // reads it, so the backlog holds the `wasd` typed while playing. Drop it
    // before the console starts accepting input.
    if (typeof rl.getCharPressed === "function") {
        let stale = rl.getCharPressed();
        while (stale !== 0) stale = rl.getCharPressed();
    }
    consoleHistoryAt = consoleHistory.length;
    consoleCaret = consoleInput.length;
    if (!consoleSeen) {
        consoleSeen = true;
        consoleSystem("console ready - backquote or ESC closes, enter runs a command");
        if (typeof rl.getCharPressed !== "function") {
            consoleSystem("text entry needs the engine's getCharPressed binding");
        }
    }
}

// Run one submitted line: echo it, dispatch it, echo the reply.
function consoleSubmit(line) {
    const text = String(line).trim();
    if (text === "") return;
    consolePush("> " + text, "echo");
    if (consoleHistory.length === 0 || consoleHistory[consoleHistory.length - 1] !== text) {
        consoleHistory.push(text);
        if (consoleHistory.length > CONSOLE_HISTORY) consoleHistory.shift();
    }
    consoleHistoryAt = consoleHistory.length;
    let reply;
    try {
        reply = sceneCommand(text);
    } catch (error) {
        reply = "error " + String(error);
    }
    consolePush(reply === undefined ? "ok" : String(reply), "local");
    consoleInput = "";
    consoleCaret = 0;
}

// Read the character queue and the editing keys, once a frame while open.
function consoleHandleInput() {
    // Text: raylib queues one codepoint per key press, 0 once drained, so read
    // until empty. Only printable ASCII is accepted for now.
    if (typeof rl.getCharPressed === "function") {
        let code = rl.getCharPressed();
        while (code !== 0) {
            if (code >= 32 && code < 127) {
                consoleInput = consoleInput.slice(0, consoleCaret) + String.fromCharCode(code) +
                    consoleInput.slice(consoleCaret);
                consoleCaret += 1;
            }
            code = rl.getCharPressed();
        }
    }
    if (consoleCaret > 0 && rl.isKeyPressed(rl.KEY_BACKSPACE)) {
        consoleInput = consoleInput.slice(0, consoleCaret - 1) + consoleInput.slice(consoleCaret);
        consoleCaret -= 1;
    }
    if (consoleCaret < consoleInput.length && typeof rl.KEY_DELETE === "number" &&
        rl.isKeyPressed(rl.KEY_DELETE)) {
        consoleInput = consoleInput.slice(0, consoleCaret) + consoleInput.slice(consoleCaret + 1);
    }
    if (consoleCaret > 0 && rl.isKeyPressed(rl.KEY_LEFT)) consoleCaret -= 1;
    if (consoleCaret < consoleInput.length && rl.isKeyPressed(rl.KEY_RIGHT)) consoleCaret += 1;
    if (consoleHistory.length > 0 && rl.isKeyPressed(rl.KEY_UP)) {
        if (consoleHistoryAt > 0) consoleHistoryAt -= 1;
        consoleInput = consoleHistory[consoleHistoryAt];
        consoleCaret = consoleInput.length;
    }
    if (rl.isKeyPressed(rl.KEY_DOWN) && consoleHistoryAt < consoleHistory.length) {
        consoleHistoryAt += 1;
        consoleInput = consoleHistoryAt < consoleHistory.length ? consoleHistory[consoleHistoryAt] : "";
        consoleCaret = consoleInput.length;
    }
    if (rl.isKeyPressed(rl.KEY_ENTER)) consoleSubmit(consoleInput);
}

// Per-frame update. Returns true when it consumed the Escape press, so the
// caller does not also toggle the main menu on the same key.
function consoleUpdate() {
    // Only open from the HUD: with a menu up, the menu owns the input.
    if (uiScreen === "hud" && rl.isKeyPressed(CONSOLE_KEY)) consoleToggle();
    if (!consoleOpen) return false;
    if (rl.isKeyPressed(rl.KEY_ESCAPE)) {
        consoleClose();
        return true;
    }
    consoleHandleInput();
    return false;
}

// The overlay: a translucent panel over the top of the screen, the scrollback's
// last visible lines, then the input line with its caret.
function drawConsole() {
    const sw = rl.getScreenWidth();
    const sh = rl.getScreenHeight();
    const lineH = 18;
    const pad = 10;
    const maxRows = Math.max(3, Math.floor((sh * 0.5 - pad * 2 - lineH) / lineH));
    const count = Math.min(consoleLines.length, maxRows);
    const first = consoleLines.length - count;
    const panelH = Math.min(sh, pad * 2 + (count + 1) * lineH);
    rl.drawRectangle(0, 0, sw, panelH, rl.color(8, 10, 14, 215));
    let y = pad;
    for (let i = 0; i < count; i++) {
        const line = consoleLines[first + i];
        rl.drawText(line.text, pad, y, lineH, CONSOLE_COLORS[line.kind] || CONSOLE_COLORS.input);
        y += lineH;
    }
    const before = consoleInput.slice(0, consoleCaret);
    const after = consoleInput.slice(consoleCaret);
    rl.drawText("> " + before + "|" + after, pad, y, lineH, CONSOLE_COLORS.input);
}
