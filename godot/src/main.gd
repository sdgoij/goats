# The port's scene: the game. A local goat you drive, a herd mirrored from a host,
# and a world -- ground, meadow and sky -- derived rather than received.
#
# It owns no simulation of *anybody else's* goats: it joins the session named by
# `GOATSD_TICKET`, drains the bridge once a frame, and hands every world snapshot to
# the `Herd`, which places one real goat per bot the host is simulating (see
# `herd.gd`). Everything else is its own: the local goat (`player_goat.gd`, the one
# the keyboard is), the ground (`terrain_mesh.gd`), the meadow (`grass.gd` over
# `meadow.gd`) and the sky with its light (`sky.gd`).
#
# The one number that has to travel is the clock -- a session's `weather.world_time`
# sets the hour, and with no session the scene is its own host and the day advances
# at `TUNING.world.dayLength` (`world.js` `sceneFrame`) -- and the weather, which the
# same event carries because the host owns it. Where the scene is a client it also
# *publishes* its goat, about twenty times a second, so a raylib client or another
# Godot one sees it exactly as it sees theirs.
#
# The weather and the two celestial bodies are the last of the world to land, and both
# are stitched in here. Offline the weather is a *machine* (`weather.gd`) whose clock
# and easing `_advance` moves, and the wind, the grass's sway and the goat's own
# slowdown all come off it; in a session it only *mirrors* the host's values, because
# the host owns the weather. Either way the rain still falls locally -- a client is sent
# a *rate*, not a list of drops -- and the sun and the moon (`celestial.gd`) move,
# because both are derived from values on the wire rather than sent as events.
#
# Two modes, one scene:
#
#   * a game -- set `GOATSD_TICKET` and play with other people, or set nothing at all
#     and play alone;
#   * a probe -- also set `GOATS_PROBE=1` and it settles, reports the herd, and
#     exits non-zero if the mirror did not converge. `tools/interop.sh herd` runs it
#     against a real `goatsd`, which is what makes it a gate rather than a window.
#
# The ticket comes from the environment because the console and the menu are stage 6;
# there is no in-game way to paste one yet.
#
# Every local is annotated rather than inferred -- see the `:=` note in
# `terrain.gd`.
extends Node3D

## How long the mirror is given to converge before the probe reports. Long
## enough for the easing (`Herd.SMOOTH`) to close a snapshot's worth of gap, and
## long enough for the host's bots to actually start moving -- a herd that is
## standing still would let a broken mirror pass.
const PROBE_SETTLE := 8.0
## The gap the probe tolerates. A bot moves about 0.15 m between snapshots at
## 10 Hz, and the easing leaves a fraction of that, so anything near this is a
## mirror that is not tracking rather than one merely lagging.
const PROBE_TOLERANCE := 0.5
## The least motion the probe will accept as evidence that the mirror tracks a
## herd that moves rather than a herd that happens to be still. One centimetre
## between snapshots is far below a walking bot's step and far above jitter.
const PROBE_MOTION := 0.01
## The least relief the probe will accept under the herd. The spawn bowl is
## deliberately flat (`TUNING.terrain.flat` is 6 units), so a herd that has not
## wandered out of it would report ~0 and prove nothing about the terrain; the
## bots do wander out, and this is what says so.
const PROBE_RELIEF := 0.05

@onready var herd: Herd = $Herd
## The other *players*: one goat per peer the server relays. `Herd` is the host's bots; this
## is the host's people, and they are two modules because they are two rules (`peers.gd`, M21).
@onready var peers: Peers = $Peers
## The scene's own herd, when there is no session to mirror one from (`bots.gd`). It is
## empty in a session -- the host owns the bots' AI there, and `Herd` places what it sends.
@onready var bots: Bots = $Bots
@onready var goat: PlayerGoat = $Goat
@onready var terrain: TerrainMesh = $Terrain
@onready var water_surface: WaterMesh = $Water
## The splashes the water throws, drawn as their own node (`water_splash.gd`, M20d).
@onready var water_splash: WaterSplash = $Splash
@onready var grass: Grass = $Grass
@onready var explosions: Explosions = $Explosions
@onready var celestial: Celestial = $Celestial
## The sound (M22): the beds, the slots and the four rules `audio.js` is (`audio.gd`).
@onready var audio: Audio = $Audio
@onready var hud: Hud = $Ui/Hud
@onready var rain: Rain = $Ui/Rain
@onready var sun: DirectionalLight3D = $Sun
@onready var world_environment: WorldEnvironment = $WorldEnvironment

## The bridge is built in code, not in the scene. A GDExtension class named as a
## node type in a `.tscn` cannot be resolved while the import pass that registers
## it is still running, and a scene cached from such a pass silently loses the
## node -- `$NetBridge` comes back null and every frame fails on it. A script path
## and a `ClassDB.instantiate` always resolve.
var bridge: Object

## The console (M24) and the vocabulary it dispatches through. Both are built in code for the
## bridge's reason: a `class_name` script used as a *node type* in a `.tscn` cannot be resolved
## while the import pass that registers it is still running. The console is a `Control` added to
## the UI layer above the HUD.
var console: Console
var commands := Commands.new()

## The menu (M25): `menu.js`'s four screens, drawn. It owns `uiScreen`, because which screen is up
## *is* the menu's state -- `main.gd` asks it (`is_open`) for the freeze and the key gates, and the
## console's `ui` verb sets it through here.
var menu: Menu

## `core.js`'s `SETTINGS`, shared with the menu's settings screen and the console's `setting` verb.
## One object because two owners is how the console and the screen would drift apart.
var settings := Settings.new()

## Frames left to run while the world is frozen (`ctl.js`'s `ctlStep`): the console's `step <n>`
## unsticks the pause gate for a fixed count and re-pauses when it reaches zero, which is what
## makes a step reproducible.
var _step_frames := 0

## The two virtual keys the console's movement verbs hold down, layered over the real keyboard
## the way `ctl.js`'s `ctlHeld` is layered by `ctlKeyDown`: `walk`/`trot`/`run`/`back` set
## `_held_gait` and `turn` sets `_held_turn`, so a script can drive the goat with no key pressed.
var _held_gait := "stop"
var _held_turn := "stop"

## The session's state as the events report it: this player's name, the ticket it joined with
## (which `copy` with no argument puts on the clipboard), and the roster. A client cannot host
## yet, so there is no hosting mode and no ticket of this scene's own.
var _net_name := ""
var _net_ticket := ""
var _roster: Array = []

## The camera's own state: an orbit the mouse drags and the arrow keys nudge, seeded
## from and clamped by `TUNING.camera`. The scene's `sceneFrame` owns the same three
## numbers and moves them the same way, and they matter more than they look: the
## scene's camera rides about three metres up (`TUNING.camera.dist` 5.2 at pitch
## 0.42) while its cloud slab hangs from `TUNING.sky.cloudBase` 5 to `cloudTop` 9.5
## -- so the eye is *under* the deck, and the sky shader's march is a function of
## that. From higher up the same slab is a band across the horizon instead of a
## canopy overhead.
var _cam_yaw := Tuning.CAMERA_YAW
var _cam_pitch := Tuning.CAMERA_PITCH
var _cam_dist := Tuning.CAMERA_DIST
var _dragging := false
## Whether the world is frozen (`goat.js`'s `paused`). `P` toggles it, the HUD says so, and the
## *view* keeps running -- see `_process`.
var _paused := false
## The one-shot presses since the last frame, filled by `_unhandled_input` and
## consumed by `_process`. The scene's `press()` reads the same four keys once per
## frame; Godot delivers the press as an event, so it is held here until then.
var _jump_pressed := false
var _eat_pressed := false
var _sleep_pressed := false
var _restart_pressed := false

## The meadow: the eaten cells, their countdowns and the tufts a bite can reach.
var meadow := Meadow.new()

## The weather: offline this scene's own state machine, and in a session a mirror of
## the host's values (see `weather.gd`). The rain overlay draws its pool and
## `PlayerGoat` reads its rain and wind through `_weather_now`.
var weather := Weather.new()

## The water: a level over the terrain *grid* (`water.gd`). It is rebuilt where the grid
## is and steps once a frame, and what it produces is the wading the goat feels -- its
## surface is a later slice.
var water := Water.new()
## The grid's build count the water was last rebuilt at, which is how a rebuild is told
## from a no-op without the water reaching into the mesh.
var _terrain_builds := -1

## The water's reflection (M20e): the setting's leaf and the promise, and the pass a tier buys
## (`water_reflect.gd`). It is a plain object rather than a node -- what decides the tier is a
## leaf, not a place in the world.
var water_reflect := WaterReflect.new()
## ...and the pass itself: `renderWaterMirror`'s second camera, in a `SubViewport` that shares
## this scene's world (`water_mirror.gd`).
var water_mirror := WaterMirror.new()

## The mod runtime (stage 1): the extension's `ModHost`, the `mods/` directory it reads, and the
## table the Mods screen draws (`mods.gd`). It is a node because a mod draws through the frame.
var mods := Mods.new()

## A bite's device test, built once and handed to the goat every frame: `food.js`
## `startEat` asks whether the tuft it just ate was trapped, and `explosions.gd` is what
## answers. It is a `Callable` and not the node because `PlayerGoat` does not link
## against the devices -- the same reason the meadow's own search takes a filter.
var _eat_trap := Callable()

## What a mod draws goes here (`mod_hud.gd`): the API's `goats.draw` surface, painted. It is a
## `Control` on the UI layer and not a 3D node, because the screen-space pass is the `hud`
## (`APIv1.md` section 4.18).
var mod_hud := ModHud.new()
## ...and what it draws in the *world* goes here (`mod_world.gd`): `goats.gfx.draw`, a node per
## call, in the root rather than the UI layer because it is 3D (`APIv1.md` section 4.19).
var mod_world := ModWorld.new()
## ...and what it *sounds* goes here (`mod_audio.gd`): `goats.sfx`, a pool of players and the
## decoders for the bytes a mod declared (`APIv1.md` section 4.20).
var mod_audio := ModAudio.new()

## Whether the scene is in a session as a *client*. It is what the herd mirror hangs on, and
## its window is the wire's. A client simulates no world: the host owns the bots, the weather and
## the meadow, and this scene adopts the snapshot instead (`net.js` `netWorldLocal`).
var _joined := false
## Whether the scene is in a session as the *host*. It is separate from `_joined` for the reason
## the scene keeps them separate: a host keeps simulating the world a client must not (the bots,
## the weather, the meadow), and it is the only side that *publishes* it. It is also what a host
## publishes its own goat through -- the goat is local to this scene but not to the clients'.
var _hosting := false
## How often this scene publishes its goat -- `NET_POSE_RATE`, about twenty a
## second: the datagrams are unreliable by design and a lost one does not matter.
const POSE_INTERVAL := 0.05
var _pose_timer := 0.0
## How often a host publishes the world, in frames -- `net.js` `NET_WORLD_EVERY`, about ten a
## second. A frame count rather than a clock because the scene's is (`sceneFrames`), and `_world_frame`
## starts a whole interval in the past so the first publication after `hosting` is prompt.
const WORLD_EVERY := 6
var _world_frame := -WORLD_EVERY

