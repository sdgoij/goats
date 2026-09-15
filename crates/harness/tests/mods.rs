//! The ported mod cases: `goat_logic_test.js`'s five `mod*Test` blocks, plus the
//! `mods/example` fixture that `tools/mod_smoke_test.js` loaded from disk.
//!
//! These stage their own mod tables and entry wrappers on top of a short run --
//! they need the scene loaded and ready, not the long scripted timeline -- so
//! they are their own test and stay cheap.
//!
//! The fixture block runs last of the ported blocks on purpose: `goats.freeze()`
//! is one-way in the scene, and the table block is the one that asserts it was
//! open before it froze, so an entry earlier in the file would turn that case
//! into a lie.
//!
//! The post-freeze-add block (M18d) runs after even that, because a mod arriving
//! after the freeze is exactly its subject.
//!
//! The `goats` handle is a top-level `const` rather than a property of any object,
//! which is why the Node harness probed the lifecycle through `vm.runInContext`.
//! Here it is [`Harness::eval`], whose direct `eval` sits in the scene's own
//! lexical scope, so `goats` resolves exactly as it does inside the host's
//! wrapper.

mod support;

use harness::Harness;
use serde_json::json;
use support::{Checks, bool_of, f64_of, net_feed, throws, try_command_json};

/// Enough frames for the scene to load and settle. The mod cases drive the rest
/// themselves.
const SHORT: u32 = 60;

#[test]
fn the_mod_surface_works() {
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(SHORT).expect("run the scene");
    let mut checks = Checks::new();

    let table = staged("the mod table block", table_block(&mut harness));
    checks.check(
        "mods list and describe the pushed table",
        table.listed && table.info,
        &table,
    );
    checks.check("mod key lists the world set", table.key, &table);
    checks.check(
        "mod disable queues a host intent and flips the flag",
        table.queued && table.disabled && table.empty,
        &table,
    );
    checks.check("mod rejects an unknown id", table.unknown, &table);
    checks.check(
        "mod lifecycle: wrapper, freeze, end",
        table.lifecycle,
        &table,
    );

    let api = staged("the hook-API block", api_block(&mut harness));
    checks.check("mod command registers and dispatches", api.command, &api);
    checks.check(
        "mod command observer sees free-form lines",
        api.observer,
        &api,
    );
    checks.check("built-in commands win over mods", api.builtin_wins, &api);
    checks.check("mod events fire from the frame loop", api.frames, &api);
    checks.check("mod tuning hook sees a change", api.tune_event, &api);
    checks.check("mod accessors read live state", api.accessors, &api);
    checks.check(
        "mod freeze gates late registration",
        api.late_rejected,
        &api,
    );
    checks.check("mod rejects a reserved command name", api.reserved, &api);

    let reg = staged("the content-registry block", reg_block(&mut harness));
    checks.check(
        "mod declared assets re-point their slots",
        reg.slot_applied && reg.override_ && reg.slots_listed,
        &reg,
    );
    checks.check(
        "mod registers a bot archetype and a gait",
        reg.bots_registered && reg.gait,
        &reg,
    );
    checks.check(
        "mod clip assets are refused with a message",
        reg.asset_refused,
        &reg,
    );

    let world = staged("the world-extension block", world_block(&mut harness));
    checks.check(
        "mod world stream re-derives from the seed",
        world.same_stream && world.seeded,
        &world,
    );
    checks.check(
        "mod world publish reaches the snapshot",
        world.publish,
        &world,
    );
    checks.check(
        "mod world apply and stream adoption",
        world.apply && world.adopt,
        &world,
    );
    checks.check(
        "a world mod is what makes the mods datagram worth sending",
        world.active,
        &world,
    );
    checks.check(
        "publishRows rounds rows of finite numbers",
        world.rows,
        &world,
    );
    checks.check(
        "publishRows refuses a NaN and a row that is not one",
        world.rows_refused,
        &world,
    );
    checks.check(
        "a client applies the mods event on its own datagram",
        world.event,
        &world,
    );

    let menu = staged("the mods-screen block", menu_block(&mut harness));
    checks.check(
        "the mods screen opens and draws a row per mod",
        menu.screen && menu.draws,
        &menu,
    );
    checks.check(
        "mod enable/disable flips the flag and queues the intent",
        menu.disabled && menu.enabled,
        &menu,
    );
    checks.check(
        "mod enable/disable rejects an unknown or missing id",
        menu.unknown && menu.no_id,
        &menu,
    );
    checks.check(
        "a world mod is fixed once in a session, a client one is not",
        menu.offline_world && menu.world_guard && menu.client_in_session,
        &menu,
    );
    checks.check("a reload re-merges the mod tuning", menu.retune, &menu);

    let fixture = staged("the example-fixture block", fixture_block(&mut harness));
    checks.check(
        "the fixture's manifest is well-formed",
        fixture.manifest,
        &fixture,
    );
    checks.check(
        "the fixture's declared asset is a real wav",
        fixture.asset,
        &fixture,
    );
    checks.check("the fixture's table installs", fixture.installed, &fixture);
    checks.check(
        "the fixture is listed and enabled",
        fixture.listed,
        &fixture,
    );
    checks.check(
        "the fixture's declared asset re-points its slot",
        fixture.slot,
        &fixture,
    );
    checks.check(
        "the fixture's tuning.json merges a known leaf",
        fixture.tuning,
        &fixture,
    );
    checks.check(
        "an unknown tuning path warns, not fails",
        fixture.typo,
        &fixture,
    );
    checks.check(
        "the fixture's command dispatches",
        fixture.command,
        &fixture,
    );
    checks.check(
        "a built-in still wins over the fixture",
        fixture.builtin,
        &fixture,
    );
    checks.check("the fixture's hud hook runs", fixture.hud, &fixture);
    checks.check(
        "a throwing handler does not abort the frame",
        fixture.isolated,
        &fixture,
    );
    checks.check(
        "the throwing handler is reported",
        fixture.reported,
        &fixture,
    );
    checks.check(
        "a reload leaves exactly one hud handler",
        fixture.reload_hud,
        &fixture,
    );
    checks.check(
        "a reload leaves the command registered once",
        fixture.reload_command,
        &fixture,
    );

    let added = staged("the post-freeze-add block", added_block(&mut harness));
    checks.check(
        "a mod can be added after the freeze",
        added.added && added.listed && added.key,
        &added,
    );
    checks.check(
        "a late mod's assets and tuning land as the boot table's did",
        added.slot && added.tuning,
        &added,
    );
    checks.check(
        "a late mod's entry registers through the window it is given",
        added.command,
        &added,
    );
    checks.check(
        "the freeze still holds for everything but the mod being added",
        added.frozen && added.closed,
        &added,
    );
    checks.check(
        "a duplicate id is refused rather than doubled",
        added.duplicate && added.unreadable,
        &added,
    );

    checks.finish();
}

