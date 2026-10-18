# The command vocabulary (M24): `ctl.js`'s `sceneCommand` transcribed, and the console's
# other half.
#
# The scene dispatches every submitted console line -- and every line the host's stdin
# channel reads -- through one `sceneCommand`, so a command a script or a harness drives
# and a command a person types are the same command. This is that dispatcher, and it is
# the *whole* vocabulary: `HELP_GROUPS` and `HELP` first, then about sixty verbs in
# `ctl.js`'s own order, each answering one line: `ok …` or `error …`, with queries
# returning JSON after `ok ` and a `void` reply meaning "ok" in the console's protocol.
#
# The scene's `sceneCommand` reads module globals -- `goat`, `mode`, `SETTINGS`, `BOTS`,
# `paused`, `worldTime`. This language has none, so the same values arrive two ways:
#
#   * **world modules** as typed references the scene hands in (`goat`, `meadow`, `water`,
#     `explosions`, `audio`, `weather`, `bots`, `herd`, `water_reflect`), because they are
#     objects with real APIs and a typo should be a parse error;
#   * **the scene's own knobs** as small named methods on the scene node (`cmd_*`), called
#     dynamically, because they are the frame's state and the frame owns them -- the
#     clock, the camera, the pause, the UI screen, quitting, the session. The names are
#     listed in `main.gd` beside the frame loop they belong to.
#
# What is *not* here is as deliberate as what is, and each is an honest answer rather than
# a silent stub: a verb answers `error <system> unavailable` when the system behind it is a
# later stage. Those are gathered in one place at the bottom of this header so the next
# stage can find them, and so a gate can assert the *list* rather than hope:
#
#   * **`tune`** -- the tuning tree is the mod surface's (stage 8), and the port has
#     constants rather than a tree to walk.
#   * **`perf`** -- the frame-cost benchmark measures the JavaScript host's own phases;
#     there is no Godot harness behind it yet.
#   * **`mod`** -- the scene loads mods as of stage 1 (`mods.gd` + the extension's `ModHost`),
#     so `mod list` and `mod key` are backed and a mod's own verb gets first refusal; `info`,
#     `enable`, `disable` and `reload` need `mods.js`'s other half, which is stage 8.
#   * **`pools`** -- the water's connected regions (M20f), a flood fill over the water grid.
#   * **`screenshot`** -- backed with a window, `error screenshot needs a window` under
#     `--headless`, where there is no rasteriser to read back.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`, whose
# warning bites hardest here: this file is a long list of calls to its own `static` helpers,
# and `var x := ctl_arg(...)` would make the analyser loop forever.
class_name Commands
extends RefCounted

## `ctl.js`'s `HELP_GROUPS`, verbatim: one topic per line, and the words that go on it.
const HELP_GROUPS := [
	["basics", "help ping"],
	["state", "state stats time weather bots camera pos phase features fps"],
	["move", "jump sleep wake walk trot run back stop turn yaw"],
	["vitals", "health energy heal eat grass traps craters water pools restart kill"],
	["view", "lighting shadows sky flood mute settings setting tune perf ui console screenshot"],
	["session", "host connect leave who net copy say msg"],
	["mods", "mod"],
	["flow", "pause resume step quit"],
]

## The one flag `connect` takes, and the *whole* of the per-join consent to fetch a host's world
## mods (M18d): `net.js`'s `NET_PULL_FLAG`. A mod is code, so it is only ever fetched because
## somebody said so -- here or with the standing `GOATS_PULL` the bridge holds.
const PULL_FLAG := "--pull"

## The console's clamps are *not* copies: the stats ceiling is the goat's own leaf
## (`PlayerGoat.STATS_MAX`) and the camera's are the tree's (`Tuning.CAMERA_*`), so a mod that
## raises `stats.max` or `camera.maxDist` moves what the console's own verbs allow too.

## The world modules the scene hands in. Each may be null in a gate that never reaches the
## verb that uses it, and every verb guards for that.
var goat: PlayerGoat
var meadow: Meadow
var water: Water
var water_reflect: WaterReflect
var explosions: Explosions
var audio: Audio
var weather: Weather
var bots: Bots
var herd: Herd
## The mod runtime: the table `mod list` prints, the world digests `mod key` reads, and the
## first refusal a mod's own console verb gets. `null` in a gate that holds only the pure rules.
var mods: Mods
## The shell the `console` verb drives: it opens, closes, toggles and submits through it.
var console: Console
## The frame, for the `cmd_*` knobs. `null` in a gate that only holds the pure dispatch.
var scene: Node

## `ctl.js`'s `SETTINGS` (M25), shared with the menu's settings screen and the HUD's read-outs.
## It defaults to a fresh object so a gate can build a bare `Commands` and still reach the verbs
## that only read or write a setting; the frame hands in the one it and the menu both hold.
var settings := Settings.new()