## The sky material and the world's clock, wind and weather, all of which `_advance`
## refreshes once a frame. `_hours` starts where the scene's own `worldTime` does.
var _sky_material: ShaderMaterial
var _hours := SkyDome.DEFAULT_HOUR
var _sky_time := 0.0
var _sway_time := 0.0
var _sky_light := 1.0
var _cloudiness := SkyDome.CLOUDINESS_CLEAR
var _wind_x := 0.0
var _wind_z := 0.0
var _wind_sway := 0.0
## The last `weather` the host sent, or empty while there is no session -- which is
## what decides whether the clock runs locally or follows the wire.
var _weather := {}
## The staging knobs: everything there is no UI for yet. The console and the menu are
## stage 6, so each of these is an environment variable, and a session's own values win,
## because the host owns the world.
##
##   `GOATS_HOUR`             pin the hour, for looking at a sky phase.
##   `GOATS_CLOUD`            pin the sky's cloudiness, for exercising the cloud march.
##                            The state machine still runs, so rain still comes and goes
##                            around it.
##   `GOATS_WEATHER=<state>`  pin the machine's state (`clear`, `cloudy`, `rain`,
##                            `clearing`), which `GOATS_CLOUD` cannot do -- it moves the
##                            sky but not the rain. A downpour has no UI either, and it
##                            is the one thing only a picture can judge (the overlay is
##                            drawn, not measured), so this is the knob that shows it.
##   `GOATS_CAM=yaw,pitch[,dist]`
##                            aim the camera. The two bodies sit on the light's line
##                            *behind* the boot camera (`TUNING.camera.yaw` 0.7), so a
##                            script cannot photograph one without this and a person
##                            would drag the mouse. Missing parts keep their defaults.
##   `GOATS_BOOM`             set off a bang beside the goat a moment into the run, so a
##                            bang and the hole it leaves can be *looked at* rather than
##                            measured. The one that changes the world rather than the
##                            view.
##   `GOATS_FLOOD=<level>`    pin the water's level by hand, which is `water.js`'s own
##                            `flood <h>` console verb. A downpour only floods the
##                            hollows, so this is what makes a pool *visible* to a camera
##                            and to a picture.
##   `GOATS_REFLECT=<tier>`   what the water reflects (M20e): `sky`, `ground` or `mirror`,
##                            which are the words `setting reflect` takes -- the console
##                            route this stands in for until stage 6. A word the scene does
##                            not know leaves the leaf where it is, as `ctl.js` does.
##   `GOATS_CONSOLE=<line>`   run a console line at boot with the panel open, so a picture can
##                            show the console with something in it. It is the one knob that is
##                            about *seeing* a thing rather than measuring it, and it exists
##                            because the console is the part of the UI no gate can photograph
##                            from the inside (M24).
##   `GOATS_UI=<screen>`      open a menu screen at boot (`main`, `settings`, `mods`, `keymap`),
##                            which is `GOATS_CONSOLE`'s knob for the menu's four panels (M25).
##                            It goes through the console's own `ui` verb, so it cannot open a
##                            screen the vocabulary would refuse.
##   `GOATS_MODS=<dir>`       read mods from this directory instead of the search `mods.gd`
##                            does (`GOATS_MODS`, then `mods/` beside the project, then beside
##                            the executable). `GOATS_NO_MODS` skips the search entirely -- the
##                            raylib client's `--mods`/`--no-mods`, spelled as the environment
##                            variables it already uses for the same two things.
var _forced_hour := -1.0
var _forced_cloud := -1.0
var _boom := false
var _boom_frame := 0

var _probe := false
var _worlds := 0
## How many *mods* datagrams this client has applied -- the world mods' own, beside the world's
## (`net.js` `netMaybePublishWorld` queues both). It is a probe's evidence rather than a rule: a
## session with no world mod has none, which is the common case.
var _mods_datagrams := 0
var _last_bots := 0
## The largest distance any single bot covered between two snapshots, which is
## what tells a mirror that tracks a moving herd from one that agrees with a
## herd standing still.
var _max_step := 0.0
var _previous := {}
## Seconds since the first snapshot that carried a herd, or -1 until one does. It
## is deliberately not a plain timer: `goatsd` publishes half-built worlds while
## it loads its scene, and settling on one of those would measure nothing.
var _settle := -1.0

func _ready() -> void:
	_set_up_sky()
	# The devices need the goat they hurt and the meadow a trap has to land in; the
	# scene's own field is wired the same way (`explosions.js` reads the goat and
	# `EATEN` out of the module scope it shares with them).
	explosions.goat = goat
	explosions.meadow = meadow
	explosions.terrain = terrain
	# ...and the herd a bang throws and kills (M19a/M19c). It is empty in a session -- a
	# client's bots are the host's, and `blast` says so by finding none to move.
	explosions.bots = bots
	# ...and the same wiring the other way for the bite: the goat asks the devices
	# whether the tuft it just ate was trapped (`food.js` `startEat`).
	_eat_trap = Callable(explosions, "trip_trap_at")
	# ...and the bite itself, which a *client* also owes the session: the host owns the
	# meadow, so a bite here is a report (`food.js`'s `netQueue({"type":"consume"})`), and it
	# comes back in the next world snapshot. A callback and not a `main.gd` poll, for the
	# reason `trap` is one -- the goat knows which tuft it ate and this file does not.
	goat.bite = Callable(self, "_report_bite")
	# The sound (M22). The goat and the devices *report*; this object decides what a report sounds
	# like, which is why both ends are `Callable`s into `audio.gd` rather than the modules
	# knowing about each other. `blast_radius` comes from the devices because the attenuation
	# knee and the damage radius are the same number in the scene's own table.
	audio.goat = goat
	audio.blast_radius = Explosions.BLAST_RADIUS
	goat.bleat = Callable(audio, "bleat")
	explosions.trigger_sound = Callable(audio, "trigger")
	explosions.bang_sound = Callable(audio, "bang")
	# ...and the bang itself, which a *client* also owes the session: a device fires in exactly one
	# place, and the process that simulates the goat that tripped it reports it (`explosions.js`
	# `netBlastFired`). A callback and not a `main.gd` poll, for the reason `trap` is one -- the
	# devices know which key went off and this file does not.
	explosions.net_fired = Callable(self, "_report_blast")
	# The water's field is the terrain *grid's*, so it is built where the grid is: once
	# here -- a child's `_ready` runs before its parent's, so the terrain has built --
	# and again whenever the grid is rebuilt (below).
	water.rebuild(terrain.heights(), terrain.anchor())
	_terrain_builds = terrain.rebuilds
	water_surface.build(terrain.heights(), terrain.anchor())
	# The two nodes that *read* the water rather than rebuild with it: the grass, which culls
	# a tuft a pool is hiding (M20d), and the splash node, which draws its drops. Both are
	# told once; neither follows the grid.
	grass.water = water
	water_splash.water = water
	# The reflection (M20e) is a mirrored pass, so the layers its `cull_mask` reads are set here:
	# the ground on one of its own, and the surface, the drops and the meadow on another. That is
	# what says "the ground, and not the goat" (the ground tier draws the ground's layer alone)
	# and "everything but what must not be in a reflection" (the mirror tier draws the rest).
	# The ground's *own* reflection is a second draw of the same mesh on a second layer, because a
	# heightfield is a back face to a camera under it; `use_ground` below hands it over, and the
	# camera a few lines down keeps the main pass away from it.
	terrain.layers = WaterMirror.LAYER_GROUND
	water_surface.layers = WaterMirror.LAYER_NOREFLECT
	grass.layers = WaterMirror.LAYER_NOREFLECT
	water_splash.layers = WaterMirror.LAYER_NOREFLECT
	add_child(water_mirror)
	# The mesh is the terrain's own, so the twin follows a rebuilt grid without a copy of it, and
	# the material is the ground's look with the mirror's own two differences.
	water_mirror.use_ground(terrain.mesh, terrain.mirror_material())
	# The tier is the console's (`setting reflect`) once there is one; until then it is the
	# staging knob, and a word the scene does not know leaves the leaf where it is. The surface
	# and the pass are both told, because neither can work the tier out for itself.
	var reflect_word: String = OS.get_environment("GOATS_REFLECT")
	var reflect_tier: int = WaterReflect.word_tier(reflect_word)
	if reflect_tier >= 0:
		water_reflect.set_wish(float(reflect_tier))
	water_reflect.apply(water_surface, water_mirror)
	# The scene's own field of view (`beginMode3D(..., 55)`); Godot's default is 75.
	var camera := $Camera3D as Camera3D
	camera.fov = 55.0
	# The ground's twin is the mirror's own, and only the mirror's camera may see it: from above,
	# `cull_front` throws every quad of it away, so a main pass that drew it would pay for nothing.
	camera.cull_mask = camera.cull_mask & ~WaterMirror.LAYER_GROUND_MIRROR
	_forced_hour = _environment_float("GOATS_HOUR", -1.0)
	_forced_cloud = _environment_float("GOATS_CLOUD", -1.0)
	_boom = not OS.get_environment("GOATS_BOOM").is_empty()
	if _forced_hour >= 0.0:
		_hours = _forced_hour
	# `GOATS_WEATHER` is a one-shot: `Weather.hold` leaves the machine *in* the state
	# (its targets are the current values), so nothing here has to remember it.
	var forced_weather := OS.get_environment("GOATS_WEATHER")
	if not forced_weather.is_empty():
		weather.hold(forced_weather)
	# An unset or unreadable `GOATS_FLOOD` is `NAN`, which `set_force` reads as "from the
	# rain" -- so the knob costs nothing when it is not there.
	water.set_force(_environment_float("GOATS_FLOOD", NAN))
	var forced_cam := OS.get_environment("GOATS_CAM")
	if not forced_cam.is_empty():
		var parts: PackedStringArray = forced_cam.split(",")
		if parts.size() >= 1 and parts[0].is_valid_float():
			_cam_yaw = parts[0].to_float()
		if parts.size() >= 2 and parts[1].is_valid_float():
			_cam_pitch = parts[1].to_float()
		if parts.size() >= 3 and parts[2].is_valid_float():
			_cam_dist = parts[2].to_float()

	var node := ClassDB.instantiate("NetBridge") as Node
	add_child(node)
	bridge = node

	# The console (M24): built in code, added to the UI layer *after* the HUD so it draws over
	# it, and pointed at the vocabulary. It is wired before the offline return below, so a
	# player with no ticket still has it -- which is the point, because the console is what the
	# `GOATS_*` environment variables stand in for and what retires them.
	console = Console.new()
	$Ui.add_child(console)
	console.dispatch = Callable(commands, "run")
	_build_commands()

	# The menu (M25): also code-built, also added after the HUD, and *after* the console so a menu
	# is the topmost thing on screen. It shares the one `Settings` with the console's `setting`
	# verb, and reaches the frame for the two things only the frame can do -- opening the console
	# and quitting. Its `mods_list` is the mod runtime's table, wired below.
	settings.apply = Callable(self, "_apply_settings")
	menu = Menu.new()
	$Ui.add_child(menu)
	menu.settings = settings
	menu.water_reflect = water_reflect
	menu.bots = bots
	menu.on_console = Callable(self, "_open_console")
	menu.on_quit = Callable(self, "cmd_quit")
	commands.settings = settings

	# The mod runtime (stage 1). Built *after* the console, because its load report is a console
	# line, and before the offline return below, so a player with no ticket still has their mods --
	# the same reason the console and the menu are. The Mods screen draws the host's table
	# (`mods_list`), and its Enable/Disable button is the runtime's own `modSetEnabled`
	# (`mod_toggle`, below), which the scene is what gives a *session* to guard.
	#
	# `mod_hud` goes on the UI layer *before* the console and the menu, so it paints over the
	# game's HUD and under the overlays -- which is where a mod's `hud` drawing belongs. The
	# world's own half is a `Node3D` in the root, because it is drawn in three dimensions.
	$Ui.add_child(mod_hud)
	add_child(mod_world)
	add_child(mod_audio)
	mods.console = console
	mods.surface = mod_hud
	# The scene's entry point for the API's functional members (`_mod_call`), handed over *before*
	# the runtime enters the tree because it builds its host in `_ready` and registers this at once.
	mods.scene_call = Callable(self, "_mod_call")
	# ...and the session guard its toggle consults, for the same reason: a `Callable` rather than a
	# flag, because a toggle can happen between two frames and a pushed value would be a frame stale.
	mods.in_session = Callable(self, "_net_in_session")
	add_child(mods)
	# After `add_child(mods)`, because the runtime builds its `ModHost` in `_ready` -- and the
	# world node and the sound pool want that host to turn an asset name into bytes.
	mod_world.host = mods.host
	mods.devices = explosions
	mods.world = mod_world
	mod_audio.host = mods.host
	# Decode the mods' declared sounds *here*, outside any hook: a `goats.sfx` call runs inside a
	# mod's JavaScript, where the extension is borrowed and cannot be asked for bytes.
	mod_audio.prepare()
	menu.mods_list = Callable(mods, "mod_table")
	# The button's own callback: one argument, and it flips whatever the table says the mod is now.
	menu.mod_toggle = Callable(mods, "toggle_mod")

	# `GOATS_UI=<screen>`: open a menu screen at boot, for `GOATS_CONSOLE`'s reason -- the panels are
	# the part of the UI only a picture can judge. It goes through the console's own `ui` verb so the
	# knob cannot open a screen the vocabulary would refuse.
	var staged_ui: String = OS.get_environment("GOATS_UI")
	if not staged_ui.is_empty():
		commands.run("ui " + staged_ui)
	# `GOATS_CONSOLE=<line>`: run a line at boot with the panel open, so a picture can show the
	# console with something in it. The command runs through the same dispatch a typed one does,
	# so a knob that works is a knob that proves the vocabulary is wired to the world.
	var staged: String = OS.get_environment("GOATS_CONSOLE")
	if not staged.is_empty():
		console.toggle()
		console.submit(staged, console.dispatch)

	_probe = not OS.get_environment("GOATS_PROBE").is_empty()
	var ticket := OS.get_environment("GOATSD_TICKET")
	if ticket.is_empty():
		# No ticket is the *normal* way to play. A session is optional -- the game's
		# own client boots into a solo world and only hosts or joins when it is asked
		# to -- and there is nothing here that needs one to run: the goat is yours,
		# the field builds itself from the seedless noise, and the sky runs its own
		# clock.
		#
		# The probe is the one case that needs a session, because what it measures is
		# a mirror of somebody else's herd, so it says so rather than sitting there
		# reporting nothing.
		if _probe:
			_report(["GOATS_PROBE is set but GOATSD_TICKET is not: the probe mirrors a session"])
			return
		print("offline: no GOATSD_TICKET, so there is no session to mirror")
		print("  play alone:         this, with WASD, shift to run, space to jump, E to eat")
		print("  watch a real herd:  godot/tools/interop.sh herd")
		print("  join a host:        set GOATSD_TICKET to its ticket")
		# With no session the scene is its own *host*: `netWorldLocal()` is true, so its
		# herd is one it simulates rather than one it mirrors (`bots.js`). The seams are
		# the same callables the goat's bite uses, plus the two the bots ask on their own
		# -- whether a cell holds an armed mine, and whether the ground is under water.
		bots.goat = goat
		bots.meadow = meadow
		bots.trap = _eat_trap
		bots.armed = Callable(explosions, "mine_armed")
		# The sleep rule's own test, and deliberately not the grass cull's: a bot does not doze
		# in the HUD's water (`Water.in_water`), while a *tuft* is skipped where the grid vertex
		# under it is drowned (`submerged_at`). Near a pool's edge the two disagree.
		bots.in_water = Callable(water, "in_water")
		bots.set_herd_size(Bots.COUNT)
		return
	print("join -> ", bridge.call("join", ticket, "godot"))
	# The scene is a *client* here, and a client is the one that publishes its goat: a
	# host's own goat is already local to its owns scene (`NetBridge::pose`). The name lands
	# when the `welcome` event arrives; until it does, this is the name that was asked for.
	_joined = true
	_net_name = "godot"
	_net_ticket = ticket

