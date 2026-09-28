// ---- touch controls (P1) --------------------------------------------------
//
// A phone's only input is its screen, and the scene's controls are a keyboard and
// a mouse: `goat.js` reads thirty `KEY_*` codes, a drag and a wheel, none of which
// exists on Android. This part is the bridge -- a stick, a jump button and a menu
// button -- and it is deliberately built out of the seams that were already there
// rather than a second input path:
//
//   * the stick writes `ctlHeld` (ctl.js), the same table a script's `walk` fills,
//     so `ctlKeyDown` layers it over the real keyboard with nothing new
//   * the buttons go through `sceneCommand` (`jump`, `ui main`), so a jump while
//     asleep is refused by the same rule the console's is, and the menu button
//     opens the screen `ESC` does
//   * the camera gets `touchPointer` -- the deltas a mouse drag would have
//     produced -- instead of reaching into `goat.js`'s camera
//
// The surface underneath is the client's `android` global
// (`crates/goats/src/android.rs`), installed only under
// `cfg(target_os = "android")`, so this part is inert everywhere else: no global,
// no controls drawn, and `touchPointer.present` stays false, which is what leaves
// the desktop's mouse path untouched. The guard is the same shape as the keymap's
// (`typeof rl.loadShaderFromMemory !== "function"`), asked per frame rather than at
// load because the harness installs its surface after the scene is evaluated.
//
// The rest of P1 is in `goat.js`: three lines of camera that read `touchPointer`,
// and the two calls below (`touchUpdate` before the input, `touchDraw` on the HUD).

// What `goat.js` reads for the camera and the zoom.
//
// `present` is whether the touch surface is the pointer this frame: on a phone
// raylib still feeds the mouse from `touch[0]`, so the mouse path must be off
// while the touch path is on, or a thumb on the stick would orbit the camera at
// the same time. `zoom` is the frame's pinch in the wheel's units, so one
// expression covers both.
const touchPointer = { present: false, dragging: false, dx: 0, dy: 0, zoom: 0 };

// How much a pixel of pinch is worth in wheel notches: a full sweep of the panel
// moves `camDist` across most of its range.
const TOUCH_PINCH = 0.02;
// The stick's dead zone, as a share of its radius: a thumb's shake inside this
// holds nothing, so the goat does not creep and the gait does not flicker.
const TOUCH_DEAD = 0.3;
// How far the stick is pushed decides the gait: past the first threshold is a
// trot, past the second a run. Between them and the dead zone is a walk.
const TOUCH_TROT = 0.55;
const TOUCH_RUN = 0.82;

// The geometry, in the screen pixels every `rl` 2D call uses. Only the fractions
// are tuned; the whole thing is rebuilt when the panel changes size, so a rotation
// or another device moves the controls rather than breaking them.
//
// The margin stands in for the phone's own edges -- the gesture bar and the
// camera's punch-hole are outside the app's control, and asking for their real
// insets needs the Java `Activity` that arrives with P2 (`android.insets()`, D1),
// so a fixed share of the short side will do until then.
let touchGeometry = null;

function touchLayout() {
    const w = rl.getScreenWidth();
    const h = rl.getScreenHeight();
    const key = w + "x" + h;
    if (touchGeometry !== null && touchGeometry.key === key) return touchGeometry;
    const k = Math.min(w, h);
    const margin = k * 0.09;
    const stickR = k * 0.13;
    const buttonR = k * 0.085;
    const menuR = k * 0.055;
    touchGeometry = {
        key: key,
        w: w,
        h: h,
        // Bottom-left, bottom-right and top-left: the HUD already uses the
        // bottom-centre for its text, the bottom-right corner for the Eat prompt
        // and the top-right for the health bars.
        stick: { x: Math.round(margin + stickR), y: Math.round(h - margin - stickR), r: Math.round(stickR) },
        jump: { x: Math.round(w - margin - buttonR), y: Math.round(h - margin - buttonR), r: Math.round(buttonR) },
        menu: { x: Math.round(margin + menuR), y: Math.round(margin + menuR), r: Math.round(menuR) },
        // A thumb lands *near* a control rather than on it, so the zone that claims
        // a touch is wider than what is drawn -- but only as wide as it can be
        // without reaching its neighbour: the drawing is the small circle.
        stickGrab: Math.round(stickR * 1.45),
        buttonGrab: Math.round(buttonR * 1.2),
    };
    return touchGeometry;
}