// ---- the fixtures ---------------------------------------------------------

const TABLE_TWO: &str = r#"[
    {"id":"com.a.client","name":"Client Thing","version":"1.0.0","api":1,"side":"client","enabled":true,"hash":"0000000000000001"},
    {"id":"com.b.world","name":"World Thing","version":"2.0.0","api":1,"side":"world","enabled":true,"hash":"0000000000000002"}
]"#;

const TABLE_HOOKS: &str = r#"[{"id":"com.hooks","name":"Hooks","version":"1.0.0","api":1,"side":"client","enabled":true,"hash":"0"}]"#;

const TABLE_PACK: &str = r#"[{"id":"com.pack","name":"Pack","version":"1","api":1,"side":"client","enabled":true,"hash":"0","assets":{"model.goat":"mod:com.pack:model.goat","sfx.music":"mod:com.pack:sfx.music"}}]"#;

const TABLE_WORLD: &str =
    r#"[{"id":"com.w","name":"W","version":"1","api":1,"side":"world","enabled":true,"hash":"0"}]"#;

const TABLE_MENU: &str = r#"[
    {"id":"com.e.client","name":"Client pack","version":"1","api":1,"side":"client","enabled":true,"hash":"0"},
    {"id":"com.e.world","name":"World pack","version":"1","api":1,"side":"world","enabled":true,"hash":"0"}
]"#;

/// A wrapped entry as the host evaluates one: a scoped IIFE handed the per-mod
/// handle. This is the full hook surface in one registration.
const HOOKS_ENTRY: &str = r#"(function (goats) {
    globalThis.__stashed = goats;
    globalThis.__seen = {};
    goats.command("dance", function (parts) { return "ok danced " + (parts[1] || "once"); });
    goats.on("update", function () { globalThis.__seen.update = true; });
    goats.on("draw3d", function () { globalThis.__seen.draw3d = true; });
    goats.on("hud", function () { globalThis.__seen.hud = true; });
    goats.on("draw", function () { globalThis.__seen.draw = true; });
    goats.on("tuning", function (path, value) { globalThis.__seen.tuning = path + "=" + value; });
    goats.on("command", function (raw) { if (raw.indexOf("zzz") === 0) return "ok observed"; });
})(goats.begin("com.hooks"))"#;

const PACK_ENTRY: &str = r#"(function (goats) {
    globalThis.__specBefore = goats.tuning.get("herd.spec").length;
    goats.bots.register("giant", { coat: [10, 20, 30], scale: 2.0, bold: 0.8, lazy: 0.4 });
    globalThis.__specAfter = goats.tuning.get("herd.spec").length;
    goats.clips.register("run", { gait: { stride: 0.6, duty: 0.4 } });
    goats.assets.override("sfx.rain", "mod:com.pack:sfx.rain");
})(goats.begin("com.pack"))"#;