## Give the scene the scene's sky: a `shader_type sky` material on the
## `WorldEnvironment`, and the environment told that its ambient is the light's
## rather than the sky's.
##
## `REALTIME` and not a bake: the sun moves, the clouds drift and the clock runs, and
## a cached radiance would freeze all three. The ambient is a colour and not the sky
## because the scene's own ambient has a *floor* (`lighting.js` `LIGHT_AMBIENT`, 0.10
## at midnight) that a sky-derived one would not have, and the scene's night is dark
## rather than black.
func _set_up_sky() -> void:
	_sky_material = SkyDome.make_material()
	var environment: Environment = world_environment.environment
	environment.sky.sky_material = _sky_material
	environment.sky.process_mode = Sky.PROCESS_MODE_REALTIME
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR

func _process(delta: float) -> void:
	for line in bridge.call("poll_events"):
		_handle(String(line))

	# The frame's controls, taken once: `_controls` consumes the one-shot presses, and both the
	# goat and the HUD want what it read.
	var controls: Dictionary = _controls()
	_orbit(delta)
	var here := Vector3(goat.px, 0.0, goat.pz)
	var camera := $Camera3D as Camera3D

	# `P` freezes the *world* and not the view: `sceneFrame`'s own gate wraps the simulation
	# (`if (!paused || ctlStep > 0)`) while the camera, the mirror, the sway, the sky, the rain and
	# the HUD are all outside it. What moves the world while it is frozen is the console's
	# `step <n>`, which unsticks this one gate for a fixed count.
	#
	# A **menu** freezes the world too, and by the same means: `menu.js` sets `dt = 0` while a
	# `uiScreen` is up, which is the whole pause -- input is gated separately. The console is the
	# opposite case and deliberately so: it must not pause anything, because it has to stay usable
	# while the game runs.
	var frozen: bool = (menu.is_open() or _paused) and _step_frames <= 0
	if not frozen:
		# The ground, the fuses and the effects first, which is `sceneFrame`'s order: a
		# crater ages, a fuse runs out and a bang lands *before* the goat moves, so a goat
		# thrown this frame is thrown on the ground this frame.
		explosions.update(delta)
		# Walk onto something. The trigger is tested once per arrival rather than once per
		# frame -- the stamp is a half-metre bucket, so a goat standing still is one
		# compare -- and neither a sleeping goat nor a dead one is walking anywhere.
		if goat.mode != "sleep" and goat.mode != "dead":
			goat.trip_stamp = explosions.check_triggers(
				goat.px, goat.pz, goat.airborne(), goat.trip_stamp)

		# The goat: it is what the camera, the ground and the meadow are placed around,
		# and it is the only thing in this scene that decides anything.
		goat.step(delta, controls, _sky_light, _weather_now(), meadow, _eat_trap, _wading())
		# The herd's own AI, in `sceneFrame`'s order: the devices, then the goat, then the
		# bots, then the push-apart that keeps them from walking through each other. A client
		# simulates none of it -- it mirrors the host's herd instead (`Herd`).
		if not _joined:
			bots.update(delta, _weather_now())
			bots.resolve_collisions()
		# The meadow is the host's in a session, so a client only mirrors it.
		meadow.update(delta, _weather.is_empty())

		# The ground rebuilds when its snapped anchor moves (`terrain.gd` /
		# `terrainEnsure`) and when something has blown a hole in it.
		if Craters.dirty:
			Craters.dirty = false
			terrain.refresh()
		terrain.follow(here.x, here.z)
		# The water is the table over the grid, so it follows the grid: the scene rebuilds it
		# wherever the terrain mesh is rebuilt (`waterRebuild`), and `rebuilds` is what says
		# one happened. The grid is *read*, never written, so it must be taken again after a
		# rebuild rather than held.
		if terrain.rebuilds != _terrain_builds:
			_terrain_builds = terrain.rebuilds
			water.rebuild(terrain.heights(), terrain.anchor())
			water_surface.build(terrain.heights(), terrain.anchor())

	# The camera is placed whether or not the world moved, and before `_advance`, which reads it:
	# the view follows a goat that is standing still as much as one that is walking.
	_place_camera(camera)
	# The reflection's pass (M20e): `renderWaterMirror` runs *before* the frame's own 3D pass, and
	# so does this -- the camera it draws from is the world's own, mirrored through the water's
	# plane, and the surface reads what it drew at its own screen position.
	water_mirror.run(camera, water.level())
	if not frozen:
		_advance(delta)
		# The sound, once a frame and after the weather has settled: the beds ride the rain and
		# the wind, the thunder rolls off the rain, and the grit a bang threw lands here.
		audio.update(delta, float(_weather_now().get("rain_amount", 0.0)), _wind_sway)
	# The sky and the light are applied on *both* paths: a menu freezes the world by `dt` and still
	# draws it, so the sky's uniforms are a drawing question and not a step.
	_apply_sky(camera.global_position)
	# `step <n>` counts down here and re-pauses at zero, which is `sceneFrame`'s own "a step
	# always ends paused". It is after the world and not before it, so the frame a step buys is
	# a whole one.
	if _step_frames > 0:
		_step_frames -= 1
		if _step_frames == 0:
			_paused = true
	grass.update(here, _sway_time, _wind_sway, meadow.eaten)
	water_splash.update()
	# The two bodies and the rain, from the values `_advance` just settled: the sun and the moon
	# ride the light's own line, and the rain is screen space over everything.
	celestial.update(here.x, here.z, SkyDome.sun_dir(_hours), _cloudiness)
	rain.show_for(weather, _wind_x)
	_publish_pose(delta)
	_publish_world()
	# The HUD's three setting read-outs are `Settings`' now (M25): the console's `setting` verb and
	# the menu's settings screen write the same object, and the HUD reads it back -- so the words
	# and the things they describe cannot disagree.
	menu.scene_frames = Engine.get_process_frames()
	hud.light_word = Settings.lighting_word(settings.shadow)
	hud.sky_word = Settings.sky_word_for(settings.sky)
	hud.cloud_word = settings.cloud
	# A menu *replaces* the HUD rather than covering it: `sceneFrame` draws `drawHud`, the touch
	# controls and the damage pulse in the `uiScreen === "hud"` branch and `drawUi` in the `else`,
	# so a menu screen is the dim over a world with no read-out on it at all. Drawing the HUD under
	# the dim would be a dimmed read-out the scene does not have.
	hud.visible = not menu.is_open()
	hud.show_for(goat, _hours, _weather_now(), water.hud_text(goat.px, goat.pz),
		_hud_world(controls))
	# The mods' own frame: the clock a mod reads, and its `hud` hook while the HUD is up. It is
	# after `hud.show_for` because that is where this frame decided the HUD is the thing on screen
	# (`sceneFrame` fires `modEmit("hud", ...)` inside the branch that draws the HUD).
	#
	# ...and the `update` event with the frame's step, which is `modFrameTick(dt)` -- fired **every**
	# frame, with the freezing in the *argument* rather than in a gate: a frozen world sends `dt = 0`,
	# so a mod's own clock holds still while its handler still runs. It rides `frame` rather than
	# being called here because it has to run *after* the snapshot is pushed (`mods.gd`).
	mods.frame(_hours, Vector2(get_viewport().get_visible_rect().size), not menu.is_open(), camera,
		_mod_snapshot(), 0.0 if frozen else delta)
	_boom_if_asked()

	# The probe's own clock, which runs whether or not the world is frozen: it is counting the
	# *snapshots* a host is sending, and a host does not pause this client.
	if _settle >= 0.0:
		_settle += delta
		if _settle >= PROBE_SETTLE:
			_settle = -99.0
			_probe_report()