## The two pure helpers `sceneCommand` leans on, spelled as it spells them.
##
## `Number(parts[index])` and `Number.isFinite`: a token that is not a finite number is
## `null`, which is the scene's `null` and this file's "no argument". It is `static` because
## it is a rule about text, not about a scene, and a gate holds it with no scene at all.
static func ctl_arg(parts: PackedStringArray, index: int) -> Variant:
	if index >= parts.size():
		return null
	var token: String = parts[index]
	if not token.is_valid_float():
		return null
	return token.to_float()

## `Math.round(value * 100) / 100`. JavaScript's `Math.round` is *half toward +infinity*,
## which Godot's `round` is not (half away from zero), so the two differ at an exact `.5` --
## and a position in this world is as likely to be negative as positive. `floor(x + 0.5)` is
## the scene's own round, transcribed rather than approximated.
static func ctl_round(value: float) -> float:
	return floor(value * 100.0 + 0.5) / 100.0

## `ctlToggle`, which is `Settings.toggle_word`'s own rule -- kept here as the name `ctl.js` uses
## so the verbs read as they do in the source, delegating so the two cannot drift.
static func ctl_toggle(current: bool, arg: String) -> bool:
	return Settings.toggle_word(current, arg)

## A value as `JSON.stringify` would write it, minus the key sort -- the scene preserves
## insertion order and so does a Godot `Dictionary`, so the reply reads as `ctl.js`'s does.
static func json_of(value: Variant) -> String:
	return JSON.stringify(value, "", false)

## A number as JavaScript's `String(n)` writes it: an integral value has no decimal point,
## where Godot's `str(6.0)` is `"6.0"`. Every reply that appends a `ctl_round`ed number is
## standing in for a JavaScript string concatenation, so it has to read the same way.
static func num(value: float) -> String:
	if is_finite(value) and value == floor(value) and absf(value) < 1.0e15:
		return str(int(value))
	return str(value)

## The `HELP` page: the header, then one indented line per group with its topic padded to
## eight. `ctl.js` builds it once; here it is a function, because a `static var` initialised
## by a same-class call is exactly the analyser loop the header warns about.
static func help_text() -> String:
	var rows := PackedStringArray(["help - commands by topic"])
	for group: Array in HELP_GROUPS:
		rows.append("  " + String(group[0]).rpad(8) + String(group[1]))
	return "\n".join(rows)

## The weather states as `Object.keys(WEATHER_STATES).join("|")`, for the one error string
## that lists them.
static func weather_words() -> String:
	var names := PackedStringArray()
	for name in Weather.STATES:
		names.append(String(name))
	return "|".join(names)

## `drawHud`'s `lightingText` and sky word are `Settings`' now (M25) -- the settings screen is the
## other writer, and one function is what keeps the console and the menu agreeing. What `lighting`
## and `sky` *do* here is the materials' `shading_mode` and the environment's background, which is
## the frame's `apply` (`main.gd`).