// The frame's pointers, in a fixed pool: this runs every frame and a hand holds a
// handful of fingers at most, so nothing here allocates. `index` is raylib's own
// index for the pointer, which `pinch` needs.
const TOUCH_MAX = 8;
const TOUCH_POINTS = [];
for (let i = 0; i < TOUCH_MAX; i++) TOUCH_POINTS.push({ x: 0, y: 0, id: -1, index: i });
let touchDown = 0;
const TOUCH_READ = { x: 0, y: 0, id: -1 };
// The ids that were down last frame, so a first sighting is a press.
const TOUCH_PREV = [];
for (let i = 0; i < TOUCH_MAX; i++) TOUCH_PREV.push(-1);
let touchPrevDown = 0;

// Which pointer owns what, by id (-1 for none). A finger keeps what it claimed
// until it lifts, whatever it does afterwards: a thumb that slides off the stick
// is still steering, and letting go is the only way to stop.
let touchStickId = -1;
const TOUCH_BUTTONS = { jump: -1, menu: -1 };
const TOUCH_STICK = { x: 0, y: 0 };      // the stick's deflection, -1..1 each way
let touchCamId = -1;
let touchCamX = 0;
let touchCamY = 0;
let touchSpreadLast = 0;
// The keys the stick is holding, with what `ctlHeld` held before it took them.
// Kept apart from `ctlHeld` so a release gives back what it found.
const TOUCH_TAKEN = {};
const TOUCH_PAIR = { a: -1, b: -1 };

// One frame of touch, before the frame reads any input.
function touchUpdate() {
    const layout = touchLayout();
    touchPointer.present = typeof android === "object" && android !== null;
    touchPointer.dragging = false;
    touchPointer.dx = 0;
    touchPointer.dy = 0;
    touchPointer.zoom = 0;

    if (touchPointer.present) touchRead();
    else touchDown = 0;

    // A menu or the console has the screen. Let go of everything rather than leave
    // the stick held behind it -- coming back from the menu to a goat already
    // walking is the kind of bug nobody reports.
    if (!touchPointer.present || uiScreen !== "hud" || consoleOpen) {
        touchRelease();
    } else {
        touchStick(layout);
        touchButtons(layout);
        touchCamera();
    }
    touchRemember();
}

// The controls, over the HUD and only there. Nothing is drawn without a touch
// surface, which is why the server's null `rl` needs no circle bindings.
function touchDraw() {
    if (!touchPointer.present || uiScreen !== "hud" || consoleOpen) return;
    const layout = touchLayout();
    const ink = rl.color(236, 238, 244, 200);
    const fill = rl.color(18, 20, 26, 90);
    const lit = rl.color(232, 201, 116, 235);

    // The stick: base, knob, and the knob is the deflection rather than the
    // finger, so it stops at the rim the way a physical stick does. The knob and
    // the label are rounded because they land on fractions of a pixel; the layout
    // itself is whole pixels already.
    rl.drawCircle(layout.stick.x, layout.stick.y, layout.stick.r, fill);
    rl.drawCircleLines(layout.stick.x, layout.stick.y, layout.stick.r, ink);
    rl.drawCircle(Math.round(layout.stick.x + TOUCH_STICK.x * layout.stick.r),
        Math.round(layout.stick.y + TOUCH_STICK.y * layout.stick.r),
        Math.round(layout.stick.r * 0.42), touchStickId >= 0 ? lit : ink);

    touchDrawButton(layout.jump, "jump", "JUMP", ink, fill, lit);
    touchDrawButton(layout.menu, "menu", "MENU", ink, fill, lit);
}

function touchDrawButton(spot, name, label, ink, fill, lit) {
    const held = TOUCH_BUTTONS[name] >= 0;
    rl.drawCircle(spot.x, spot.y, spot.r, fill);
    rl.drawCircleLines(spot.x, spot.y, spot.r, held ? lit : ink);
    const size = Math.round(spot.r * 0.5);
    rl.drawText(label, Math.round(spot.x - label.length * size * 0.3),
        Math.round(spot.y - size * 0.5), size, held ? lit : ink);
}