const WORLD_ENTRY: &str = r#"(function (goats) {
    globalThis.__g = goats;
    globalThis.__rngA = goats.world.registerStream("sprint", 7);
    globalThis.__rngB = goats.rng("sprint");
    goats.world.extend("com.w", {
        publish: function () { return { n: 42 }; },
        apply: function (state) { globalThis.__applied = state; }
    });
})(goats.begin("com.w"))"#;

/// Draws the Mods screen with the raygui calls counted, then puts them back. The
/// counts are how the screen's shape is checked: one panel, a row per mod and one
/// Back button.
const DRAW_MODS_PROBE: &str = r#"(function () {
    const realPanel = rl.guiPanel, realLabel = rl.guiLabel, realButton = rl.guiButton;
    let panel = 0, label = 0, button = 0;
    rl.guiPanel = function () { panel += 1; };
    rl.guiLabel = function () { label += 1; };
    rl.guiButton = function () { button += 1; return false; };
    drawMods(600, 440);
    rl.guiPanel = realPanel; rl.guiLabel = realLabel; rl.guiButton = realButton;
    return { panel: panel, label: label, button: button };
})()"#;

/// The queued mod intents, drained.
fn mod_drain(harness: &mut Harness) -> Result<String, String> {
    let value = harness.call("sceneModDrain", &[])?;
    Ok(value.as_str().unwrap_or("").to_string())
}

// ---- the blocks -----------------------------------------------------------

/// Runs a block, or reports why it stopped and hands back an all-false result, so
/// that block's cases fail while the rest of the test still runs.
fn staged<T: Default>(name: &str, block: Result<T, String>) -> T {
    match block {
        Ok(block) => block,
        Err(error) => {
            eprintln!("{name}: {error}");
            T::default()
        }
    }
}

/// What the mod-table cases found. One field per case, plus the error that
/// stopped the block if one did.
#[derive(Debug, Default)]
struct ModTable {
    listed: bool,
    info: bool,
    key: bool,
    queued: bool,
    disabled: bool,
    empty: bool,
    unknown: bool,
    // The lifecycle's four facts, kept apart so a failure says which one broke.
    wrapped: bool,
    frozen_before: bool,
    frozen_after: bool,
    loaded_before: bool,
    loaded_after: bool,
    lifecycle: bool,
}

/// The host pushes a metadata table; the scene lists it and queues
/// enable/disable/reload intents for the host.
fn table_block(harness: &mut Harness) -> Result<ModTable, String> {
    let mut mods = ModTable::default();
    harness.call("sceneMods", &[json!(TABLE_TWO)])?;

    let list = try_command_json(harness, "mod list")?;
    mods.listed = list.as_array().is_some_and(|rows| {
        rows.len() == 2
            && rows[0]["id"] == json!("com.a.client")
            && rows[1]["side"] == json!("world")
    });
    let info = try_command_json(harness, "mod info com.b.world")?;
    mods.info = info["side"] == json!("world")
        && info["version"] == json!("2.0.0")
        && info["hash"] == json!("0000000000000002")
        && info["loaded"] == json!(false);
    let key = try_command_json(harness, "mod key")?;
    mods.key = key.as_array().is_some_and(|rows| {
        rows.len() == 1 && rows[0] == json!("com.b.world@2.0.0#0000000000000002")
    });

    // Disabling flips the flag now and queues the unload for the host.
    let reply = harness.command("mod disable com.b.world")?;
    let drained = mod_drain(harness)?;
    mods.queued = reply == "ok mod disable com.b.world" && drained.contains("\"type\":\"disable\"");
    let after = try_command_json(harness, "mod list")?;
    mods.disabled = after
        .as_array()
        .and_then(|rows| rows.get(1))
        .is_some_and(|row| row["enabled"] == json!(false));
    mods.empty = mod_drain(harness)?.is_empty();
    mods.unknown = harness.command("mod info nope")? == "error unknown mod: nope";

    // A wrapped entry, exactly as the host evaluates it.
    harness.eval(
        "(function (goats) { goats.log(\"wrapped entry\"); })(goats.begin(\"com.a.client\"));",
    )?;
    let logs = harness.observe()?.logs;
    mods.wrapped = logs
        .iter()
        .any(|line| line.contains("[mod:com.a.client] wrapped entry"));

    mods.frozen_before = bool_of(harness.eval("goats.frozen()")?);
    harness.eval("goats.freeze()")?;
    mods.frozen_after = bool_of(harness.eval("goats.frozen()")?);
    // The four facts, raw: `lifecycle` is the comparison, so a failure says which
    // one broke.
    mods.loaded_before =
        try_command_json(harness, "mod info com.a.client")?["loaded"] == json!(true);
    harness.eval("goats.end(\"com.a.client\")")?;
    mods.loaded_after =
        try_command_json(harness, "mod info com.a.client")?["loaded"] == json!(true);
    mods.lifecycle = mods.wrapped
        && !mods.frozen_before
        && mods.frozen_after
        && mods.loaded_before
        && !mods.loaded_after;
    Ok(mods)
}