## A value as `JSON.stringify` would write it, minus the key sort -- the scene preserves
## `sceneCommand(line)`: one line in, one line out.
func run(line: String) -> String:
	# `String(line).trim().split(/\s+/)`: the strip and the empty-token drop together are the
	# regex's collapsing of runs of whitespace. A console line has no tabs in it -- paste
	# strips every codepoint below 32 (`console.gd` `sanitize_paste`) -- so spaces are the
	# whole of the whitespace that can reach here.
	var parts: PackedStringArray = line.strip_edges().split(" ", false)
	if parts.is_empty():
		return "error empty command"
	# `/who` and `who` are the same command: the slash is just what people type in something
	# that looks like a chat box.
	if parts[0].length() > 1 and parts[0].begins_with("/"):
		parts[0] = parts[0].substr(1)
	var command: String = parts[0]
	if command == "":
		return "error empty command"

	match command:
		"help":
			return "ok " + help_text()
		"ping":
			return "ok pong"

		# ---- queries -----------------------------------------------------
		"state":
			return "ok " + json_of(_state())
		"stats":
			return "ok " + json_of({
				"health": ctl_round(goat.health),
				"energy": ctl_round(goat.energy),
				"exhausted": goat.exhausted,
			})
		"time":
			return _time(parts)
		"weather":
			return _weather(parts)
		"bots":
			return "ok " + json_of(_bots())
		"camera":
			return _camera(parts)
		"features":
			return "ok " + json_of({
				"lighting": settings.light,
				"shadows": settings.shadow,
				"sky": settings.sky,
				"cloud": settings.cloud,
				"fullscreen": _is_fullscreen(),
				"muted": audio.muted,
				"paused": bool(_call("cmd_paused")),
				"fps": Engine.get_frames_per_second(),
			})
		"fps":
			return "ok " + str(Engine.get_frames_per_second())

		# ---- settings / UI ----------------------------------------------
		"settings":
			return "ok " + json_of(_settings())
		"setting":
			return _setting(parts)
		# Any leaf of the tuning tree, by path. The tree is the mod surface's (stage 8) and
		# the port has constants rather than one, so this is the honest answer rather than a
		# second vocabulary for the handful this file could reach.
		"tune":
			return "error tune unavailable"
		"ui":
			return _ui(parts)

		# ---- console (M9) ------------------------------------------------
		"console":
			return _console(parts)

		# ---- net ---------------------------------------------------------
		"host":
			return _host(parts)
		"connect", "join":
			return _connect(parts)
		"leave", "disconnect":
			return _leave()
		"who":
			if not _in_session():
				return "error not in a session"
			return "ok " + json_of(_net_status())
		"net":
			return "ok " + json_of(_net_status())
		"swarm":
			return _swarm(parts)
		"copy":
			return _copy(parts)
		"say":
			return _say(" ".join(parts.slice(1)))
		"msg", "tell", "whisper":
			if parts.size() < 2:
				return "error msg expects a name"
			var body: String = " ".join(parts.slice(2))
			if body == "":
				return "error msg expects a message"
			# A whisper is just a chat line with a leading `@name`, which is the one form the
			# server routes for both sides.
			return _say("@" + parts[1] + " " + body)

		# ---- goat state --------------------------------------------------
		"jump":
			if goat.mode == "dead":
				return "error cannot jump while dead"
			if goat.mode == "sleep":
				return "error cannot jump while asleep"
			goat.start_jump(int(_call("cmd_held_move")), String(_call("cmd_held_gait")))
			return "ok jump"
		"sleep":
			if goat.mode == "dead":
				return "error cannot sleep while dead"
			if goat.mode == "sleep":
				return "error already asleep"
			if not goat.start_sleep():
				return "error cannot sleep in the water"
			return "ok sleep"
		"wake":
			if goat.mode != "sleep":
				return "error not asleep"
			goat.wake_up()
			return "ok wake"
		"restart":
			goat.restart()
			return "ok restart"
		"kill":
			if goat.mode == "dead":
				return "error already dead"
			goat.die()
			return "ok kill"
		"health":
			var health: Variant = ctl_arg(parts, 1)
			if health == null:
				return "error health expects a number"
			goat.health = clampf(float(health), 0.0, PlayerGoat.STATS_MAX)
			return "ok health " + num(ctl_round(goat.health))
		"energy":
			var energy: Variant = ctl_arg(parts, 1)
			if energy == null:
				return "error energy expects a number"
			goat.energy = clampf(float(energy), 0.0, PlayerGoat.STATS_MAX)
			goat.exhausted = goat.energy <= 0.0
			return "ok energy " + num(ctl_round(goat.energy))
		"heal":
			goat.health = PlayerGoat.STATS_MAX
			goat.energy = PlayerGoat.STATS_MAX
			goat.exhausted = false
			return "ok heal"

		# ---- food --------------------------------------------------------
		"grass":
			return _grass(parts)
		"traps":
			return _traps(parts)
		"craters":
			return _craters(parts)
		"water":
			return _water(parts)
		"pools":
			# The connected regions are the *scene's* flood fill (M20f), so a `Commands` with no water
			# behind it -- a gate's, or a build without the module -- says so rather than faulting.
			if water == null:
				return "error pools unavailable"
			return "ok " + json_of(water.pools())
		"flood":
			return _flood(parts)
		"perf":
			return "error perf unavailable"
		"eat":
			var target: Dictionary = meadow.nearest(goat.px, goat.pz, Meadow.EAT_RANGE)
			if target.is_empty():
				return "error no grass in reach"
			goat.start_eat(target, meadow, Callable(explosions, "trip_trap_at"))
			return "ok eat"

		# ---- movement ----------------------------------------------------
		"walk", "trot", "run", "back", "stop":
			_call("cmd_set_gait", [command])
			return "ok " + command
		"turn":
			var dir: String = parts[1] if parts.size() > 1 else "stop"
			if dir != "left" and dir != "right" and dir != "stop":
				return "error turn expects left|right|stop"
			_call("cmd_set_turn", [dir])
			return "ok turn " + dir
		"yaw":
			var degrees: Variant = ctl_arg(parts, 1)
			if degrees == null:
				return "error yaw expects degrees"
			goat.yaw = deg_to_rad(float(degrees))
			return "ok yaw " + num(ctl_round(goat.yaw))
		"pos":
			var x: Variant = ctl_arg(parts, 1)
			var z: Variant = ctl_arg(parts, 2)
			if x == null or z == null:
				return "error pos expects <x> <z>"
			goat.px = float(x)
			goat.pz = float(z)
			return "ok pos " + num(ctl_round(goat.px)) + " " + num(ctl_round(goat.pz))
		"phase":
			var value: Variant = ctl_arg(parts, 1)
			if value == null:
				return "error phase expects a number"
			goat.phase = fposmod(float(value), 1.0)
			return "ok phase " + num(ctl_round(goat.phase))

		# ---- toggles -----------------------------------------------------
		"pause":
			_call("cmd_set_paused", [true])
			return "ok pause"
		"resume":
			_call("cmd_set_paused", [false])
			return "ok resume"
		"step":
			var count: Variant = ctl_arg(parts, 1)
			if count == null or float(count) < 1.0:
				return "error step expects a positive frame count"
			_call("cmd_step", [int(floor(float(count)))])
			return "ok step " + str(int(floor(float(count))))
		"lighting":
			# `L`'s verb: the lit materials and the unshaded ones (M25). The scene swaps a shader;
			# Godot swaps a material's `shading_mode`, which is the same bisect in this engine.
			var arg: String = parts[1] if parts.size() > 1 else ""
			settings.light = ctl_toggle(settings.light, arg)
			settings.push()
			return "ok lighting " + ("on" if settings.light else "off")
		"shadows":
			var name: String = parts[1] if parts.size() > 1 else "off"
			# The scene's own error, word for word: `planar` is a fallback for a build without a
			# shadow map, and Godot always has one (see `settings.gd`'s header).
			if name == "planar":
				return "error planar shadow unavailable"
			if Settings.index_of(Settings.SHADOW_NAMES, name) < 0:
				return "error shadows expects " + "|".join(Settings.SHADOW_NAMES)
			settings.shadow = name
			settings.push()
			return "ok shadows " + name
		"sky":
			# `B`'s verb: the raymarched sky or a flat horizon across it.
			var arg: String = parts[1] if parts.size() > 1 else ""
			settings.sky = ctl_toggle(settings.sky, arg)
			settings.push()
			return "ok sky " + ("on" if settings.sky else "off")
		"mute":
			var arg: String = parts[1] if parts.size() > 1 else ""
			audio.set_muted(ctl_toggle(audio.muted, arg))
			return "ok mute " + ("on" if audio.muted else "off")

		# ---- mods --------------------------------------------------------
		"mod":
			return _mod(parts)

		# ---- host --------------------------------------------------------
		"screenshot":
			if parts.size() < 2:
				return "error screenshot expects a path"
			var took: String = String(_call("cmd_screenshot", [" ".join(parts.slice(1))]))
			return "ok screenshot" if took == "" else "error screenshot " + took
		"quit":
			_call("cmd_quit")
			return "ok quit"

		_:
			# A mod's registered verb gets first refusal, which is `mods.js`'s own order: a mod
			# extends the vocabulary, so a word it claims is not chat. `run_command` answers `""`
			# for a word nobody claims -- an empty reply is also how a command says "nothing to
			# print", so the two are told apart by whether a mod is there at all.
			if mods != null:
				var reply: String = mods.run_command(command, line.strip_edges())
				if reply != "":
					return reply
			# What is left is the console's chat: in a session, anything that is not a command is
			# something to say -- which is what makes the console a chat box. Offline it stays an
			# error, so a typo is still caught rather than broadcast.
			if _in_session():
				return _say(line.strip_edges())
			return "error unknown command: " + command