## What the HUD needs that only the frame knows (`drawHud`'s own arguments). The herd is the
## *local* one when there is no session and the mirrored one when there is, which is the same
## switch `BOTS` is in the scene.
func _hud_world(controls: Dictionary) -> Dictionary:
	# `foodReady`: a tuft in reach, and a goat free to take it.
	var food_ready: bool = not meadow.nearest(goat.px, goat.pz).is_empty() \
		and goat.mode != "dead" and goat.mode != "sleep" \
		and goat.mode != "jump" and goat.mode != "eat"
	return {
		"move": int(controls.get("move", 0)),
		"paused": _paused,
		"herd": bots.count() if not _joined else herd.count(),
		"food_ready": food_ready,
		"hurt": explosions.hurt(),
		"fps": Engine.get_frames_per_second(),
		"audio": audio.word(),
		# A compiled client mod's bar, or `-1.0` for none. It is the *previous* frame's value here,
		# because the mods are driven after the HUD is refreshed -- the reference's own order, and
		# the reason `Mods.wasm_hud_fill()`'s comment calls the value one frame old.
		"wasm_belly": mods.wasm_hud_fill(),
	}

## The world as a mod reads it (`APIv1.md` section 4.5-4.12), one dictionary per frame.
##
## This *is* the readable surface: it is built here, where the world modules live, and handed to
## `Mods.frame`, which pushes it (`PORT.md` section 6 decision 3). Every value is taken from the
## same place the HUD's own read-out and the wire's world take it, so there is no third derivation
## of anything -- a snapshot that disagreed with the HUD would be one bug in two places.
##
## The read is `goat`'s own fields rather than `PlayerGoat`'s, and `_weather_now()` is *not* used:
## that dictionary is the wire's shape (snake_case, `rain_amount`), while the API's `weather()` is
## its own (`rain`, `wind`, `speed`), so the two are joined here rather than one being renamed.
func _mod_snapshot() -> Dictionary:
	var herd_count: int = bots.count() if not _joined else herd.count()
	return {
		"player": {
			"mode": goat.mode, "health": goat.health, "energy": goat.energy,
			"exhausted": goat.exhausted, "satiety": goat.satiety,
			"x": goat.px, "y": goat.py, "z": goat.pz,
			"yaw": goat.yaw, "phase": goat.phase, "speed": goat.speed,
			"clip": goat.playing_clip(),
		},
		"camera": {"yaw": _cam_yaw, "pitch": _cam_pitch, "dist": _cam_dist},
		"weather": {
			"kind": weather.kind,
			"cloudiness": weather.cloudiness,
			"rain": weather.rain_amount,
			"wind": _wind_sway,
			"speed": goat.weather_speed_now(),
		},
		"wind": {"x": _wind_x, "z": _wind_z, "sway": _wind_sway},
		"bots": _mod_bots(),
		"settings": {
			"bgm": settings.bgm, "sfx": settings.sfx, "light": settings.light,
			"shadow": settings.shadow, "sky": settings.sky, "cloud": settings.cloud,
			"fullscreen": settings.fullscreen, "herd": herd_count,
		},
		"net": {
			"mode": "host" if _hosting else ("client" if _joined else "off"),
			"inSession": _hosting or _joined,
			"isHost": _hosting,
			"localWorld": not _joined,
			"name": _net_name,
			"roster": _roster.duplicate(),
		},
		"tuning": Tuning.tree(herd_count, water.enabled, water_reflect.wish),
		# The built-in half of the asset slots (`APIv1.md` section 4.11). A mod's *declared* half is
		# already reachable -- it is in the mod table, which the facade can read -- so what the scene
		# supplies is only what it alone knows: the game's own files.
		"assets": Audio.built_in(),
	}

## The herd as `goats.bots.list()` wants it (`APIv1.md` section 4.8): `{id, x, z, yaw, mode,
## satiety}` per bot, in index order. Offline that is the scene's own herd, reported directly; in a
## session it is the host's, mirrored, and the best a snapshot can say about a bot's `mode` is the
## *gait* it is posed with -- which is why `Herd.state()` reports one -- and nothing carries its
## belly, so `satiety` is 0.
func _mod_bots() -> Array:
	var out: Array = []
	if _joined:
		for entry: Dictionary in herd.state():
			out.append({
				"id": int(entry.get("index", 0)),
				"x": entry.get("x", 0.0), "z": entry.get("z", 0.0),
				"yaw": entry.get("yaw", 0.0),
				"mode": entry.get("gait", "idle"), "satiety": 0.0,
			})
	else:
		for entry: Dictionary in bots.report():
			out.append({
				"id": out.size(),
				"x": entry.get("x", 0.0), "z": entry.get("z", 0.0),
				"yaw": entry.get("yaw", 0.0),
				"mode": entry.get("mode", "idle"), "satiety": entry.get("belly", 0.0),
			})
	return out

## The scene's entry point for the API's *functional* members -- the ones a pushed snapshot cannot
## answer, because they are asked rather than told (`APIv1.md` section 4.7's `terrainHeight`,
## section 4.20's `sfx`, and the writes when they land). The extension routes a `goats` call here
## through `ModHost`'s `__goatsCall`; the answer is a JSON object -- `{\"ok\": <value>}` or
## `{\"err\": \"<message>\"}` -- which the facade turns into a returned value or a thrown error.
##
## A member this client does not answer is an `err` rather than silence, so a mod that calls one
## fails loudly in its own hook and is isolated (`APIv1.md` section 7), which is the same refusal
## the write members give from the facade.
##
## **Nothing on this seam may call back into the extension.** It runs inside a mod's own JavaScript,
## where `ModHost` is borrowed; the sound members are answered from what `ModAudio.prepare` built at
## boot for exactly that reason (`PORT.md` section 9).
## The scene going down: the one moment a mod's `shutdown` can still free what it built, which is
## what the flock does with its three meshes (`APIv1.md` section 6, `sceneShutdown`). It is the
## extension's last use in this process, so it has to happen while the node tree is still here.
func _exit_tree() -> void:
	mods.shutdown()

## Whether this client is in a session, as host or joiner -- `netInSession()`, the guard a world
## mod's toggle consults (`Mods.in_session`). Read rather than pushed, because a toggle can happen
## between two frames and a value pushed with the snapshot would be a frame stale.
func _net_in_session() -> bool:
	return _hosting or _joined

func _mod_call(name: String, args_json: String) -> String:
	var parsed: Variant = JSON.parse_string(args_json)
	var args: Array = parsed if parsed is Array else []
	match name:
		"world.terrainHeight":
			# The scene's own function, craters and all -- not a second heightfield, which is the
			# whole reason this crosses instead of being pushed as values.
			#
			# The `is int or is float` guard is not a formality: the facade sends `Number(x)`, and a
			# mod that passed `undefined` sends `null` through `JSON.stringify`. `float(null)` is not
			# a refusal, it is a *script error* (`Nonexistent 'float' constructor`), and a script
			# error inside this seam is the one thing the boundary must never produce -- it is
			# reported as an engine error rather than as the member's own thrown one, so a mod
			# cannot catch it and the log does not name what asked.
			if args.size() < 2:
				return _mod_err("world.terrainHeight needs an x and a z")
			if not (args[0] is float or args[0] is int) or not (args[1] is float or args[1] is int):
				return _mod_err("world.terrainHeight needs two numbers")
			var x: float = float(args[0])
			var z: float = float(args[1])
			if is_nan(x) or is_nan(z):
				return _mod_err("world.terrainHeight needs two numbers")
			return _mod_ok(Terrain.height_at(x, z))
		"sfx.load":
			# A mod's own sound (`APIv1.md` section 4.20). The *handle* is the opaque asset name
			# itself: it is already a token with no path in it, which is what `gfx.model` hands
			# back too, and the scene has nothing to add to it.
			if args.size() < 1:
				return _mod_err("sfx.load needs an asset name")
			if mod_audio.stream(String(args[0])) == null:
				return _mod_ok(null)
			return _mod_ok(String(args[0]))
		"sfx.play":
			if args.size() < 1:
				return _mod_err("sfx.play needs a sound")
			mod_audio.play(String(args[0]),
				float(args[1]) if args.size() > 1 else 1.0,
				float(args[2]) if args.size() > 2 else 1.0)
			return _mod_ok(null)
		"explosions.traps":
			# The scene's own derivation (`Explosions.traps_near`), crossing rather than being
			# pushed because the field *moves*: a device spent a frame ago is not in the answer.
			if args.size() < 3:
				return _mod_err("explosions.traps needs x, z and a range")
			var tx: float = float(args[0])
			var tz: float = float(args[1])
			var reach: float = float(args[2])
			if is_nan(tx) or is_nan(tz) or is_nan(reach) or reach < 0.0:
				return _mod_err("explosions.traps needs a point and a range")
			return _mod_ok(explosions.traps_near(tx, tz, reach))
		"explosions.blast":
			# A mod's bang, through the core's own path (`Explosions.mod_blast`): the crater, the
			# damage, the flash, the knock, the sound, the `blast` event and -- in a session -- the
			# report, which `net_fired` is already wired to. A bang nobody else hears is a bang that
			# did not happen.
			if args.size() < 3:
				return _mod_err("explosions.blast needs x, z and a kind")
			var bx: float = float(args[0])
			var bz: float = float(args[1])
			if is_nan(bx) or is_nan(bz):
				return _mod_err("explosions.blast needs two numbers")
			return _mod_ok(explosions.mod_blast(String(args[2]), bx, bz))
		"explosions.coreArmed":
			# The facade's set of mods that have taken the core devices away, derived to the one bit
			# the scene's own derivation reads (`Explosions.set_core_armed`). Private to the seam: the
			# *member* is `goats.explosions.armed(on)`, and whose request it is is the facade's own
			# bookkeeping -- which is why a mod that unloads restores the field without a second call.
			return _mod_ok(explosions.set_core_armed(args.is_empty() or args[0] != false))
		"player.giveEnergy":
			# The goat's two stats, given rather than read (`APIv1.md` section 4.5). A bird
			# perched on its back is the caller these exist for, and the clamp is the API's own:
			# `stats.max` either way, `0` at the bottom, and the new value answers.
			if args.size() < 1:
				return _mod_err("player.giveEnergy needs an amount")
			var energy: float = float(args[0])
			if is_nan(energy):
				return _mod_err("player.giveEnergy needs a number")
			goat.energy = clampf(goat.energy + energy, 0.0, PlayerGoat.STATS_MAX)
			return _mod_ok(goat.energy)
		"player.giveHealth":
			if args.size() < 1:
				return _mod_err("player.giveHealth needs an amount")
			var health: float = float(args[0])
			if is_nan(health):
				return _mod_err("player.giveHealth needs a number")
			goat.health = clampf(goat.health + health, 0.0, PlayerGoat.STATS_MAX)
			return _mod_ok(goat.health)
		"water.state":
			# The read-out the console's own `water` verb prints (`APIv1.md` section 4.17). It takes
			# the *goat's* position because that is the readout the scene defines -- the goat's own
			# drag, the wetted share around it -- and not a second derivation of the table.
			return _mod_ok(water.state(goat.px, goat.pz))
		"water.level":
			return _mod_ok(water.level())
		"water.depthAt":
			if args.size() < 2:
				return _mod_err("water.depthAt needs an x and a z")
			if not (args[0] is float or args[0] is int) or not (args[1] is float or args[1] is int):
				return _mod_err("water.depthAt needs two numbers")
			return _mod_ok(water.depth_at(float(args[0]), float(args[1])))
		"water.setLevel":
			if args.size() < 1 or not (args[0] is float or args[0] is int):
				return _mod_err("water.setLevel needs a level in metres")
			water.set_force(float(args[0]))
			return _mod_ok(water.level())
		"water.clear":
			water.force_off()
			return _mod_ok(water.level())
		"water.pools":
			# The connected regions (M20f), as the *scene's* own flood fill -- a function of the field
			# rather than a statement about it, so it crosses like `traps` and `terrainHeight`.
			return _mod_ok(water.pools())
		"water.enabled":
			water.enabled = args.is_empty() or args[0] != false
			water.update()
			return _mod_ok(water.enabled)
		# ---- the writes (`APIv1.md` sections 4.5-4.12). Every one is the *scene's* own rule: the
		# console's verb calls the same handler, because a write is a claim about the simulation and
		# only the simulation can keep its invariants (the water a goat may not sleep in, the pitch a
		# camera clamps, the gait `jump` outranks).
		"player.teleport":
			if args.size() < 2 or not _is_number(args[0]) or not _is_number(args[1]):
				return _mod_err("player.teleport needs an x and a z")
			goat.teleport(float(args[0]), float(args[1]))
			return _mod_ok(null)
		"player.face":
			if args.size() < 1 or not _is_number(args[0]):
				return _mod_err("player.face needs a yaw")
			goat.face(float(args[0]))
			return _mod_ok(null)
		"player.setMode":
			if args.is_empty():
				return _mod_err("player.setMode needs a mode")
			return _mod_ok(_mod_set_mode(str(args[0])))
		"player.restart":
			goat.restart()
			return _mod_ok(null)
		"camera.set":
			# Partial by the API's own words: the facade sends the object as three slots, and a slot
			# that is not a number is "not given" rather than a write to zero. `cmd_set_camera`
			# clamps the pitch and the distance, which is the reference's own pair of clamps.
			var cam: Dictionary = cmd_camera()
			var want_yaw: float = float(cam["yaw"])
			var want_pitch: float = float(cam["pitch"])
			var want_dist: float = float(cam["dist"])
			if args.size() > 0 and _is_number(args[0]):
				want_yaw = float(args[0])
			if args.size() > 1 and _is_number(args[1]):
				want_pitch = float(args[1])
			if args.size() > 2 and _is_number(args[2]):
				want_dist = float(args[2])
			cmd_set_camera(want_yaw, want_pitch, want_dist)
			return _mod_ok(null)
		"settings.set":
			if args.is_empty() or not (args[0] is Dictionary):
				return _mod_err("settings.set needs an object")
			_mod_apply_settings(args[0])
			return _mod_ok(null)
		"world.setTime":
			# Local-only, and *answered* rather than thrown (`APIv1.md` section 4.7): a client that
			# joined does not own the clock, so it gets the API's own `false`. The wrap is the
			# reference's (`((h % 24) + 24) % 24`).
			if _joined:
				return _mod_ok(false)
			if args.is_empty() or not _is_number(args[0]):
				return _mod_err("world.setTime needs an hour")
			cmd_set_hours(fposmod(float(args[0]), 24.0))
			return _mod_ok(true)
		"world.setWeather":
			if _joined:
				return _mod_ok(false)
			if args.is_empty():
				return _mod_err("world.setWeather needs a state")
			return _mod_ok(weather.go_to(str(args[0])))
		"net.say":
			# `netSay` reports by *value* rather than by throwing: the console prints nothing for an
			# empty reply, and the two failures are strings a caller can read.
			if not (_joined or _hosting):
				return _mod_ok("error not in a session")
			var chat: String = str(args[0]).strip_edges() if not args.is_empty() else ""
			if chat == "":
				return _mod_ok("error nothing to say")
			cmd_say(chat)
			return _mod_ok("")
		"bots.setCount":
			if args.is_empty() or not _is_number(args[0]):
				return _mod_err("bots.setCount needs a count")
			bots.set_herd_size(int(round(float(args[0]))))
			return _mod_ok(bots.count())
		"bots.zoomies":
			if args.size() < 2 or not _is_number(args[0]) or not _is_number(args[1]):
				return _mod_err("bots.get(i).zoomies needs seconds")
			if not bots.zoomies_at(int(args[0]), float(args[1])):
				return _mod_err("bots.get: no bot at that index")
			return _mod_ok(null)
		"bots.startle":
			if args.is_empty() or not _is_number(args[0]):
				return _mod_err("bots.get(i).startle needs an index")
			if not bots.startle_at(int(args[0])):
				return _mod_err("bots.get: no bot at that index")
			return _mod_ok(null)
		"bots.teleport":
			if args.size() < 3 or not _is_number(args[0]) or not _is_number(args[1]) \
					or not _is_number(args[2]):
				return _mod_err("bots.get(i).teleport needs an x and a z")
			if not bots.teleport_at(int(args[0]), float(args[1]), float(args[2])):
				return _mod_err("bots.get: no bot at that index")
			return _mod_ok(null)
		"bots.face":
			if args.size() < 2 or not _is_number(args[0]) or not _is_number(args[1]):
				return _mod_err("bots.get(i).face needs a yaw")
			if not bots.face_at(int(args[0]), float(args[1])):
				return _mod_err("bots.get: no bot at that index")
			return _mod_ok(null)
	return _mod_err("goats." + name + ": this client does not answer that member")