// The frame's pointers into the pool. `touchAt` is handed an object to fill, so
// this is a loop of reads rather than of allocations.
function touchRead() {
    const count = Math.min(android.touchCount() | 0, TOUCH_MAX);
    touchDown = 0;
    for (let i = 0; i < count; i++) {
        if (android.touchAt(i, TOUCH_READ) !== true) continue;
        const point = TOUCH_POINTS[touchDown];
        point.x = TOUCH_READ.x;
        point.y = TOUCH_READ.y;
        point.id = TOUCH_READ.id;
        point.index = i;
        touchDown += 1;
    }
}

function touchRemember() {
    for (let i = 0; i < touchDown; i++) TOUCH_PREV[i] = TOUCH_POINTS[i].id;
    touchPrevDown = touchDown;
}

// Whether this pointer was already down when the frame began, which is what tells
// a press -- a button, or a grab of the stick -- from a finger being held.
function touchWasDown(id) {
    if (id < 0) return false;
    for (let i = 0; i < touchPrevDown; i++) {
        if (TOUCH_PREV[i] === id) return true;
    }
    return false;
}

function touchSeek(id) {
    if (id < 0) return -1;
    for (let i = 0; i < touchDown; i++) {
        if (TOUCH_POINTS[i].id === id) return i;
    }
    return -1;
}

function touchInside(point, spot, grab) {
    const dx = point.x - spot.x;
    const dy = point.y - spot.y;
    return dx * dx + dy * dy <= grab * grab;
}

// A pointer is taken if a control owns it; everything else is the camera's to use.
function touchTaken(id) {
    return id === touchStickId || id === TOUCH_BUTTONS.jump || id === TOUCH_BUTTONS.menu;
}

// The stick: claim a finger that goes down in the zone, then follow it. The claim
// is on the *down* edge so a finger dragged in from the camera's half of the
// screen keeps orbiting instead of taking the stick away mid-drag.
function touchStick(layout) {
    let owner = touchSeek(touchStickId);
    if (owner < 0) {
        touchStickId = -1;
        for (let i = 0; i < touchDown; i++) {
            const point = TOUCH_POINTS[i];
            if (touchWasDown(point.id)) continue;
            if (touchTaken(point.id)) continue;
            if (!touchInside(point, layout.stick, layout.stickGrab)) continue;
            touchStickId = point.id;
            owner = i;
            break;
        }
    }
    if (owner < 0) {
        TOUCH_STICK.x = 0;
        TOUCH_STICK.y = 0;
        touchStickKeys(0, 0);
        return;
    }
    const point = TOUCH_POINTS[owner];
    const dx = clamp((point.x - layout.stick.x) / layout.stick.r, -1, 1);
    const dy = clamp((point.y - layout.stick.y) / layout.stick.r, -1, 1);
    TOUCH_STICK.x = dx;
    TOUCH_STICK.y = dy;
    touchStickKeys(dx, dy);
}

// The deflection as the keys everything else already reads. Screen `y` grows
// downwards, so a push up is negative, and `A`/`D` are the turn keys rather than
// strafe: this is the same pair `goat.js` reads for the keyboard.
function touchStickKeys(dx, dy) {
    const push = Math.sqrt(dx * dx + dy * dy);
    touchHold(rl.KEY_W, dy < -TOUCH_DEAD);
    touchHold(rl.KEY_S, dy > TOUCH_DEAD);
    touchHold(rl.KEY_A, dx < -TOUCH_DEAD);
    touchHold(rl.KEY_D, dx > TOUCH_DEAD);
    touchHold(rl.KEY_LEFT_CONTROL, push > TOUCH_TROT);
    touchHold(rl.KEY_LEFT_SHIFT, push > TOUCH_RUN);
}

// Hold or release one key in `ctlHeld`, remembering what the table held before
// the touch took it. A release puts that back, so a script's `walk` -- which writes
// the same table -- survives a thumb lifting off the stick. (A script that issues
// `walk` *while* the stick is held still loses it on the release; the table has no
// way to know about two owners.)
function touchHold(code, down) {
    if (down) {
        if (!(code in TOUCH_TAKEN)) TOUCH_TAKEN[code] = ctlHeld[code] === true;
        ctlHeld[code] = true;
    } else if (code in TOUCH_TAKEN) {
        const had = TOUCH_TAKEN[code];
        delete TOUCH_TAKEN[code];
        if (had) ctlHeld[code] = true;
        else delete ctlHeld[code];
    }
}