## `state`: the goat, the world and the frame, as `ctl.js`'s object literal.
func _state() -> Dictionary:
	return {
		"mode": goat.mode,
		"clip": goat.playing_clip(),
		"health": ctl_round(goat.health),
		"energy": ctl_round(goat.energy),
		"exhausted": goat.exhausted,
		"paused": bool(_call("cmd_paused")),
		"satiety": ctl_round(goat.satiety),
		"foodInReach": not meadow.nearest(goat.px, goat.pz, Meadow.EAT_RANGE).is_empty(),
		"eaten": meadow.eaten_count,
		"x": ctl_round(goat.px),
		"y": ctl_round(goat.py),
		"z": ctl_round(goat.pz),
		"ground": ctl_round(Terrain.height_at(goat.px, goat.pz)),
		"yaw": ctl_round(goat.yaw),
		"phase": ctl_round(goat.phase),
		"time": ctl_round(float(_call("cmd_hours"))),
		"weather": weather.kind,
		"fps": Engine.get_frames_per_second(),
		"frame": Engine.get_process_frames(),
	}

## `time`, both halves: with no argument it is the clock, and with one it sets the hour.
## Setting it is not *pinning* it -- the scene's `worldTime` moves on as the day does, and
## `GOATS_HOUR` is the staging knob that holds it still.
func _time(parts: PackedStringArray) -> String:
	if parts.size() == 1:
		var hours: float = float(_call("cmd_hours"))
		var hh: int = int(floor(hours))
		var mm: int = int(floor((hours - float(hh)) * 60.0))
		return "ok " + json_of({
			"hours": ctl_round(hours),
			"clock": "%02d:%02d" % [hh, mm],
		})
	var wanted: Variant = ctl_arg(parts, 1)
	if wanted == null:
		return "error time expects hours"
	var wrapped: float = SkyDome.mod24(float(wanted))
	_call("cmd_set_hours", [wrapped])
	return "ok time " + num(ctl_round(wrapped))