## A successful `_mod_call` answer.
func _mod_ok(value: Variant) -> String:
	return JSON.stringify({"ok": value})

## ...and a refusal, which the facade throws.
func _mod_err(message: String) -> String:
	return JSON.stringify({"err": message})

## Whether one JSON argument is a number. A `null` is "not given" -- the facade's partial writes
## send it -- and a `null` that reached `float()` would be a *script error* rather than a refusal,
## which is the one thing this seam must never produce (`world.terrainHeight`'s own note above).
func _is_number(value: Variant) -> bool:
	return value is float or value is int

## `player.setMode(next)` (`APIv1.md` section 4.5): only the modes a *script* may enter. `sleep`
## goes through the scene's own water gate, the four gaits are the keys' own, and `jump`/`dead` are
## the simulation's -- so everything else answers `false` rather than throwing, which is `mods.js`'s
## own `setMode` line for line. `eat` is one of those: it needs a tuft the *scene* picked, which is
## the `E` key and the `eat` verb, not a mode a caller can name.
func _mod_set_mode(next: String) -> bool:
	if next == "sleep":
		return goat.start_sleep()
	if next == "idle" or next == "walk" or next == "trot" or next == "run":
		if goat.mode == "dead" or goat.mode == "jump" or goat.mode == "eat":
			return false
		goat.mode = next
		return true
	return false

## `settings.set(options)` (`APIv1.md` section 4.9): a partial object, through the scene's own
## `applySettings`. The reference assigns whatever it is handed; this build's settings are *typed*
## -- booleans, names from the shadow/cloud lists, numbers -- so a value that is not the type its
## field holds is ignored rather than assigned. Assigning it would be a script error at this seam
## instead of a setting. An unknown key is ignored too, which is what the reference's own loop over
## its key list does.
func _mod_apply_settings(options: Dictionary) -> void:
	if options.has("bgm"):
		settings.bgm = clampf(roundf(_mod_number(options["bgm"], settings.bgm)), 0.0, 100.0)
	if options.has("sfx"):
		settings.sfx = clampf(roundf(_mod_number(options["sfx"], settings.sfx)), 0.0, 100.0)
	if options.has("light"):
		settings.light = _mod_setting_bool(options["light"], settings.light)
	if options.has("sky"):
		settings.sky = _mod_setting_bool(options["sky"], settings.sky)
	if options.has("fullscreen"):
		settings.fullscreen = _mod_setting_bool(options["fullscreen"], settings.fullscreen)
	if options.has("shadow") and Settings.SHADOW_NAMES.has(str(options["shadow"])):
		settings.shadow = str(options["shadow"])
	if options.has("cloud") and Settings.CLOUD_NAMES.has(str(options["cloud"])):
		settings.cloud = str(options["cloud"])
	# `herd` is the API's convenience alias for `goats.bots.setCount` (`APIv1.md` section 4.9).
	if options.has("herd") and _is_number(options["herd"]):
		bots.set_herd_size(int(round(float(options["herd"]))))
	settings.push()

## A number, or the value already there -- the "ignored" half of a partial write.
static func _mod_number(value: Variant, current: float) -> float:
	if value is float or value is int:
		return float(value)
	return current

## A boolean, or an `on`/`off`/`toggle` word, which is the console's own vocabulary for the same
## field (`setting light on`). Anything else leaves the field alone.
static func _mod_setting_bool(value: Variant, current: bool) -> bool:
	if value is bool:
		return value
	if value is String:
		var word: String = str(value)
		if word == "on" or word == "off" or word == "toggle":
			return Settings.toggle_word(current, word)
	return current

## This frame's controls, in the form `PlayerGoat.step` wants. `sceneFrame` reads
## its keys the same way and combines them the same way: a held axis, a gait chosen
## by the modifiers, and the four presses.
##
## The console swallows all of it, which is `menu.js`'s `press` and `ctl.js`'s `ctlKeyDown`
## both: typing must never move the goat, so while it is open the frame reads a neutral
## control -- no axis, no gait, no press -- and the `wasd` in a line stay in the line. The
## `_held_*` virtual keys are blocked with the real ones, as `ctlKeyDown` blocks both.
func _controls() -> Dictionary:
	if (console != null and console.open) or (menu != null and menu.is_open()):
		return {"move": 0, "turn": 0, "gait": "walk", "jump": false, "eat": false,
			"sleep": false, "restart": false}
	# The virtual keys first, then the real ones ORed on top -- `ctlKeyDown`'s own order.
	var move: int = 0
	if _held_gait == "walk" or _held_gait == "trot" or _held_gait == "run":
		move += 1
	elif _held_gait == "back":
		move -= 1
	if Input.is_physical_key_pressed(KEY_W):
		move += 1
	if Input.is_physical_key_pressed(KEY_S):
		move -= 1
	var turn: int = 0
	if _held_turn == "left":
		turn += 1
	elif _held_turn == "right":
		turn -= 1
	if Input.is_physical_key_pressed(KEY_A):
		turn += 1
	if Input.is_physical_key_pressed(KEY_D):
		turn -= 1
	var running: bool = Input.is_physical_key_pressed(KEY_SHIFT) or _held_gait == "run"
	var trotting: bool = Input.is_physical_key_pressed(KEY_CTRL) or _held_gait == "trot"
	var gait: String = "walk"
	if running:
		gait = "run"
	elif trotting:
		gait = "trot"
	var controls := {
		"move": move,
		"turn": turn,
		"gait": gait,
		"jump": _jump_pressed,
		"eat": _eat_pressed,
		"sleep": _sleep_pressed,
		"restart": _restart_pressed,
	}
	_jump_pressed = false
	_eat_pressed = false
	_sleep_pressed = false
	_restart_pressed = false
	return controls

## The arrow keys as a camera fallback, and the clamps. `sceneFrame`'s own, with
## the same rates and the same two limits (`TUNING.camera.minDist`/`maxDist`, and a
## pitch that stops short of the poles so the up vector never degenerates).
##
## The console owns the arrow keys while it is open -- they move the caret and walk the
## history there -- so the camera does not also orbit on them.
func _orbit(delta: float) -> void:
	if (console != null and console.open) or (menu != null and menu.is_open()):
		return
	if Input.is_physical_key_pressed(KEY_LEFT):
		_cam_yaw += 1.6 * delta
	if Input.is_physical_key_pressed(KEY_RIGHT):
		_cam_yaw -= 1.6 * delta
	if Input.is_physical_key_pressed(KEY_UP):
		_cam_pitch += 1.0 * delta
	if Input.is_physical_key_pressed(KEY_DOWN):
		_cam_pitch -= 1.0 * delta
	_cam_pitch = clampf(_cam_pitch, Tuning.CAMERA_MIN_PITCH, Tuning.CAMERA_MAX_PITCH)
	_cam_dist = clampf(_cam_dist, Tuning.CAMERA_MIN_DIST, Tuning.CAMERA_MAX_DIST)

