// Part 12/16 of the goat scene: the main menu, settings, mods and keymap.
// ---- menus ----------------------------------------------------------------
//
// The UI is drawn with raygui (the engine builds its bindings as `rl.gui*`).
// ESC pauses the game and opens the main menu; ESC again, or Continue, resumes.
// While a screen is open the frame's `dt` is 0 and the game's input is ignored
// (see `uiScreen` in goat.js), so the world freezes behind the menu.

let uiScreen = "hud";   // "hud" | "main" | "settings" | "mods" | "keymap"

// The keymap screen's table.
const KEYMAP_ROWS = [
    ["W / S", "walk forward / back"],
    ["CTRL + W/S", "trot"],
    ["SHIFT + W/S", "run"],
    ["A / D", "turn left / right"],
    ["SPACE", "jump"],
    ["E", "eat the grass in reach"],
    ["Z", "sleep / wake"],
    ["R", "restart after death"],
    ["T (hold)", "fast-forward the clock"],
    ["C", "next weather"],
    ["L", "toggle lighting"],
    ["K", "cycle shadows"],
    ["B", "toggle the sky shader"],
    ["M", "mute audio"],
    ["F11", "toggle fullscreen"],
    ["Mouse drag", "orbit the camera"],
    ["Mouse wheel", "zoom"],
    ["Arrow keys", "orbit the camera"],
    ["P", "pause / resume"],
    ["`", "open / close the console"],
    ["ESC", "main menu / resume"],
];

const SHADOW_LIST = "None;Planar;Shadow map";
const CLOUD_LIST = "Low;Medium;High";

// A menu is showing: the world is frozen and the game ignores its input.
function uiIsOpen() {
    return uiScreen !== "hud";
}

// Game key presses are swallowed while a menu is open, or while the console is
// taking typed input.
function press(code) {
    return uiScreen === "hud" && !consoleOpen && rl.isKeyPressed(code);
}

// Push SETTINGS into the systems that own the behaviour.
function applySettings() {
    applyAudioSettings();
    if (litShader >= 0) {
        useLighting = SETTINGS.light;
        if (haveModel) rl.setModelShader(model, modelShaderFor(model, useLighting ? litShader : -1));
        setBotsShader(useLighting ? litShader : -1);
    }
    if (SETTINGS.shadow === 2 && !shadowMapReady) SETTINGS.shadow = 0;
    if (SETTINGS.shadow === 1 && shadowShader < 0) SETTINGS.shadow = 0;
    shadowMode = SETTINGS.shadow;
    if (skyShader >= 0) useSkyShader = SETTINGS.sky;
    if (typeof rl.toggleFullscreen === "function" &&
        typeof rl.isWindowFullscreen === "function" &&
        SETTINGS.fullscreen !== rl.isWindowFullscreen()) {
        rl.toggleFullscreen();
    }
}

// The subset of `applySettings` that is safe before the first frame: the shadow
// map only counts as ready once it has been rendered, so startup sets the mode
// directly rather than letting `applySettings` downgrade it.
function applyStartupSettings() {
    applyAudioSettings();
    useLighting = SETTINGS.light;
    if (litShader >= 0 && haveModel) rl.setModelShader(model, modelShaderFor(model, useLighting ? litShader : -1));
    setBotsShader(useLighting ? litShader : -1);
    if (skyShader >= 0) useSkyShader = SETTINGS.sky;
    shadowMode = SETTINGS.shadow;
}

function drawMainMenu(sw, sh) {
    const w = 300;
    const h = 306;
    const x = Math.round((sw - w) / 2);
    const y = Math.round((sh - h) / 2);
    rl.guiPanel(x, y, w, h, "Slag goat");
    const bx = x + 30;
    const bw = w - 60;
    const bh = 34;
    let by = y + 46;
    if (rl.guiButton(bx, by, bw, bh, sceneFrames > 0 ? "Continue" : "Play")) uiScreen = "hud";
    by += bh + 10;
    if (rl.guiButton(bx, by, bw, bh, "Settings")) uiScreen = "settings";
    by += bh + 10;
    if (rl.guiButton(bx, by, bw, bh, "Mods")) uiScreen = "mods";
    by += bh + 10;
    if (rl.guiButton(bx, by, bw, bh, "Keymap")) uiScreen = "keymap";
    by += bh + 10;
    if (rl.guiButton(bx, by, bw, bh, "Quit")) ctlQuit = true;
}

