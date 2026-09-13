// Part 13/15 of the goat scene: the in-game console.
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
const CONSOLE_MAX_INPUT = 512;

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
// Set while the console is asking a question: the next submitted line is the
// answer, passed to `action`, rather than being dispatched as a command.
let consolePrompt = null;

// Append a line, dropping the oldest once the ring is full. A reply may carry
// newlines (the `help` page does), so it is split into one entry per row.
function consolePush(text, kind) {
    const parts = String(text).split("\n");
    for (let i = 0; i < parts.length; i++) {
        consoleLines.push({ text: parts[i], kind: kind || "local" });
    }
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
    // A pending question is abandoned with the console; the player runs the
    // command again if they still want it.
    consolePrompt = null;
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

// Ask a question in the console. The next submitted line becomes the answer and
// goes to `action`, whose reply is printed like any other command's. This is the
// username prompt, so it opens the console to be typed into.
function consoleAsk(question, action) {
    consolePrompt = { question: question, action: action };
    if (!consoleOpen) consoleToggle();
    consoleInput = "";
    consoleCaret = 0;
    consolePush(question, "system");
}

// Run one submitted line: echo it, dispatch it, echo the reply.
function consoleSubmit(line) {
    const text = String(line).trim();
    if (text === "") return;
    if (consoleHistory.length === 0 || consoleHistory[consoleHistory.length - 1] !== text) {
        consoleHistory.push(text);
        if (consoleHistory.length > CONSOLE_HISTORY) consoleHistory.shift();
    }
    consoleHistoryAt = consoleHistory.length;
    consolePush("> " + text, "echo");

    // A pending question consumes the line instead of dispatching it.
    const prompt = consolePrompt;
    consolePrompt = null;
    let reply;
    try {
        reply = prompt !== null ? prompt.action(text) : sceneCommand(text);
    } catch (error) {
        reply = "error " + String(error);
    }
    const message = reply === undefined ? "ok" : String(reply);
    // An empty reply means "nothing to report" -- chat queues silently rather
    // than printing an `ok` after every line.
    if (message !== "") consolePush(message, "local");
    consoleInput = "";
    consoleCaret = 0;
}

// Reads the engine's clipboard. Without the binding, paste and copy say so
// rather than silently doing nothing.
function consoleClipboardAvailable() {
    return typeof rl.getClipboardText === "function" && typeof rl.setClipboardText === "function";
}

// Pasted text arrives as one line of printable characters: a ticket copied from
// a terminal comes with a newline, and a text field has no room for either.
function consoleSanitizePaste(text) {
    let out = "";
    for (const character of String(text)) {
        const code = character.codePointAt(0);
        if (code < 32 || code === 127) continue;
        out += character;
    }
    return out.trim();
}

// Ctrl+V: insert the clipboard at the caret.
function consolePaste() {
    if (typeof rl.getClipboardText !== "function") {
        consoleSystem("paste needs the engine's getClipboardText binding");
        return;
    }
    const text = consoleSanitizePaste(rl.getClipboardText());
    const room = CONSOLE_MAX_INPUT - consoleInput.length;
    if (text === "" || room <= 0) return;
    const insert = text.slice(0, room);
    consoleInput = consoleInput.slice(0, consoleCaret) + insert + consoleInput.slice(consoleCaret);
    consoleCaret += insert.length;
}

// Ctrl+C, or the `copy` verb: put text on the clipboard. Returns false when the
// engine has no clipboard, so a command can report it.
function consoleCopy(text) {
    if (typeof rl.setClipboardText !== "function") {
        consoleSystem("copy needs the engine's setClipboardText binding");
        return false;
    }
    const value = String(text);
    rl.setClipboardText(value);
    consoleSystem("copied " + value.length + " characters");
    return true;
}

// Read the character queue and the editing keys, once a frame while open.
function consoleHandleInput() {
    // Text: raylib queues one codepoint per key press, 0 once drained, so read
    // until empty. Only printable ASCII is accepted for now.
    if (typeof rl.getCharPressed === "function") {
        let code = rl.getCharPressed();
        while (code !== 0) {
            if (code >= 32 && code < 127 && consoleInput.length < CONSOLE_MAX_INPUT) {
                consoleInput = consoleInput.slice(0, consoleCaret) + String.fromCharCode(code) +
                    consoleInput.slice(consoleCaret);
                consoleCaret += 1;
            }
            code = rl.getCharPressed();
        }
    }
    // Clipboard. Ctrl+V is how a ticket gets in -- they are long, and typing one
    // correctly is not a reasonable thing to ask of anyone.
    const control = rl.isKeyDown(rl.KEY_LEFT_CONTROL) || rl.isKeyDown(rl.KEY_RIGHT_CONTROL);
    if (control && rl.isKeyPressed(rl.KEY_V)) consolePaste();
    if (control && rl.isKeyPressed(rl.KEY_C) && consoleInput.length > 0) consoleCopy(consoleInput);
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

// The width of a console row in pixels. `drawText` uses the default font at
// spacing 0, and `measureTextEx` measures the same font, so the two agree. A
// stub without it falls back to an estimate so the harness still wraps.
function consoleTextWidth(text, size) {
    if (typeof rl.measureTextEx === "function") {
        const measured = rl.measureTextEx(text, size, 0);
        if (measured !== undefined && measured !== null && typeof measured.x === "number") {
            return measured.x;
        }
    }
    return String(text).length * size * 0.55;
}

// Break one line into rows that fit `maxWidth`. Words stay whole; a single long
// token (a URL, a JSON blob) is split rather than run off the panel. The leading
// indentation is kept on every row, so columns stay lined up after a wrap.
function consoleWrap(text, maxWidth, size) {
    if (consoleTextWidth(text, size) <= maxWidth) return [text];
    const indent = (/^\s*/.exec(text) || [""])[0];
    const words = text.slice(indent.length).split(" ");
    const rows = [];
    let row = "";
    for (let i = 0; i < words.length; i++) {
        const word = words[i];
        const candidate = row === "" ? word : row + " " + word;
        if (consoleTextWidth(indent + candidate, size) <= maxWidth) {
            row = candidate;
            continue;
        }
        if (row !== "") rows.push(row);
        let rest = word;
        while (consoleTextWidth(indent + rest, size) > maxWidth && rest.length > 1) {
            let cut = rest.length - 1;
            while (cut > 1 && consoleTextWidth(indent + rest.slice(0, cut), size) > maxWidth) cut -= 1;
            rows.push(rest.slice(0, cut));
            rest = rest.slice(cut);
        }
        row = rest;
    }
    if (row !== "") rows.push(row);
    for (let i = 0; i < rows.length; i++) rows[i] = indent + rows[i];
    return rows;
}

// The overlay: a translucent panel over the top of the screen, the scrollback's
// last visible lines, then the input line with its caret.
function drawConsole() {
    const sw = rl.getScreenWidth();
    const sh = rl.getScreenHeight();
    const lineH = 18;
    const pad = 10;
    const maxRows = Math.max(3, Math.floor((sh * 0.5 - pad * 2 - lineH) / lineH));
    const maxWidth = Math.max(80, sw - pad * 2);
    // Wrap to display rows first, so a long reply or chat line never runs off,
    // then keep the last `maxRows` of them.
    const rows = [];
    for (let i = 0; i < consoleLines.length; i++) {
        const entry = consoleLines[i];
        const wrapped = consoleWrap(entry.text, maxWidth, lineH);
        for (let j = 0; j < wrapped.length; j++) {
            rows.push({ text: wrapped[j], kind: entry.kind });
        }
    }
    const count = Math.min(rows.length, maxRows);
    const first = rows.length - count;
    const panelH = Math.min(sh, pad * 2 + (count + 1) * lineH);
    rl.drawRectangle(0, 0, sw, panelH, rl.color(8, 10, 14, 215));
    let y = pad;
    for (let i = 0; i < count; i++) {
        const line = rows[first + i];
        rl.drawText(line.text, pad, y, lineH, CONSOLE_COLORS[line.kind] || CONSOLE_COLORS.input);
        y += lineH;
    }
    const before = consoleInput.slice(0, consoleCaret);
    const after = consoleInput.slice(consoleCaret);
    rl.drawText("> " + before + "|" + after, pad, y, lineH, CONSOLE_COLORS.input);
}