## Put the camera where the scene's own camera goes: an orbit of the goat, aimed at
## its shoulders. There is always a goat -- one you drive, offline or not -- so there
## is no case where the camera has nothing to orbit.
##
## The blast's knock moves the camera *and* what it looks at by the same offset, so
## the world shifts rather than the view swinging (`sceneFrame`).
func _place_camera(camera: Camera3D) -> void:
	var focus: Vector3 = goat.focus()
	var knock: Vector3 = explosions.shake_offset()
	camera.position = PlayerGoat.orbit_eye(focus, _cam_yaw, _cam_pitch, _cam_dist) + knock
	camera.look_at(focus + knock)

## Publish this goat to the session, about twenty times a second -- which is the rate
## `NetBridge::pose` documents, because the datagrams are unreliable by design and a
## lost one does not matter.
##
## A *host* publishes too (`net.js` `netMaybePublish` gates on `netInSession`, not on the mode):
## its own goat is local to its scene, but not to the clients', so it is the one goat a client
## cannot derive for itself.
##
## The gait name is the goat's mode, which is the vocabulary the wire's `Gait` enum
## and the scene's own `net.js` both use.
func _publish_pose(delta: float) -> void:
	if not _joined and not _hosting:
		return
	_pose_timer += delta
	if _pose_timer < POSE_INTERVAL:
		return
	_pose_timer = 0.0
	bridge.call("pose", goat.px, goat.pz, goat.yaw, goat.phase, goat.speed, goat.mode,
		goat.py)

## Publish the server's world, about ten times a second -- `net.js` `netMaybePublishWorld`, which
## is a *host's* alone: a client simulates no world and mirrors one instead. It is the whole of
## what a host owns and a client cannot derive: the bots, the sky, the four PRNG streams (so a
## stream a client still draws from continues where the host is), the meadow's eaten cells, the
## ground's craters and the devices that have gone off.
##
## It is one JSON object, and the *same* object the `world` event carries, so the port has one
## shape for a world in both directions and `NetBridge`'s own parse is the only schema.
func _publish_world() -> void:
	if not _hosting:
		return
	var frame: int = Engine.get_process_frames()
	if frame - _world_frame < WORLD_EVERY:
		return
	_world_frame = frame
	var answer: String = String(bridge.call("world", JSON.stringify(_world_payload())))
	# A payload `proto` cannot read is the one failure a scene can act on -- and otherwise
	# invisible, because a dropped snapshot is a world nobody has. It is a bug in `_world_payload`
	# rather than in the session, so it is said out loud rather than folded into a notice.
	if answer != "ok":
		console.net_line("net: world refused: " + answer)
		print("world refused: ", answer)
	# ...and the world mods, on a datagram of their own and at the same rate -- `net.js`
	# `netMaybePublishWorld` queues both, because a mod's state may be bigger than the world's budget
	# and losing it costs a mod rather than everyone's world. Nothing is sent when no world mod
	# contributes anything: the extension answers the empty string, and asking is cheaper than opening
	# a datagram to say nothing.
	var contribution: String = mods.world_mods_json()
	if contribution != "":
		var verdict: String = String(bridge.call("mods", contribution))
		# A payload that is not JSON at all is this scene's bug rather than the session's, the same
		# rule the world's own refusal follows; the *size* refusal is `proto`'s and arrives as a notice.
		if verdict != "ok":
			console.net_line("net: mods refused: " + verdict)
			print("mods refused: ", verdict)

## The world a host publishes, as the one object both directions of the wire share.
##
## Split from the throttled sender above so a gate can read it with no session and no networking --
## the shape is the part that can be silently wrong, since `NetBridge::world` answers an unreadable
## payload with `error: ...` and a dropped snapshot is a world nobody has.
##
## Every field is `net.js`'s own: `sceneWorldBots`'s bots, `sceneWeatherState`'s sky,
## `sceneStreams`'s four PRNG states, `sceneEaten`'s meadow, `netWorldCraters`'s ground and
## `netWorldSpent`'s devices.
func _world_payload() -> Dictionary:
	return {
		"bots": bots.wire(),
		"weather": weather.values(_wind_x, _wind_z, _wind_sway, _hours),
		"streams": {
			"weather": weather.stream(),
			"bots": bots.stream(),
			"food": meadow.stream(),
			"audio": audio.stream(),
		},
		"eaten": meadow.wire(),
		"craters": Craters.wire(),
		"spent": explosions.wire_spent(),
	}

## The mouse: drag to orbit, wheel to zoom, F11 for fullscreen, the backquote that opens the
## console, and Escape for the menu. `sceneFrame`'s ratios, so the feel matches the thing being
## ported.
##
## The console takes the keyboard first, and takes *all* of it while it is open -- a pressed key is
## its line, not the goat's. That is `consoleUpdate`'s "the frame loop gives the console first
## refusal", plus `press`'s own gate on the gameplay keys, in one place because Godot delivers an
## event to one handler rather than polling every key. A **menu** takes everything while it is up,
## which is `press`'s gate (`uiScreen === "hud"`) and `uiIsOpen`'s freeze, both: the only key a menu
## answers is Escape, and Escape walks the screens.
func _unhandled_input(event: InputEvent) -> void:
	if console != null and console.open and event is InputEventKey:
		console.handle_key(event as InputEventKey)
		return
	if menu != null and menu.is_open():
		# A menu is a `uiScreen` value and it owns the input: `press()` is false for every gameplay
		# key while one is up, and Escape is the one thing that gets through.
		if event is InputEventKey:
			var key := event as InputEventKey
			if key.pressed and not key.echo and key.physical_keycode == KEY_ESCAPE:
				_escape()
				get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			_dragging = button.pressed
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_dist -= 0.4
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_dist += 0.4
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		_cam_yaw -= motion.relative.x * 0.004
		_cam_pitch -= motion.relative.y * 0.004
	elif event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		if key.physical_keycode == KEY_QUOTELEFT:
			# Backquote toggles the console, but only from the HUD: with a menu up, the menu owns
			# the input (`consoleUpdate`'s own gate).
			if menu.screen == "hud":
				console.toggle()
			get_viewport().set_input_as_handled()
			return
		if key.physical_keycode == KEY_ESCAPE:
			_escape()
			get_viewport().set_input_as_handled()
			return
		match key.physical_keycode:
			KEY_SPACE:
				_jump_pressed = true
			KEY_E:
				_eat_pressed = true
			KEY_Z:
				_sleep_pressed = true
			KEY_R:
				_restart_pressed = true
			KEY_M:
				# `goat.js`'s `M`: the master mute. The console's `mute` verb drives the same switch, and
				# the menu's `bgm`/`sfx` sliders are this stage's other half.
				audio.set_muted(not audio.muted)
			KEY_L:
				# `goat.js`'s `L`: the lit program or the plain one, which is the settings screen's
				# `Light` toggle. The scene gates it on `litShader >= 0`; the port always has the
				# materials, so it always acts.
				settings.light = not settings.light
				settings.push()
			KEY_K:
				# `goat.js`'s `K`: cycle shadows. The scene's order is map -> planar -> off and it
				# *skips* planar when the build has no planar shader; the port has no planar shader at
				# all, so its cycle is the two words it has (`settings.gd`'s header).
				var at: int = maxi(0, Settings.index_of(Settings.SHADOW_NAMES, settings.shadow))
				settings.shadow = Settings.SHADOW_NAMES[(at + 1) % Settings.SHADOW_NAMES.size()]
				settings.push()
			KEY_B:
				# `goat.js`'s `B`: the sky shader on or off.
				settings.sky = not settings.sky
				settings.push()
			KEY_J:
				# `water.js`'s `J` (M20f): the whole water system's bisect, which is also the `water`
				# console verb's `off`.
				water.enabled = not water.enabled
				water.update()
			KEY_P:
				# `goat.js`'s `P`: freeze the world. The console's `step <n>` is what moves it while
				# it is frozen.
				_paused = not _paused
				_step_frames = 0
			KEY_C:
				# `weather.js`'s `C`: jump to the next state now, for previewing the cycle.
				# The scene gates it on `netWeatherLocal()` -- a client may not force the
				# host's weather -- and so does this.
				if _weather.is_empty():
					weather.force()
			KEY_F11:
				var full: bool = DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_FULLSCREEN
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if full \
					else DisplayServer.WINDOW_MODE_WINDOWED)

## Escape: the menu's own walk, which is `Menu.next_screen` -- from a sub-screen back to `main`,
## from `main` back to the game, and from the game to `main`.
func _escape() -> void:
	menu.show_screen(Menu.next_screen(menu.screen))

## Move the world's clock, its weather and its water on by a frame. The grass is `_process`'s -- it
## follows the goat, which the clock does not -- and the sky is `_apply_sky`'s, because a frozen
## world still has a sky to draw and this function is behind the freeze gate.
##
## The clock is the one thing the wire decides. `weather.js` `applyWeatherState` sets
## `worldTime` from the snapshot and `sceneFrame` advances it only when
## `netWeatherLocal()` -- so a scene with a session follows the host's day, and a
## scene without one is its own host and runs the day at `TUNING.world.dayLength`.
## The wind follows the same split, through the same function (`updateWind`).
##
## The two phase clocks (`_sky_time` for the cloud drift, `_sway_time` for the grass's
## lean) run locally in both cases, which is what the scene does for the sky's and not
## quite for the grass's -- it advances `swayTime` only where `updateWind` runs, so a
## joiner's grass leans at a fixed phase and only the strength of the wind changes.
## That reads as a frozen wind rather than as a faithful mirror, so the port runs the
## clock and lets the *values* come from the wire.
func _advance(delta: float) -> void:
	_sky_time += delta
	_sway_time += delta
	if _weather.is_empty():
		# Offline (or hosting): the weather is ours. The machine walks its own clock and
		# eases toward the state it is in, and the wind is read off the cloudiness it
		# leaves behind -- `updateWind` reads `cloudiness`, so the two are one step.
		if _forced_hour < 0.0:
			_hours = SkyDome.mod24(_hours + delta / SkyDome.DAY_LENGTH * 24.0)
		weather.update(delta)
		var cloud: float = weather.cloudiness
		if _forced_cloud >= 0.0:
			cloud = _forced_cloud
		var gust: Dictionary = SkyDome.wind(_sway_time, cloud)
		_wind_x = gust["x"]
		_wind_z = gust["z"]
		_wind_sway = gust["sway"]
		_cloudiness = cloud
	else:
		# A client: the host owns the weather, so the machine mirrors its values and
		# keeps only the rain's own integration and this goat's effects.
		weather.apply_wire(_weather)
		_hours = float(_weather.get("world_time", _hours))
		_wind_x = float(_weather.get("wind_x", 0.0))
		_wind_z = float(_weather.get("wind_z", 0.0))
		_wind_sway = float(_weather.get("wind_sway", 0.0))
		_cloudiness = float(_weather.get("cloudiness", 0.0))

	# The rain falls whether or not there is a session: a client is sent the *rate* and
	# still has to move its own drops, which is what `weather.js` keeps `rainSeed`
	# separate for.
	weather.update_rain(delta, _wind_x)

	# The water's own clock, once a frame on either path (`goat.js` `waterStep`): the
	# table rises to the rain the instant it moves and drains over `TUNING.water.wetDown`,
	# so a shower leaves standing water behind it.
	water.step(delta, float(_weather_now().get("rain_amount", 0.0)))
	# ...and the surface is told where the table ended up. It is one uniform, which is the
	# whole reason the mesh carries the ground rather than the water: a rising pool costs
	# this line and not a rebuild.
	water_surface.set_level(water.level())
	# The chop's own clock and wind (`waterDraw`'s `waterClock`, `waterSetUniforms`): the
	# clock runs only while there is water to draw, and the wind is the weather's, turned
	# into the unit direction and gust share the shader wants.
	water.advance_clock(delta)
	# ...and the wake, which `waterDraw` steps in the same place and behind the same switch:
	# the clock, then the rings and the drops the frame's own actors laid, then the surface
	# they belong to. A dry field has no wake to have.
	water.wake_step(delta, _wake_actors())
	water_surface.set_chop(water.clock(), water.wave_wind(_wind_x, _wind_z, _wind_sway))
	water_surface.set_ripples(water.ripple_uniform(0), water.ripple_uniform(1),
		water.ripple_uniform(2))