## `weather`: the machine's values, or a named state to go to. `go_to` is the verb's own
## transition -- `hold` is the staging knob's steady picture -- and a word the machine does
## not know is the scene's own error, listing the words it does.
func _weather(parts: PackedStringArray) -> String:
	if parts.size() == 1:
		return "ok " + json_of({
			"kind": weather.kind,
			"cloudiness": ctl_round(weather.cloudiness),
			"rain": ctl_round(weather.rain_amount),
			"wind": ctl_round(float(_call("cmd_wind_sway"))),
			"speed": ctl_round(goat.weather_speed_now()),
		})
	var state: String = parts[1]
	if not weather.go_to(state):
		return "error unknown weather: " + state + " (want " + weather_words() + ")"
	return "ok weather " + state

## `bots`: the herd the goat is standing among -- the scene's own offline, the host's mirror
## in a session, which is the same switch `main.gd`'s HUD makes.
func _bots() -> Dictionary:
	var list: Array = bot_list()
	return {"count": list.size(), "bots": list}

## The herd's per-goat read-out, from whichever of the two the frame is running.
func bot_list() -> Array:
	if _joined_scene():
		return herd.report() if herd != null else []
	return bots.report() if bots != null else []

## `camera`: the query, `reset`, or the three angles. Degrees in, radians kept -- which is
## `ctl.js`'s own conversion, and the query reads back what was kept.
func _camera(parts: PackedStringArray) -> String:
	if parts.size() == 1:
		return "ok " + json_of(_call("cmd_camera"))
	if parts[1] == "reset":
		_call("cmd_camera_reset")
		return "ok camera reset"
	var yaw: Variant = ctl_arg(parts, 1)
	var pitch: Variant = ctl_arg(parts, 2)
	var dist: Variant = ctl_arg(parts, 3)
	if yaw == null or pitch == null or dist == null:
		return "error camera expects <yawDeg> <pitchDeg> <dist>"
	var out_yaw: float = deg_to_rad(float(yaw))
	var out_pitch: float = clampf(deg_to_rad(float(pitch)), Tuning.CAMERA_MIN_PITCH, Tuning.CAMERA_MAX_PITCH)
	var out_dist: float = clampf(float(dist), Tuning.CAMERA_MIN_DIST, Tuning.CAMERA_MAX_DIST)
	_call("cmd_set_camera", [out_yaw, out_pitch, out_dist])
	return "ok camera %s %s %s" % [num(ctl_round(out_yaw)), num(ctl_round(out_pitch)),
		num(ctl_round(out_dist))]

## `settings`: the read-outs the settings screen drives (M25), at the values the scene has. It is
## `ctl.js`'s object literal, including `fullscreen` from `SETTINGS` rather than from the window
## -- `features` reports the window, which is the scene's own split.
func _settings() -> Dictionary:
	return {
		"bgm": int(settings.bgm),
		"sfx": int(settings.sfx),
		"light": settings.light,
		"shadow": settings.shadow,
		"sky": settings.sky,
		"cloud": settings.cloud,
		"reflect": WaterReflect.tier_word(water_reflect.tier()),
		"fullscreen": settings.fullscreen,
		"herd": bots.count() if bots != null else 0,
	}

## `setting <key> [value]`: every key the settings screen has, and one `applySettings` at the end
## -- which is the scene's own shape, and what makes `setting reflect` reach the surface rather
## than only the leaf.
func _setting(parts: PackedStringArray) -> String:
	var key: String = parts[1] if parts.size() > 1 else ""
	match key:
		"bgm", "sfx":
			var gain: Variant = ctl_arg(parts, 2)
			if gain == null:
				return "error setting " + key + " expects a number"
			var level: float = clampf(roundf(float(gain)), 0.0, 100.0)
			if key == "bgm":
				settings.bgm = level
			else:
				settings.sfx = level
		"light", "sky":
			var arg: String = parts[2] if parts.size() > 2 else ""
			if arg != "on" and arg != "off" and arg != "toggle":
				return "error setting " + key + " expects on|off|toggle"
			if key == "light":
				settings.light = Settings.toggle_word(settings.light, arg)
			else:
				settings.sky = Settings.toggle_word(settings.sky, arg)
		"shadow":
			var shadow_word: String = parts[2] if parts.size() > 2 else ""
			if Settings.index_of(Settings.SHADOW_NAMES, shadow_word) < 0:
				return "error setting shadow expects " + "|".join(Settings.SHADOW_NAMES)
			settings.shadow = shadow_word
		"reflect":
			var reflect_word: String = parts[2] if parts.size() > 2 else ""
			var tier: int = WaterReflect.word_tier(reflect_word)
			if tier < 0:
				return "error setting reflect expects sky|ground|mirror"
			water_reflect.set_wish(float(tier))
		"herd":
			var herd_size: Variant = ctl_arg(parts, 2)
			if herd_size == null:
				return "error setting herd expects a number"
			if bots != null:
				bots.set_herd_size(int(roundf(float(herd_size))))
		"cloud":
			var cloud_word: String = parts[2] if parts.size() > 2 else ""
			if Settings.index_of(Settings.CLOUD_NAMES, cloud_word) < 0:
				return "error setting cloud expects " + "|".join(Settings.CLOUD_NAMES)
			settings.cloud = cloud_word
		_:
			return "error unknown setting: " + key
	# `applySettings()`, once, for whichever key moved.
	settings.push()
	return "ok setting " + key