function drawSettings(sw, sh) {
    const w = 460;
    const h = 460;
    const x = Math.round((sw - w) / 2);
    const y = Math.round((sh - h) / 2);
    rl.guiPanel(x, y, w, h, "Settings");
    const lx = x + 20;
    const lw = w - 40;
    let cy = y + 44;

    rl.guiGroupBox(lx, cy, lw, 92, "Audio");
    cy += 26;
    const bgm = rl.guiSlider(lx + 10, cy, lw - 20, 24, "Music", "", SETTINGS.bgm, 0, 100);
    if (Math.round(bgm.value) !== SETTINGS.bgm) {
        SETTINGS.bgm = Math.round(bgm.value);
        applyAudioSettings();
    }
    cy += 30;
    const sfx = rl.guiSlider(lx + 10, cy, lw - 20, 24, "SFX", "", SETTINGS.sfx, 0, 100);
    if (Math.round(sfx.value) !== SETTINGS.sfx) SETTINGS.sfx = Math.round(sfx.value);
    cy += 46;

    rl.guiGroupBox(lx, cy, lw, 178, "Graphics");
    cy += 26;
    const light = rl.guiToggle(lx + 10, cy, lw - 20, 24, "Light", SETTINGS.light);
    if (light.value !== SETTINGS.light) {
        SETTINGS.light = light.value;
        applySettings();
    }
    cy += 30;
    const shCombo = rl.guiComboBox(lx + 10, cy, lw - 20, 24, SHADOW_LIST, SETTINGS.shadow);
    if (shCombo.value >= 0 && shCombo.value !== SETTINGS.shadow) {
        SETTINGS.shadow = shCombo.value;
        applySettings();
    }
    cy += 30;
    const sky = rl.guiToggle(lx + 10, cy, lw - 20, 24, "Sky shader", SETTINGS.sky);
    if (sky.value !== SETTINGS.sky) {
        SETTINGS.sky = sky.value;
        applySettings();
    }
    cy += 30;
    const clouds = rl.guiComboBox(lx + 10, cy, lw - 20, 24, CLOUD_LIST, SETTINGS.cloud);
    if (clouds.value >= 0 && clouds.value !== SETTINGS.cloud) {
        SETTINGS.cloud = clouds.value;
        applySettings();
    }
    cy += 30;
    const full = rl.guiToggle(lx + 10, cy, lw - 20, 24, "Fullscreen", SETTINGS.fullscreen);
    if (full.value !== SETTINGS.fullscreen) {
        SETTINGS.fullscreen = full.value;
        applySettings();
    }
    cy += 46;

    rl.guiGroupBox(lx, cy, lw, 66, "Gameplay");
    cy += 26;
    const herd = rl.guiSlider(lx + 10, cy, lw - 20, 24, "Herd size", "", TUNING.herd.count, 0, 10);
    if (Math.round(herd.value) !== TUNING.herd.count) {
        tuningSet("herd.count", Math.round(herd.value));
    }

    if (rl.guiButton(x + w / 2 - 60, y + h - 40, 120, 30, "Back")) uiScreen = "main";
}

// The Mods screen: what the host found, with a session-only toggle each. It
// writes the same flags `mod enable|disable` does, so the state agrees.
let modsNote = "";

function drawMods(sw, sh) {
    const w = 600;
    const h = 440;
    const x = Math.round((sw - w) / 2);
    const y = Math.round((sh - h) / 2);
    rl.guiPanel(x, y, w, h, "Mods");
    rl.guiLabel(x + 20, y + 34, w - 40, 18, "this session only - a restart restores the mods/ directory");
    const mods = goats.mods();
    let cy = y + 60;
    if (mods.length === 0) {
        rl.guiLabel(x + 20, cy, w - 40, 20, "no mods found - put them in mods/ next to the game");
    }
    for (let i = 0; i < mods.length && cy < y + h - 74; i++) {
        const meta = mods[i];
        const label = meta.name + " v" + meta.version + "  (" + meta.side + ")" +
            (meta.failed ? "  FAILED: " + meta.error : "");
        rl.guiLabel(x + 20, cy + 5, w - 190, 20, label);
        if (rl.guiButton(x + w - 150, cy, 130, 28, meta.enabled ? "Disable" : "Enable")) {
            const reply = modSetEnabled(meta.id, !meta.enabled);
            modsNote = reply.indexOf("error") === 0 ? reply.slice(6) : "";
        }
        cy += 34;
    }
    if (modsNote !== "") rl.guiLabel(x + 20, y + h - 62, w - 40, 18, modsNote);
    if (rl.guiButton(x + w / 2 - 60, y + h - 40, 120, 30, "Back")) uiScreen = "main";
}

function drawKeymap(sw, sh) {
    const w = 540;
    const h = 500;
    const x = Math.round((sw - w) / 2);
    const y = Math.round((sh - h) / 2);
    rl.guiPanel(x, y, w, h, "Keymap");
    const kx = x + 24;
    const ax = x + 200;
    const rowH = 21;
    let ry = y + 44;
    for (let i = 0; i < KEYMAP_ROWS.length; i++) {
        rl.guiLabel(kx, ry, 168, rowH, KEYMAP_ROWS[i][0]);
        rl.guiLabel(ax, ry, w - 224, rowH, KEYMAP_ROWS[i][1]);
        ry += rowH;
    }
    if (rl.guiButton(x + w / 2 - 60, y + h - 40, 120, 30, "Back")) uiScreen = "main";
}

// Draw the active screen: a dim over the frozen world, then the panel.
function drawUi() {
    const sw = rl.getScreenWidth();
    const sh = rl.getScreenHeight();
    rl.drawRectangle(0, 0, sw, sh, rl.color(0, 0, 0, 130));
    if (uiScreen === "main") drawMainMenu(sw, sh);
    else if (uiScreen === "settings") drawSettings(sw, sh);
    else if (uiScreen === "mods") drawMods(sw, sh);
    else if (uiScreen === "keymap") drawKeymap(sw, sh);
}