## Put the sky and the light where this frame's values say they are. It is separate from `_advance`
## because a **frozen world still has a sky**: `sceneFrame` draws the sky from `worldTime` outside
## its `dt` gate, so a menu -- which freezes by `dt` -- dims a *drawn* world rather than a black
## one. With this inside `_advance`, a menu opened on the first frame never set a single sky
## uniform and the panel hung over nothing; a picture found it, and no data could.
##
## The cloud drift's own clock (`_sky_time`) is `_advance`'s, so a frozen sky holds still -- which
## is the freeze, and not this.
func _apply_sky(camera: Vector3) -> void:
	_sky_light = float(SkyDome.sample(_hours)["light"])
	SkyDome.apply(_sky_material, world_environment.environment, sun, camera, _hours,
		_sky_light, _cloudiness, _wind_x, _wind_z, _sky_time)
	# The sky program or the flat horizon across it (M25). `apply` sets the sun and the ambient
	# either way -- those are the lighting, not the sky -- and this is the one line the setting
	# changes; it is per-frame because the flat colour has to follow the clock and the clouds.
	if not settings.sky:
		_set_sky_background(false)

## This frame's weather, in the shape the goat and the HUD read it: the session's own
## snapshot in a session, and the local machine's values offline. It is the same
## dictionary `weather.js` `sceneWeatherState` puts on the wire, so offline the scene
## is its own host and the goat feels the rain it is standing in.
func _weather_now() -> Dictionary:
	if _weather.is_empty():
		return weather.values(_wind_x, _wind_z, _wind_sway, _hours)
	return _weather

## The wading this frame, as the two factors `water.gd` derives for the goat's own place
## -- `{ "speed": ..., "drain": ... }`, both 1 out of water. It is derived here because
## it is a function of where the goat is standing, which the field knows and the goat
## does not.
func _wading() -> Dictionary:
	return {
		"speed": water.speed_factor(goat.px, goat.pz),
		"drain": water.drain_factor(goat.px, goat.pz),
	}

## The wake's own actors, in the order `waterActorStep` reads them: the player's goat first,
## then the herd -- the scene's own offline and the host's when joined, which is the one
## `BOTS` array the scene has on either side of the wire.
##
## One flat `(x, z, py)` run and not an array of triples: the water keys its wake marks by a
## position in this list, so the order is the contract rather than a convenience.
func _wake_actors() -> PackedFloat64Array:
	var actors := PackedFloat64Array([goat.px, goat.pz, goat.py])
	actors.append_array(herd.actors() if _joined else bots.actors())
	return actors

## Set off the staging bang, if one was asked for. It lands beside the goat rather
## than under it, so both the hole and the goat are in shot.
func _boom_if_asked() -> void:
	if not _boom:
		return
	_boom_frame += 1
	if _boom_frame == 20:
		explosions.blast("mine", goat.px + 2.0, goat.pz, 0.417, 0)

## An environment variable as a float, or `fallback` when it is unset or not a number.
func _environment_float(name: String, fallback: float) -> float:
	var text: String = OS.get_environment(name)
	if text.is_empty() or not text.is_valid_float():
		return fallback
	return text.to_float()

## One event from the session, routed as `net.js`'s `sceneNetEvent` routes it. What is *this*
## scene's is the world data: the seed, the snapshot a client mirrors, a peer's goat, a bite.
## Everything the scene only reports goes to the console's own network stream, so a session is
## visible where the player is typing -- which is what M24 is for.
func _handle(line: String) -> void:
	var event: Variant = JSON.parse_string(line)
	if not (event is Dictionary):
		return
	match String(event.get("type", "")):
		"session":
			# The seed the world is built from, sent once before anything else. The device
			# field is *derived* from it, so this is what puts this scene's mines where the
			# host's are without a word about where they are -- and the four streams too, which
			# a host runs from this same seed (`sceneUseSeed`).
			var seed: int = int(event.get("seed", 0))
			explosions.use_seed(seed)
			weather.use_seed(seed)
			# The herd's stream is `sceneUseSeed`'s *second* draw, the meadow's the *third* and
			# the variety stream's the *fourth* (`bots.gd`, `meadow.gd`, `audio.gd`). All four
			# matter to a host; a joiner takes the streams the host sends in each world snapshot
			# instead (`use_stream`), so its own draws are overwritten as soon as a world lands.
			bots.use_seed(seed)
			meadow.use_seed(seed)
			audio.use_seed(seed)
			# ...and the *mods'* streams from the same seed, which is `sceneUseSeed`'s own last act: a
			# `side: "world"` mod's PRNG has to be the same one on every peer, or the flock the host
			# simulates is not the flock a joiner computes (`APIv1.md` section 4.13).
			mods.use_seed(seed)
			console.net_line("net: world seed " + str(seed))
		"hosting":
			# This scene is the server. A host keeps simulating the world (`not _joined` in
			# `_process`) and is the one side that *publishes* it, so the flag is what both
			# `_publish_world` and the pose's own gate read. The frames are set a whole interval
			# back, which is `net.js`'s own two lines on this event: publish promptly now that a
			# session exists rather than waiting for the next throttle window.
			_hosting = true
			_net_name = String(event.get("name", ""))
			_world_frame = -WORLD_EVERY
			_pose_timer = POSE_INTERVAL
			console.net_line("net: hosting as " + _net_name)
		"ticket":
			_net_ticket = String(event.get("ticket", ""))
			console.net_line("net: ticket " + _net_ticket)
			console.system_line("net: `copy` puts the ticket on the clipboard")
		"welcome":
			# The canonical name, which may differ from the one asked for: names are first
			# come, first served. This is also what makes the scene a *client* -- until it
			# arrives, a join that was refused is a scene that is still alone.
			_net_name = String(event.get("name", _net_name))
			_joined = true
			_pose_timer = POSE_INTERVAL
			print("welcome: ", event.get("name"))
			console.net_line("net: joined as " + _net_name)
		"joined":
			var who: String = String(event.get("name", ""))
			_roster.append(who)
			console.net_line("net: " + who + " joined")
		"roster":
			var names: Variant = event.get("names", [])
			_roster = (names as Array).duplicate() if names is Array else []
			console.net_line("net: roster " + ", ".join(PackedStringArray(_roster)))
		"chat":
			var from: String = String(event.get("from", ""))
			console.net_line("net: " + ("dm " if bool(event.get("direct", false)) else "") \
				+ ("you" if from == _net_name else from) + ": " + String(event.get("text", "")))
		"disconnected":
			_joined = false
			_hosting = false
			_roster = []
			console.net_line("net: disconnected")
		"world":
			# The weather and the meadow ride every world snapshot, not only the ones
			# that carry a herd: `goatsd` publishes half-built worlds while it loads its
			# scene, and the clock is as true in those as in any other.
			var weather: Variant = event.get("weather", null)
			if weather is Dictionary:
				_weather = weather
			var eaten: Variant = event.get("eaten", null)
			meadow.apply_wire(eaten)
			# The ground the host has cratered and the devices it has seen go off: state
			# rather than events, because a joiner has to see the world as it stands.
			Craters.apply_wire(event.get("craters", null))
			explosions.apply_spent(event.get("spent", null))
			var bots_here: Variant = event.get("bots", [])
			if bots_here is Array and bots_here.size() > 0:
				_measure_motion(bots_here)
				herd.apply(event)
				_worlds += 1
				_last_bots = bots_here.size()
				# The settle clock is a *probe's*, and it arms only for one. It used to arm for
				# anybody who received a herd, and the report at the far end of it `quit()`s --
				# so every Godot client that joined a session with a herd in it quit eight
				# seconds in. `interop.sh herd` sets `GOATS_PROBE`, which is why the gate never
				# saw it; `interop.sh pair` runs two clients that are not probes, which is what
				# found it.
				if _probe and _settle < 0.0:
					_settle = 0.0
		"mods":
			# The host's world mods, beside its world: the mods' streams and whatever each world mod
			# published. A client **adopts** rather than derives -- the streams go on from the host's
			# sequences, and each world mod is handed the state the host published under its id -- which
			# is how a joiner's flock is the host's flock rather than a second simulation of it
			# (`mods.js`'s `sceneApplyWorldMods`, `APIv1.md` section 4.13). A host with nothing to say
			# sends no datagram at all, so this arm only ever sees a contribution.
			var contribution: Variant = event.get("mods", null)
			if contribution is Dictionary:
				mods.apply_world_mods(JSON.stringify(contribution))
				_mods_datagrams += 1
		"notice", "error":
			console.net_line("net: " + ("error " if String(event.get("type", "")) == "error" else "") \
				+ String(event.get("text", "")))
			print(String(event.get("type", "")), ": ", event.get("text"))
		"peer":
			# Another player's goat, on the same rates and the same easing rules a bot's is
			# (`Net`), except that a peer is addressed by *name* and carries a gait its own
			# owner chose -- so it lands in `Peers` rather than in `Herd`.
			peers.apply(String(event.get("name", "")), event.get("state", null))
		"left":
			# A peer that left takes its goat with it. This is the *only* thing that removes
			# a peer: a snapshot stream that stops leaves a goat standing, which is what the
			# client does too, and better than a herd that blinks.
			var gone: String = String(event.get("name", ""))
			peers.remove(gone)
			_roster.erase(gone)
			console.net_line("net: " + gone + " left")
		"consume":
			# A *client's* bite, arriving at the host: record it in this meadow, and the next
			# world snapshot carries it back to everyone -- including the goat that bit.
			meadow.consume_key(int(event.get("key", 0)))
		"blast":
			# A bang the host relayed (M19e), or a host's own goat's. Ours to see and ours to
			# feel, but not ours to fire again: the fire, the hole and the *goats this end
			# simulates* -- a peer's mine flings this player's goat, here, and not on the host.
			explosions.apply_remote_blast(String(event.get("kind", "mine")),
				int(event.get("key", 0)), float(event.get("x", 0.0)), float(event.get("z", 0.0)))
		"blast_report":
			# A client's device went off (M19e), on the host: spend it and dig it here, then hand
			# the relay back with the reporter named -- the host leaves them out, because they
			# have already felt this one. An empty answer is a key that is no device here, and
			# then nothing is relayed at all.
			var kind: String = String(event.get("kind", "mine"))
			var key: int = int(event.get("key", 0))
			var at: Dictionary = explosions.scene_blast_report(kind, key)
			if not at.is_empty():
				bridge.call("blast", kind, key, float(at["x"]), float(at["z"]),
					String(event.get("by", "")))
		_:
			console.net_line("net: unknown event " + line)

## Tell the session about a bite this goat took. A client's duty and nobody else's: a host
## *is* the meadow, and offline there is no session to tell -- which is `food.js`'s own
## `if (!netWorldLocal())` guard, and why this is silent rather than an error.
func _report_bite(cx: int, cz: int) -> void:
	if not _joined:
		return
	bridge.call("consume", Meadow.key(cx, cz))