## `ui`: which screen is showing. The menu draws four of them (M25) and `hud` is the game, so
## this is the scene's own five words and every one of them lands somewhere.
func _ui(parts: PackedStringArray) -> String:
	if parts.size() == 1:
		return "ok " + String(_call("cmd_ui"))
	var screen: String = parts[1]
	if screen != "hud" and screen != "main" and screen != "settings" \
			and screen != "keymap" and screen != "mods":
		return "error ui expects hud|main|settings|keymap|mods"
	_call("cmd_set_ui", [screen])
	return "ok ui " + screen

## `console`: open, close, toggle, submit a line, or report the shell's own state.
func _console(parts: PackedStringArray) -> String:
	var action: String = parts[1] if parts.size() > 1 else ""
	if action == "open":
		if not console.open:
			console.toggle()
		return "ok console open"
	if action == "close":
		console.close()
		return "ok console close"
	if action == "toggle":
		console.toggle()
		return "ok console " + ("open" if console.open else "close")
	if action == "say":
		console.submit(" ".join(parts.slice(2)), console.dispatch)
		return "ok console say"
	var reported := []
	for line in console.lines:
		reported.append(String(line["kind"]) + ": " + String(line["text"]))
	return "ok " + json_of({
		"open": console.open,
		"input": console.input_text,
		"caret": console.caret,
		"history": console.history,
		"lines": reported,
	})

## `connect <ticket> [name] [--pull]`: join a session the ticket names, asking for a username in
## the console when the line does not carry one -- which is what a ticket's length makes worth
## having. A `--pull`-style flag is skipped anywhere after the verb, as `netJoinArgs` allows, and
## whether that one was seen is the *per-join* consent the bridge joins with its own standing
## `GOATS_PULL` (M18d). The username prompt carries it through, so `connect T --pull` still fetches
## after the name is typed -- `net.js`'s own re-composition in `sceneCommand`.
func _connect(parts: PackedStringArray) -> String:
	if _in_session():
		return "error already in a session (leave first)"
	var args := PackedStringArray()
	var pull := false
	for i in range(1, parts.size()):
		if parts[i] == PULL_FLAG:
			pull = true
			continue
		if not parts[i].begins_with("-"):
			args.append(parts[i])
	if args.is_empty():
		return "error connect expects a ticket"
	var ticket: String = args[0]
	if args.size() < 2:
		var action := func(answer: String) -> String:
			return String(_call("cmd_join", [ticket, answer.strip_edges(), pull]))
		console.ask("Username?", action)
		return "ok name?"
	return String(_call("cmd_join", [ticket, args[1], pull]))

## `leave`: end the session.
func _leave() -> String:
	if not _in_session():
		return "error not in a session"
	_call("cmd_leave")
	return "ok leave"

## `host [name]`: serve a session, and be the side that owns the world (`ctl.js`'s `netHost`).
## The name is optional and only a request: the server answers with the canonical one on the
## `hosting` event. The ticket to hand out arrives on the `ticket` event, and `copy` takes it.
##
## The reply is this verb's own rather than the `cmd_*` call's, the way `_leave`'s is: the two
## refusals (`already in a session`) are the `_in_session` guard above, so there is nothing left
## for the call to report.
func _host(parts: PackedStringArray) -> String:
	if _in_session():
		return "error already in a session (leave first)"
	var name: String = parts[1] if parts.size() > 1 else ""
	_call("cmd_host", [name])
	return "ok host"