/// What the hook-API cases found.
#[derive(Debug, Default)]
struct ModApi {
    command: bool,
    observer: bool,
    builtin_wins: bool,
    frames: bool,
    tune_event: bool,
    accessors: bool,
    late_rejected: bool,
    reserved: bool,
}

/// A wrapped entry registers a command and handlers; the command dispatches, the
/// frame loop emits the events, the accessors read live state, and freeze gates
/// registration once the window has closed.
fn api_block(harness: &mut Harness) -> Result<ModApi, String> {
    let mut api = ModApi::default();
    harness.call("sceneMods", &[json!(TABLE_HOOKS)])?;
    harness.eval(HOOKS_ENTRY)?;
    harness.call(
        "sceneModResult",
        &[json!("com.hooks"), json!(true), json!("")],
    )?;

    api.command = harness.command("dance twice")? == "ok danced twice";
    api.observer = harness.command("zzz hi")? == "ok observed";
    api.builtin_wins = harness.command("ping")? == "ok pong";

    // The tuning hook fires synchronously from `tuningSet`.
    harness.eval("goats.tuning.set(\"stats.max\", 111)")?;
    api.tune_event = harness.eval("globalThis.__seen.tuning")? == json!("stats.max=111");
    harness.eval("goats.tuning.set(\"stats.max\", 100)")?;

    // One real frame drives update/draw3d/hud/draw. The scripted run left the
    // stub's frame counter at its end, which would make `windowShouldClose` true,
    // so it is reset for this frame.
    harness.reset_frame()?;
    harness.call("sceneFrame", &[])?;
    api.frames = bool_of(harness.eval(
        "globalThis.__seen.update && globalThis.__seen.draw3d && globalThis.__seen.hud && globalThis.__seen.draw",
    )?);

    // The accessors read the live scene.
    let state = harness.eval("JSON.stringify(goats.player.state())")?;
    api.accessors = state
        .as_str()
        .is_some_and(|json| json.contains("\"mode\"") && json.contains("\"health\""))
        && bool_of(harness.eval("goats.camera.get().dist > 0")?)
        && bool_of(harness.eval("goats.bots.count() === goats.bots.list().length")?)
        && bool_of(harness.eval("goats.world.weather().kind !== undefined")?)
        && bool_of(harness.eval("typeof goats.settings.get().bgm === \"number\"")?)
        && bool_of(harness.eval("goats.net.inSession() === false")?);

    // Freeze gates registration once the entry window has closed.
    api.late_rejected = throws(
        harness,
        "globalThis.__stashed.on(\"update\", function () {})",
    );
    // A reserved (built-in) command name is refused.
    api.reserved = throws(
        harness,
        "(function (goats) { goats.command(\"help\", function () {}); })(goats.begin(\"com.hooks\"))",
    );
    harness.call(
        "sceneModResult",
        &[json!("com.hooks"), json!(false), json!("reserved")],
    )?;
    Ok(api)
}

/// What the content-registry cases found.
#[derive(Debug, Default)]
struct ModReg {
    slot_applied: bool,
    slots_listed: bool,
    bots_registered: bool,
    gait: bool,
    override_: bool,
    asset_refused: bool,
}

/// A declared asset re-points its slot when the table is pushed, and a mod adds a
/// bot archetype, a gait and an explicit override while its entry window is open.
fn reg_block(harness: &mut Harness) -> Result<ModReg, String> {
    let mut reg = ModReg::default();
    harness.call("sceneMods", &[json!(TABLE_PACK)])?;

    reg.slot_applied = harness.eval("goats.assets.get(\"model.goat\")")?
        == json!("mod:com.pack:model.goat")
        && harness.eval("goats.assets.get(\"sfx.music\")")? == json!("mod:com.pack:sfx.music");
    reg.slots_listed = bool_of(harness.eval("goats.assets.slots().indexOf(\"sfx.rain\") >= 0")?);

    harness.eval(PACK_ENTRY)?;
    harness.call(
        "sceneModResult",
        &[json!("com.pack"), json!(true), json!("")],
    )?;
    reg.bots_registered = bool_of(harness.eval(
        "globalThis.__specAfter === globalThis.__specBefore + 1 && goats.tuning.get(\"herd.spec\")[globalThis.__specBefore].name === \"giant\"",
    )?);
    reg.gait = bool_of(harness.eval(
        "goats.tuning.get(\"gait.run.stride\") === 0.6 && goats.tuning.get(\"gait.run.duty\") === 0.4",
    )?);
    reg.override_ =
        harness.eval("goats.assets.get(\"sfx.rain\")")? == json!("mod:com.pack:sfx.rain");
    harness.eval(
        "goats.tuning.set(\"gait.run.stride\", 0.50); goats.tuning.set(\"gait.run.duty\", 0.34);",
    )?;

    // A clip's asset is refused with an actionable message until the model work.
    reg.asset_refused = throws(
        harness,
        "(function (goats) { goats.clips.register(\"run\", { asset: \"x\" }); })(goats.begin(\"com.pack\"))",
    );
    harness.call(
        "sceneModResult",
        &[json!("com.pack"), json!(false), json!("asset")],
    )?;
    Ok(reg)
}