## Tell the session about a device this process's goat or herd just set off (`net.js`
## `netBlastFired`). Both halves owe it, and `NetBridge` decides what it means from there: a
## client's is a report -- its `x`/`z` are dropped and the host derives where the key is -- and a
## host's is the broadcast every client draws and feels. Silent with no session: the bang is
## already local and there is nobody to tell.
##
## The coordinates are this process's own, which matters only on the host (a client's report
## carries none on the wire, whatever is passed here).
func _report_blast(kind: String, key: int, x: float, z: float) -> void:
	if not _joined and not _hosting:
		return
	bridge.call("blast", kind, key, x, z, "")

func _probe_report() -> void:
	var failures: Array[String] = []
	print("world snapshots: ", _worlds, ", mirroring ", _last_bots, " bot(s)")
	print("mods datagrams: ", _mods_datagrams)
	print("herd: ", herd.count(), " goat(s), ", herd.airborne_count(), " in the air")
	print("grounded gap: %.4f m, largest bot step %.4f m"
		% [herd.worst_gap(), _max_step])
	var ground: Array = herd.ground_range()
	print("ground under the herd: %.3f .. %.3f m" % [ground[0], ground[1]])
	var mark: Vector2 = terrain.anchor()
	print("terrain mesh: %d rebuild(s), anchored (%.0f, %.0f)"
		% [terrain.rebuilds, mark.x, mark.y])
	for line in herd.describe():
		print(line)

	if _worlds == 0:
		failures.append("no world snapshot carrying a herd arrived")
	if herd.count() != _last_bots:
		failures.append("the snapshot named %d bots and the mirror holds %d"
			% [_last_bots, herd.count()])
	if herd.worst_gap() > PROBE_TOLERANCE:
		failures.append("the grounded herd has not converged: worst gap %.4f m" % herd.worst_gap())
	# Agreeing with a herd that never moved would be a weaker thing than it
	# looks, so the probe insists the herd moved while it watched.
	if _max_step < PROBE_MOTION:
		failures.append("no bot moved more than %.4f m between snapshots" % PROBE_MOTION)
	# And agreeing with a herd that is standing on nothing would be weaker still:
	# the spawn bowl is flat, so this only says something because the bots wander
	# out of it.
	if ground[1] - ground[0] < PROBE_RELIEF:
		failures.append("the herd stands on ground that varies by only %.3f m"
			% (ground[1] - ground[0]))
	_report(failures, "the herd mirrors goatsd's bots, on Godot-drawn ground")

## The largest per-bot displacement between consecutive snapshots.
func _measure_motion(bots: Array) -> void:
	var current := {}
	for entry in bots:
		if not (entry is Dictionary):
			continue
		var index: int = int(entry.get("index", 0))
		var spot := Vector2(float(entry.get("x", 0.0)), float(entry.get("z", 0.0)))
		current[index] = spot
		if _previous.has(index):
			_max_step = maxf(_max_step, spot.distance_to(_previous[index]))
	_previous = current

## Report and exit. Used by the probe, and by a probe that was started without a
## session; a plain run without a ticket does not come here at all, because
## joining is optional (`_ready`).
func _report(failures: Array, ok_message: String = "") -> void:
	# Close the session and join its runtime thread before the process ends. The
	# bridge also does this when it leaves the tree, but a probe quits while the
	# tree is still up, so it says so explicitly.
	bridge.call("shutdown")
	if failures.is_empty():
		print("OK: ", ok_message)
		get_tree().quit(0)
		return
	# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
	# flushes, so a failure written there is never seen.
	for failure in failures:
		print("FAIL: ", failure)
	get_tree().quit(1)

# ---- the console's own seams (M24) -----------------------------------------
#
# `commands.gd` reaches the frame's state through these, by name. Each is one thing the
# frame owns and no module does -- the clock, the wind, the camera, the pause and its step
# counter, the UI screen, quitting, the screenshot, the two virtual keys, and the session --
# so the vocabulary stays a vocabulary and the frame stays the frame.

## Hand the console's vocabulary everything it reads: the world modules as typed references,
## the console itself, and this frame for the knobs only it owns.
func _build_commands() -> void:
	commands.goat = goat
	commands.meadow = meadow
	commands.water = water
	commands.water_reflect = water_reflect
	commands.explosions = explosions
	commands.audio = audio
	commands.weather = weather
	commands.bots = bots
	commands.herd = herd
	commands.console = console
	commands.mods = mods
	commands.scene = self

func cmd_hours() -> float:
	return _hours

func cmd_set_hours(hours: float) -> void:
	_hours = hours

func cmd_wind_sway() -> float:
	return _wind_sway

func cmd_camera() -> Dictionary:
	return {"yaw": _cam_yaw, "pitch": _cam_pitch, "dist": _cam_dist}

func cmd_set_camera(yaw: float, pitch: float, dist: float) -> void:
	_cam_yaw = yaw
	_cam_pitch = clampf(pitch, Tuning.CAMERA_MIN_PITCH, Tuning.CAMERA_MAX_PITCH)
	_cam_dist = clampf(dist, Tuning.CAMERA_MIN_DIST, Tuning.CAMERA_MAX_DIST)

## `camera reset`: the three numbers `TUNING.camera` boots with, which are this frame's
## starting values.
func cmd_camera_reset() -> void:
	_cam_yaw = Tuning.CAMERA_YAW
	_cam_pitch = Tuning.CAMERA_PITCH
	_cam_dist = Tuning.CAMERA_DIST

func cmd_paused() -> bool:
	return _paused

func cmd_set_paused(paused: bool) -> void:
	_paused = paused
	_step_frames = 0

## `step <n>`: unfreeze for n frames and re-pause at the end of them, which `_process` does.
func cmd_step(steps: int) -> void:
	_paused = false
	_step_frames = steps

func cmd_ui() -> String:
	return menu.screen

func cmd_set_ui(screen_word: String) -> void:
	menu.show_screen(screen_word)

func cmd_quit() -> void:
	bridge.call("shutdown")
	get_tree().quit(0)

## Write the current frame to `path`. A headless run has no rasteriser to read back, which
## `WaterReflect.can_ground` asks the same way; an empty string is success, a word is the
## failure `commands.gd` puts after `error screenshot `.
func cmd_screenshot(path: String) -> String:
	if DisplayServer.get_name() == "headless":
		return "needs a window"
	var image: Image = get_viewport().get_texture().get_image()
	if image == null:
		return "could not read the frame"
	return "" if image.save_png(path) == OK else "could not write " + path

## The direction the console's held gait implies, which is `ctlHeldMove`.
func cmd_held_move() -> int:
	if _held_gait == "walk" or _held_gait == "trot" or _held_gait == "run":
		return 1
	if _held_gait == "back":
		return -1
	return 0

## The gait the console is holding, which is `ctlHeldGait`.
func cmd_held_gait() -> String:
	if _held_gait == "run":
		return "run"
	if _held_gait == "trot":
		return "trot"
	return "walk"

func cmd_set_gait(gait: String) -> void:
	if gait == "walk" or gait == "trot" or gait == "run" or gait == "back":
		_held_gait = gait
	else:
		_held_gait = "stop"

func cmd_set_turn(dir: String) -> void:
	_held_turn = dir if dir == "left" or dir == "right" else "stop"

## Whether the frame is a *client*, which is `_joined`: it is what the console's `bots` verb
## and the herd's mirror switch read.
func cmd_is_client() -> bool:
	return _joined

## `netStatus()`: the mode, this player's name, the ticket, and the roster. The mode is three-valued
## (`net.js`'s `netMode`): a host keeps simulating the world a client mirrors, so the two cannot be
## one flag -- and it is what the console's `_in_session` reads to know either side is a session.
func cmd_net_status() -> Dictionary:
	return {
		"mode": "host" if _hosting else ("client" if _joined else "off"),
		"name": _net_name,
		"ticket": _net_ticket,
		"roster": _roster,
	}

## `host [name]`: serve a session, and be the side that owns the world (`net.js` `netHost`). The
## scene boots into a solo world and only serves when it is asked to, so this is the console's way
## in. The name is a request: the `hosting` event carries the canonical one, which may differ.
func cmd_host(name: String) -> String:
	if _joined or _hosting:
		return "error already in a session (leave first)"
	bridge.call("host", name)
	_hosting = true
	_net_name = name
	return "ok host"

## `connect`: join the session a ticket names. The scene joins on startup from
## `GOATSD_TICKET`; this is the console's own way in, and the one the prompt's answer lands in.
func cmd_join(ticket: String, name: String) -> String:
	if _joined or _hosting:
		return "error already in a session (leave first)"
	var asked: String = name if name != "" else "godot"
	bridge.call("join", ticket, asked)
	_net_ticket = ticket
	_net_name = asked
	_joined = true
	return "ok connect"

func cmd_leave() -> String:
	if not _joined and not _hosting:
		return "error not in a session"
	bridge.call("leave")
	_joined = false
	_hosting = false
	_net_ticket = ""
	_roster = []
	return "ok leave"

func cmd_say(text: String) -> String:
	bridge.call("say", text)
	return ""

func cmd_ticket() -> String:
	return _net_ticket

## The main menu's `Console` button: close the menu and open the console, which is
## `drawMainMenu`'s own two lines.
func _open_console() -> void:
	if not console.open:
		console.toggle()

## `applySettings`: every setting pushed where it belongs. The settings are the *values* and this
## is what a value means -- which is why `settings.gd` hands the whole thing here rather than
## knowing what `cloud high` costs.
##
## Five of the seven are the port's own switches (`PORT.md` section 5, decided): the lit materials
## and the unshaded ones are `TerrainMesh.shading` on the ground, the tufts, the goat's rig and the
## herd's coats; the shadow map is Godot's `sun.shadow_enabled`; and the sky program is the
## environment's `sky_material`, with a flat horizon colour standing in for it when it is off.
## The reflection tier is the water's own leaf, applied through the pass that draws it.
func _apply_settings() -> void:
	audio.bgm = settings.bgm
	audio.sfx = settings.sfx

	# Lighting: the four things the scene draws through its lit program.
	terrain.set_lit(settings.light)
	grass.set_lit(settings.light)
	goat.set_lit(settings.light)
	bots.set_lit(settings.light)

	# Shadows: Godot's map or nothing. `planar` is not a word this port has (`settings.gd`).
	sun.shadow_enabled = settings.shadow != "off"

	# The sky: the raymarched program, or a flat horizon colour. `_advance` decides which on every
	# frame from the same setting, so this only has to say it once here.
	SkyDome.cloud_level = maxi(0, Settings.index_of(Settings.CLOUD_NAMES, settings.cloud))
	_set_sky_background(settings.sky)

	# Fullscreen, if the window is not already where the setting says.
	var wanted: int = DisplayServer.WINDOW_MODE_FULLSCREEN if settings.fullscreen \
		else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != wanted:
		DisplayServer.window_set_mode(wanted)

	# The water's reflection is the leaf's, and the pass is what draws it.
	water_reflect.apply(water_surface, water_mirror)

## The sky program on or off. Off, the environment draws a flat colour at the horizon -- which is
## what `useSkyShader = false` falls back to in the scene, a gradient instead of the raymarched
## slab -- and on, the material is back.
func _set_sky_background(on: bool) -> void:
	var environment: Environment = world_environment.environment
	if on:
		environment.sky.sky_material = _sky_material
		environment.background_mode = Environment.BG_SKY
		return
	var curve: Dictionary = SkyDome.sample(_hours)
	var horizon: Color = SkyDome.overcast(curve["bot"], SkyDome.OVERCAST_BOT, _cloudiness)
	environment.sky.sky_material = null
	environment.background_mode = Environment.BG_COLOR
	# The environment's colours are linear here, which is the conversion `SkyDome.apply` makes for
	# the *shader's* uniforms (`_linear`); the sky curve is display space.
	environment.background_color = horizon.srgb_to_linear()