## `mod [list|key|info]`: the metadata table the host found, the world-mod digest key a join
## handshake compares, and one mod's own entry (`ctl.js`'s `modCommand`).
##
## `info` adds what the table cannot carry: a *compiled* mod's module report, straight from the host
## that instantiated it (`crates/plugin`'s `describe_json`: the ABI, the imports, the frame count,
## the last log line). That is `mods.js`'s `modWasmInfo`, and it is the only place a player can see
## what a `.wasm` module made of itself. The scene's `commands` list is the one part of the
## reference's reply that is *not* here: the registered verbs live in the JavaScript facade, and the
## port has no reader for that registry yet.
##
## `enable` and `disable` are the other half (`modSetEnabled`, `mods.js`'s own): they go through
## `Mods.set_enabled`, which guards a world mod against a mid-session change and re-reads the table,
## and the host does the teardown and the re-run. `reload` is the same path (`Mods.reload_mod`),
## which is what the host does for an enable of a mod that is already loaded.
func _mod(parts: PackedStringArray) -> String:
	if mods == null:
		return "error mod unavailable"
	var verb: String = parts[1] if parts.size() > 1 else "list"
	if verb == "" or verb == "list":
		return "ok " + json_of(mods.mod_table())
	if verb == "key":
		var world: Array = []
		for meta: Dictionary in mods.mod_table():
			if String(meta.get("side", "")) != "world":
				continue
			world.append("%s@%s#%s" % [String(meta.get("id", "")), String(meta.get("version", "")),
				String(meta.get("hash", ""))])
		world.sort()
		return "ok " + json_of(world)
	if verb == "info":
		var id: String = parts[2] if parts.size() > 2 else ""
		if id == "":
			return "error mod info expects an id"
		var row: Variant = null
		for meta: Dictionary in mods.mod_table():
			if String(meta.get("id", "")) == id:
				row = meta
		if row == null:
			return "error unknown mod: " + id
		var info: Dictionary = (row as Dictionary).duplicate()
		info["wasm"] = _wasm_info(id)
		return "ok " + json_of(info)
	if verb == "enable" or verb == "disable":
		if parts.size() < 3:
			return "error mod " + verb + " expects an id"
		return mods.set_enabled(parts[2], verb == "enable")
	if verb == "reload":
		if parts.size() < 3:
			return "error mod reload expects an id"
		return mods.reload_mod(parts[2])
	return "error mod expects list|info|key|enable|disable|reload"

## A compiled mod's own report, or `null`. The host answers the string `"null"` for a mod with no
## module rather than an empty reply, so the two answers parse the same way and there is one path.
func _wasm_info(id: String) -> Variant:
	if mods == null or mods.host == null:
		return null
	return JSON.parse_string(String(mods.host.call("wasm_describe", id)))

## `copy [text]`: with no argument, the ticket -- the one thing long enough that it should
## never have to be typed. The clipboard is Godot's own, and `console.gd` says whether it
## took.
func _copy(parts: PackedStringArray) -> String:
	var text: String = " ".join(parts.slice(1)) if parts.size() > 1 else String(_call("cmd_ticket"))
	if text == "":
		return "error nothing to copy"
	return "ok copy" if console.copy(text) else "error clipboard unavailable"

## `say`: a chat line. The empty reply is the scene's own -- "nothing to report" -- because
## the server relays a line back to its own sender, so the console prints the `net` echo
## rather than a second `ok` after every message.
func _say(text: String) -> String:
	if not _in_session():
		return "error not in a session"
	var line: String = text.strip_edges()
	if line == "":
		return "error nothing to say"
	_call("cmd_say", [line])
	return ""

## `grass [range]`: the nearest standing tuft, its distance, and whether it is in reach.
func _grass(parts: PackedStringArray) -> String:
	var range: Variant = ctl_arg(parts, 1)
	var reach: float = float(range) if range != null else 60.0
	var t: Dictionary = meadow.nearest(goat.px, goat.pz, reach)
	if t.is_empty():
		return "ok null"
	var d2: float = float(t["d2"])
	return "ok " + json_of({
		"x": ctl_round(float(t["x"])),
		"z": ctl_round(float(t["z"])),
		"dist": ctl_round(sqrt(d2)),
		"inReach": d2 <= Meadow.EAT_RANGE * Meadow.EAT_RANGE,
		"key": Meadow.key(int(t["cx"]), int(t["cz"])),
	})

## `traps [range]`: the devices around the goat, their distance, and whether the device
## moved there rather than being part of the field's derivation. `sceneTraps`, transcribed:
## a mine is judged at its cell's centre, a trapped tuft at the tuft itself, which is the
## half-metre the scene's own comment is about.
func _traps(parts: PackedStringArray) -> String:
	var range: Variant = ctl_arg(parts, 1)
	var reach: float = float(range) if range != null else 30.0
	# The derivation is `Explosions.traps_near`'s, and deliberately the *same* function a mod reaches
	# through `goats.explosions.traps` (`APIv1.md` section 4.15): a mine detector a mod writes and
	# the console's own verb would otherwise be two transcriptions of `sceneTraps`, and the one that
	# drifted would be the one nobody happened to look at. Only the rounding is this verb's, because
	# a console line is prose and a mod's numbers are not.
	var near: Dictionary = explosions.traps_near(goat.px, goat.pz, reach)
	var mines: Array = []
	for mine: Dictionary in near["mines"]:
		mines.append({
			"x": mine["x"], "z": mine["z"], "key": mine["key"],
			"dist": ctl_round(mine["dist"]), "moved": mine["moved"],
		})
	var traps: Array = []
	for trap: Dictionary in near["traps"]:
		traps.append({
			"x": ctl_round(trap["x"]), "z": ctl_round(trap["z"]), "key": trap["key"],
			"dist": ctl_round(trap["dist"]), "moved": trap["moved"],
		})
	return "ok " + json_of({
		"range": reach,
		"mines": mines,
		"traps": traps,
		"spent": explosions.spent.size() + explosions.trap_spent.size(),
		"moved": explosions.moved.size() + explosions.trap_moved.size(),
		"pending": explosions.pending.size(),
	})