// The buttons, each on its own finger's down edge.
function touchButtons(layout) {
    if (touchPress(layout.jump, layout.buttonGrab, "jump")) sceneCommand("jump");
    if (touchPress(layout.menu, layout.buttonGrab, "menu")) sceneCommand("ui main");
}

function touchPress(spot, grab, name) {
    // A held button is released when its finger lifts, and only then can it fire
    // again: the action behind each is a one-shot, not a hold.
    if (TOUCH_BUTTONS[name] >= 0 && touchSeek(TOUCH_BUTTONS[name]) < 0) TOUCH_BUTTONS[name] = -1;
    if (TOUCH_BUTTONS[name] >= 0) return false;
    for (let i = 0; i < touchDown; i++) {
        const point = TOUCH_POINTS[i];
        if (touchWasDown(point.id)) continue;
        if (touchTaken(point.id)) continue;
        if (!touchInside(point, spot, grab)) continue;
        TOUCH_BUTTONS[name] = point.id;
        return true;
    }
    return false;
}

// The camera drag and the pinch, handed to `goat.js` through `touchPointer`.
function touchCamera() {
    // The first free finger, followed by id: the indices shift when a finger in
    // the middle of the list lifts, and a drag that jumped to a different finger
    // would swing the view.
    let owner = touchSeek(touchCamId);
    if (owner < 0) {
        touchCamId = -1;
        for (let i = 0; i < touchDown; i++) {
            const point = TOUCH_POINTS[i];
            if (touchTaken(point.id)) continue;
            touchCamId = point.id;
            owner = i;
            break;
        }
    }
    if (owner >= 0) {
        const point = TOUCH_POINTS[owner];
        // No delta on the frame it arrives: there is no previous position yet, and
        // a drag measured from wherever the last finger left off would jump.
        if (touchWasDown(point.id)) {
            touchPointer.dragging = true;
            touchPointer.dx = point.x - touchCamX;
            touchPointer.dy = point.y - touchCamY;
        }
        touchCamX = point.x;
        touchCamY = point.y;
    }

    // Two free fingers are a pinch. The client names the pair rather than assuming
    // the first two pointers, because one of those is often a thumb on the stick.
    // The spread is a distance and not a delta, so a frame where the second finger
    // has only just landed -- 0 to 200 and back -- is not a gesture, and is skipped
    // by asking that both frames had one.
    const pair = touchFreePair();
    const spread = pair === null ? 0 : android.pinch(pair.a, pair.b);
    if (spread > 0 && touchSpreadLast > 0) {
        touchPointer.zoom += (spread - touchSpreadLast) * TOUCH_PINCH;
    }
    touchSpreadLast = spread;
}

// The two lowest-indexed pointers no control owns, or null when there are not two.
function touchFreePair() {
    TOUCH_PAIR.a = -1;
    TOUCH_PAIR.b = -1;
    for (let i = 0; i < touchDown; i++) {
        const point = TOUCH_POINTS[i];
        if (touchTaken(point.id)) continue;
        if (TOUCH_PAIR.a < 0) TOUCH_PAIR.a = point.index;
        else {
            TOUCH_PAIR.b = point.index;
            break;
        }
    }
    return TOUCH_PAIR.b >= 0 ? TOUCH_PAIR : null;
}

// Let go of everything. Called when the controls are not on screen, and when the
// surface goes away.
function touchRelease() {
    touchStickId = -1;
    TOUCH_BUTTONS.jump = -1;
    TOUCH_BUTTONS.menu = -1;
    TOUCH_STICK.x = 0;
    TOUCH_STICK.y = 0;
    touchCamId = -1;
    touchSpreadLast = 0;
    for (const code in TOUCH_TAKEN) {
        if (TOUCH_TAKEN[code] === true) ctlHeld[code] = true;
        else delete ctlHeld[code];
        delete TOUCH_TAKEN[code];
    }
}