/// What the world-extension cases found.
#[derive(Debug, Default)]
struct ModWorld {
    same_stream: bool,
    seeded: bool,
    publish: bool,
    apply: bool,
    adopt: bool,
    active: bool,
    rows: bool,
    rows_refused: bool,
    event: bool,
}

/// A `side: "world"` mod owns a seeded stream and publishes into the snapshot; the
/// host builds it and a client applies it.
fn world_block(harness: &mut Harness) -> Result<ModWorld, String> {
    let mut world = ModWorld::default();
    harness.call("sceneMods", &[json!(TABLE_WORLD)])?;
    harness.eval(WORLD_ENTRY)?;
    harness.call("sceneModResult", &[json!("com.w"), json!(true), json!("")])?;

    // A world mod means there is something to put on the mods datagram, which is
    // what gates sending one at all.
    world.active = bool_of(harness.eval("modWorldActive()")?);

    // `registerStream`'s handle and `goats.rng` draw from the same seeded stream.
    harness.call("sceneUseSeed", &[json!(1234)])?;
    let via_register = f64_of(harness.eval("globalThis.__rngA()")?);
    harness.call("sceneUseSeed", &[json!(1234)])?;
    let via_rng = f64_of(harness.eval("globalThis.__rngB()")?);
    world.same_stream = via_register == via_rng && via_register != 0.0;

    // A fresh draw re-derives deterministically from the session seed.
    harness.call("sceneUseSeed", &[json!(1234)])?;
    let first = f64_of(harness.eval("globalThis.__g.rng(\"sprint\")()")?);
    harness.call("sceneUseSeed", &[json!(1234)])?;
    let second = f64_of(harness.eval("globalThis.__g.rng(\"sprint\")()")?);
    world.seeded = first == second && first != 0.0;

    // The host's contribution carries the published data and the stream state.
    let published = harness.eval("JSON.stringify(sceneWorldMods())")?;
    let published: serde_json::Value = published
        .as_str()
        .and_then(|json| serde_json::from_str(json).ok())
        .unwrap_or(serde_json::Value::Null);
    world.publish = published["data"]["com.w"]["n"] == json!(42)
        && !published["streams"]["com.w:sprint"].is_null();

    // A client applies the host's contribution and adopts its stream state.
    harness.eval(
        "sceneApplyWorldMods({ streams: { \"com.w:sprint\": 999 }, data: { \"com.w\": { n: 7 } } });",
    )?;
    world.apply = harness.eval("globalThis.__applied.n")? == json!(7);
    world.adopt = harness.eval("sceneWorldMods().streams[\"com.w:sprint\"]")? == json!(999);

    // The compact publish path: rows of finite numbers, rounded to three
    // decimals so a row costs what it should.
    world.rows = bool_of(harness.eval(
        "JSON.stringify(globalThis.__g.world.publishRows([[1.23456, -2.0], [0.5]])) \
         === \"[[1.235,-2],[0.5]]\"",
    )?);
    // A value `JSON.stringify` would have written as `null` is refused here,
    // where the log can name the mod, rather than arriving at every peer as
    // `null`. So is a row that is not a row.
    let not_a_number = throws(harness, "globalThis.__g.world.publishRows([[1, NaN]])");
    let not_rows = throws(harness, "globalThis.__g.world.publishRows(\"nope\")");
    let not_a_row = throws(harness, "globalThis.__g.world.publishRows([[1], [2], 3])");
    world.rows_refused = not_a_number && not_rows && not_a_row;

    // And the host's state reaches a client as its own event, which is the
    // datagram the transport carries it on.
    net_feed(
        harness,
        r#"{"type":"mods","mods":{"streams":{"com.w:sprint":1234},"data":{"com.w":{"n":9}}}}"#,
    )?;
    world.event = harness.eval("globalThis.__applied.n")? == json!(9)
        && harness.eval("sceneWorldMods().streams[\"com.w:sprint\"]")? == json!(1234);
    Ok(world)
}