## `craters [range]`: the holes the ground is carrying, where and how deep right now and how
## far through the heal. `sceneCraters`, filtered to the range like the scene's own.
func _craters(parts: PackedStringArray) -> String:
	var range: Variant = ctl_arg(parts, 1)
	var reach: float = float(range) if range != null else 30.0
	var range2: float = reach * reach
	var near: Array = []
	for crater: Dictionary in Craters.list:
		var dx: float = float(crater["x"]) - goat.px
		var dz: float = float(crater["z"]) - goat.pz
		var d2: float = dx * dx + dz * dz
		if d2 > range2:
			continue
		near.append({
			"x": ctl_round(float(crater["x"])),
			"z": ctl_round(float(crater["z"])),
			"r": ctl_round(float(crater["r"])),
			"depth": ctl_round(float(crater["dip"])),
			"age": ctl_round(float(crater["age"])),
			"heal": ctl_round(float(crater["heal"])),
			"dist": ctl_round(sqrt(d2)),
		})
	return "ok " + json_of({"range": reach, "craters": near, "live": Craters.list.size()})

## `water [on|off]`: the whole system's bisect, or the table's own read-out.
func _water(parts: PackedStringArray) -> String:
	var arg: String = parts[1] if parts.size() > 1 else ""
	if arg == "on" or arg == "off":
		var on: bool = arg == "on"
		water.enabled = on
		water.update()
		return "ok water " + ("on" if on else "off")
	return "ok " + json_of(water.state(goat.px, goat.pz))

## `flood [level|off|rain]`: force the table's level, or hand it back to the weather. The
## same shape as `C` forcing the weather cycle.
func _flood(parts: PackedStringArray) -> String:
	var arg: String = parts[1] if parts.size() > 1 else ""
	if arg == "" or arg == "off" or arg == "rain":
		water.force_off()
		return "ok flood off"
	var level: Variant = ctl_arg(parts, 1)
	if level == null:
		return "error flood: expects a number or 'off'"
	water.set_force(float(level))
	return "ok flood " + num(ctl_round(float(level)))

## Whether the window is fullscreen, which is a `DisplayServer` question in Godot and a
## binding question in the scene.
func _is_fullscreen() -> bool:
	return DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN

## The session's state as `netStatus()`: the mode, this player's name, the ticket, and the
## roster. The frame tracks all four from the bridge's events.
func _net_status() -> Dictionary:
	var status: Variant = _call("cmd_net_status")
	if status is Dictionary:
		return status
	return {"mode": "off", "name": "", "ticket": "", "roster": []}

## Whether the frame is in a session at all, which is `netInSession()`.
func _in_session() -> bool:
	return String(_net_status().get("mode", "off")) != "off"

## `swarm [join [--topic ID] [--peer ID|TICKET]... | leave]`: the gossip topic hosts
## advertise on (`ctl.js`'s `swarm`). With no verb it reports the topic, the direct
## neighbours and how many hosts were found, which is `netSwarmStatus()`.
func _swarm(parts: PackedStringArray) -> String:
	var verb: String = parts[1] if parts.size() > 1 else ""
	if verb == "":
		var status: Variant = _call("cmd_swarm_status")
		if status is Dictionary:
			return "ok " + json_of(status)
		return "ok " + json_of({"topic": "", "peers": 0, "hosts": 0})
	if verb == "join":
		var topic := ""
		var peers := PackedStringArray()
		var i: int = 2
		while i < parts.size():
			if parts[i] == "--topic" and i + 1 < parts.size():
				topic = parts[i + 1]
				i += 2
			elif parts[i] == "--peer" and i + 1 < parts.size():
				peers.append(parts[i + 1])
				i += 2
			else:
				return "error swarm join expects --topic ID or --peer ID"
		return String(_call("cmd_swarm_join", [topic, ",".join(peers)]))
	if verb == "leave":
		return String(_call("cmd_swarm_leave"))
	return "error swarm expects join|leave"

## Whether the frame is a *client* in a session, which is what decides whether the herd is
## the scene's own or the host's mirror -- `main.gd`'s `_joined`.
func _joined_scene() -> bool:
	return bool(_call("cmd_is_client"))

## One of the frame's own `cmd_*` methods, by name. A missing frame or a missing method is
## `null`, so a gate that holds only the pure rules never has to build one.
func _call(name: String, args: Array = []) -> Variant:
	if scene == null:
		return null
	return scene.callv(name, args)