/// What the Mods-screen cases found.
#[derive(Debug, Default)]
struct ModMenu {
    screen: bool,
    disabled: bool,
    enabled: bool,
    unknown: bool,
    no_id: bool,
    offline_world: bool,
    world_guard: bool,
    client_in_session: bool,
    draws: bool,
    retune: bool,
}

/// The screen is reachable from `ui`, and `modSetEnabled` is exactly the
/// session-only toggle its buttons call. A world mod may not change mid-session,
/// because the host fixed that set at join.
fn menu_block(harness: &mut Harness) -> Result<ModMenu, String> {
    let mut menu = ModMenu::default();
    harness.call("sceneMods", &[json!(TABLE_MENU)])?;

    menu.screen =
        harness.command("ui mods")? == "ok ui mods" && harness.command("ui")? == "ok mods";

    // A client toggle flips the flag and queues the host intent in lockstep.
    let off = harness.eval("modSetEnabled(\"com.e.client\", false)")?;
    menu.disabled = off == json!("ok mod disable com.e.client")
        && harness.eval("goats.mods()[0].enabled")? == json!(false)
        && mod_drain(harness)?.contains("\"type\":\"disable\"");
    let on = harness.eval("modSetEnabled(\"com.e.client\", true)")?;
    menu.enabled = on == json!("ok mod enable com.e.client")
        && harness.eval("goats.mods()[0].enabled")? == json!(true)
        && mod_drain(harness)?.contains("\"type\":\"enable\"");
    menu.unknown =
        harness.eval("modSetEnabled(\"nope\", true)")? == json!("error unknown mod: nope");
    menu.no_id = harness
        .eval("modSetEnabled(undefined, true)")?
        .as_str()
        .is_some_and(|reply| reply.starts_with("error"));

    // Offline a world mod toggles like any other.
    menu.offline_world = harness.eval("modSetEnabled(\"com.e.world\", false)")?
        == json!("ok mod disable com.e.world");
    harness.eval("modSetEnabled(\"com.e.world\", true)")?;
    mod_drain(harness)?;

    // In a session the world set is fixed, so a world toggle is refused and the
    // flag is left untouched; a client mod still toggles.
    net_feed(harness, r#"{"type":"hosting","name":"bob"}"#)?;
    let refused = harness.eval("modSetEnabled(\"com.e.world\", false)")?;
    menu.world_guard = refused
        .as_str()
        .is_some_and(|reply| reply.starts_with("error") && reply.contains("world"))
        && harness.eval("goats.mods()[1].enabled")? == json!(true)
        && mod_drain(harness)?.is_empty();
    menu.client_in_session = harness.eval("modSetEnabled(\"com.e.client\", false)")?
        == json!("ok mod disable com.e.client");
    harness.eval("modSetEnabled(\"com.e.client\", true)")?;
    mod_drain(harness)?;
    net_feed(harness, r#"{"type":"disconnected"}"#)?;

    // The screen draws a panel, a row per mod and a Back button.
    let draws = harness.eval(DRAW_MODS_PROBE)?;
    menu.draws = draws["panel"].as_u64() == Some(1)
        && draws["label"].as_u64().is_some_and(|count| count >= 3)
        && draws["button"].as_u64() == Some(3);
    harness.command("ui hud")?;

    // A reload re-reads the manifest and merges its tuning tree again.
    harness.call(
        "sceneModTuning",
        &[json!("com.e.client"), json!(r#"{"camera":{"dist":8.25}}"#)],
    )?;
    menu.retune = f64_of(harness.eval("goats.tuning.get(\"camera.dist\")")?) == 8.25;
    harness.call(
        "sceneModTuning",
        &[json!("com.e.client"), json!(r#"{"camera":{"dist":5.2}}"#)],
    )?;
    Ok(menu)
}

// ---- the checked-in fixture ------------------------------------------------

/// The checked-in `mods/example` fixture, compiled in: a renamed or broken file
/// then fails the build as well as the case, and the test cannot drift from it.
///
/// `tools/mod_smoke_test.js` loaded this directory from disk and asserted both
/// halves of the seam. The host-side half -- the manifest is well-formed, the
/// declared asset exists and is a real RIFF wav -- is what `crates/mods` and the
/// release packaging own; what is left here is the scene side: the table
/// installs, the slot re-points, the tuning tree merges (and its deliberate typo
/// warns), the command dispatches, the HUD hook draws, a throwing handler is
/// isolated, and a reload leaves no duplicate.
const EXAMPLE_MANIFEST: &str = include_str!("../../../mods/example/mod.json");
const EXAMPLE_ENTRY: &str = include_str!("../../../mods/example/mod.js");
const EXAMPLE_TUNING: &str = include_str!("../../../mods/example/tuning.json");
const EXAMPLE_BLEAT: &[u8] = include_bytes!("../../../mods/example/assets/bleat.wav");

/// One `hud` emit with `rl.drawText` stood in for, returning the lines drawn.
/// `modEmit` reaches mod handlers only, so every line is the hook's -- which is
/// what `drawTexts.length` measured in the Node harness.
const HUD_PROBE: &str = r#"(function () {
    const real = rl.drawText;
    const texts = [];
    rl.drawText = function (text) { texts.push(String(text)); };
    try {
        modEmit("hud", { width: 1280, height: 720 });
    } finally {
        rl.drawText = real;
    }
    return texts;
})()"#;

/// One `hud` emit, as the lines it drew.
fn hud_lines(harness: &mut Harness) -> Result<Vec<String>, String> {
    let value = harness.eval(HUD_PROBE)?;
    Ok(value
        .as_array()
        .map(|lines| {
            lines
                .iter()
                .filter_map(|line| line.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default())
}

/// The host's wrapper around an entry: a scoped IIFE handed the per-mod handle.
fn wrapper(id: &str, body: &str) -> String {
    format!("(function (goats) {{\n\"use strict\";\n{body}\n}})(goats.begin({id:?}));")
}

/// The unload-then-load pair a reload performs, which is how the host re-reads a
/// mod: `sceneModEnd` drops the instance, then the fresh wrapper re-registers.
fn reload(harness: &mut Harness, id: &str, body: &str) -> Result<(), String> {
    harness.call("sceneModEnd", &[json!(id)])?;
    harness.eval(&wrapper(id, body))?;
    harness
        .call("sceneModResult", &[json!(id), json!(true), json!("")])
        .map(|_| ())
}

/// What the fixture cases found.
#[derive(Debug, Default)]
struct ModFixture {
    manifest: bool,
    asset: bool,
    installed: bool,
    listed: bool,
    slot: bool,
    tuning: bool,
    typo: bool,
    command: bool,
    builtin: bool,
    hud: bool,
    isolated: bool,
    reported: bool,
    reload_hud: bool,
    reload_command: bool,
}

/// The example fixture, loaded the way the host loads one: the metadata table,
/// the entry inside its wrapper, the result, then the freeze. It leaves the mod
/// unloaded again, so nothing after this block runs against it.
fn fixture_block(harness: &mut Harness) -> Result<ModFixture, String> {
    let mut fixture = ModFixture::default();
    let manifest: serde_json::Value =
        serde_json::from_str(EXAMPLE_MANIFEST).map_err(|error| format!("mod.json: {error}"))?;
    let id = manifest["id"]
        .as_str()
        .filter(|id| !id.is_empty())
        .ok_or("mod.json declares no id")?
        .to_string();
    fixture.manifest = manifest["api"] == json!(1)
        && manifest["side"] == json!("client")
        && manifest["entry"].is_string();
    fixture.asset = manifest["assets"]["sfx.bleat"] == json!("assets/bleat.wav")
        && EXAMPLE_BLEAT.starts_with(b"RIFF");

    let tuning: serde_json::Value =
        serde_json::from_str(EXAMPLE_TUNING).map_err(|error| format!("tuning.json: {error}"))?;
    let table = json!([{
        "id": id,
        "name": manifest["name"],
        "version": manifest["version"],
        "api": manifest["api"],
        "side": manifest["side"],
        "description": manifest["description"],
        "enabled": true,
        "hash": "0",
        "assets": { "sfx.bleat": format!("mod:{id}:sfx.bleat") },
        "tuning": tuning,
    }]);
    let table = serde_json::to_string(&table).map_err(|error| error.to_string())?;
    fixture.installed = harness.call("sceneMods", &[json!(table)])? == json!("ok");
    fixture.listed = bool_of(harness.eval(&format!(
        "goats.mods().some(function (m) {{ return m.id === {id:?} && m.enabled; }})"
    ))?);
    fixture.slot =
        harness.eval("goats.assets.get(\"sfx.bleat\")")? == json!(format!("mod:{id}:sfx.bleat"));
    fixture.tuning = f64_of(harness.eval("goats.tuning.get(\"camera.dist\")")?) == 6.5;
    fixture.typo = harness
        .observe()?
        .logs
        .iter()
        .any(|line| line.contains("typo.notAThing") && line.contains("unknown path"));

    harness.eval(&wrapper(&id, EXAMPLE_ENTRY))?;
    harness.call("sceneModResult", &[json!(id), json!(true), json!("")])?;
    harness.call("sceneModFreeze", &[])?;

    fixture.command = harness.command("hello")? == "ok hello world"
        && harness.command("hello goat")? == "ok hello goat";
    fixture.builtin = harness.command("ping")? == "ok pong";
    let lines = hud_lines(harness)?;
    fixture.hud = lines.len() == 1 && lines[0].contains("example mod");

    // The fixture with one extra handler that throws, the way a mod with a bug
    // behaves: the frame must survive and the fixture's own hook must still run.
    let seen = harness.observe()?.logs.len();
    reload(
        harness,
        &id,
        &format!(
            "{EXAMPLE_ENTRY}\ngoats.on(\"hud\", function () {{ throw new Error(\"boom\"); }});\n"
        ),
    )?;
    fixture.isolated = hud_lines(harness)?.len() == 1;
    fixture.reported = harness.observe()?.logs.get(seen..).is_some_and(|lines| {
        lines
            .iter()
            .any(|line| line.contains("handler threw") && line.contains("boom"))
    });

    // ...and reloading the clean entry leaves exactly one of each.
    reload(harness, &id, EXAMPLE_ENTRY)?;
    fixture.reload_hud = hud_lines(harness)?.len() == 1;
    fixture.reload_command = harness.command("hello goat")? == "ok hello goat";
    harness.call("sceneModEnd", &[json!(id)])?;
    Ok(fixture)
}

// ---- a mod that arrives after the freeze ------------------------------------

/// The row a pulled world mod arrives as: a mod the host fetched for us, with an
/// asset slot and a tuning leaf, so the block can check that both land the way the
/// boot table's did.
const ADDED_ROW: &str = r#"{
    "id":"com.pulled","name":"Pulled","version":"1.0.0","api":1,"side":"world",
    "description":"arrived by fetch","enabled":true,"hash":"aaaaaaaaaaaaaaaa",
    "assets":{"sfx.pulled":"mod:com.pulled:sfx.pulled"},
    "tuning":{"camera":{"dist":9.25}}
}"#;

/// Its entry, evaluated by the host the same way any entry is. It registers a
/// command, which is the test: registration closes at `goats.freeze()`, and the
/// only reason this can work is that the host opens the window for the mod it is
/// adding.
const ADDED_ENTRY: &str = r#"(function (goats) {
    goats.command("pulled", function (parts) { return "ok pulled " + (parts[1] || "once"); });
})(goats.begin("com.pulled"))"#;

/// What the post-freeze-add cases found.
#[derive(Debug, Default)]
struct ModAdded {
    added: bool,
    listed: bool,
    key: bool,
    slot: bool,
    tuning: bool,
    command: bool,
    duplicate: bool,
    unreadable: bool,
    closed: bool,
    frozen: bool,
}

/// A mod added after `goats.freeze()` (M18d): the scene sets its mod table up once
/// at boot and closes registration, so a world mod pulled from a host mid-session
/// goes in through `sceneModAdd` instead. Everything else about it is the boot
/// path -- and everything the freeze closed stays closed.
///
/// Runs last, and after the fixture block, because the freeze is what it needs.
fn added_block(harness: &mut Harness) -> Result<ModAdded, String> {
    let mut added = ModAdded {
        added: harness.call("sceneModAdd", &[json!(ADDED_ROW)])? == json!("ok"),
        ..ModAdded::default()
    };

    // It is a mod like any other now: listed, described, and in the world set.
    let list = try_command_json(harness, "mod list")?;
    added.listed = list.as_array().is_some_and(|rows| {
        rows.iter().any(|row| {
            row["id"] == json!("com.pulled")
                && row["side"] == json!("world")
                && row["description"] == json!("arrived by fetch")
        })
    });
    let key = try_command_json(harness, "mod key")?;
    added.key = key
        .as_array()
        .is_some_and(|rows| rows.contains(&json!("com.pulled@1.0.0#aaaaaaaaaaaaaaaa")));

    // Its declared asset re-points its slot, and its tuning tree merges -- the two
    // halves of `sceneMods` that a late mod has to repeat.
    added.slot =
        harness.eval("goats.assets.get(\"sfx.pulled\")")? == json!("mod:com.pulled:sfx.pulled");
    added.tuning = f64_of(harness.eval("goats.tuning.get(\"camera.dist\")")?) == 9.25;

    // Its entry runs, and its command registers through the window the host holds
    // open for it.
    harness.eval(ADDED_ENTRY)?;
    harness.call(
        "sceneModResult",
        &[json!("com.pulled"), json!(true), json!("")],
    )?;
    added.command = harness.command("pulled now")? == "ok pulled now";

    // The window is for that mod and no further: registration is still closed, and
    // a second copy of the same id is refused rather than doubled.
    added.frozen = bool_of(harness.eval("goats.frozen()")?);
    added.closed = throws(
        harness,
        "globalThis.__stashed.on(\"update\", function () {})",
    );
    let again = harness.call("sceneModAdd", &[json!(ADDED_ROW)])?;
    added.duplicate = again == json!("error already loaded: com.pulled");
    added.unreadable = harness.call("sceneModAdd", &[json!("not json")])?
        == json!("error unreadable mod metadata");
    Ok(added)
}
