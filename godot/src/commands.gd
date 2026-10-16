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
#   * **`lighting`, `shadows`, `sky`, `setting light|shadow|sky`** -- the port's lighting,
#     shadows and sky are Godot's own materials and lights, not the scene's switchable lit
#     and sky programs. They arrive with the settings screen, which is the same stage; the
#     `cloud` setting *is* backed, because Godot's sky march has a step count to change.
#   * **`tune`** -- the tuning tree is the mod surface's (stage 8), and the port has
#     constants rather than a tree to walk.
#   * **`perf`** -- the frame-cost benchmark measures the JavaScript host's own phases;
#     there is no Godot harness behind it yet.
#   * **`mod`** -- the mod surface is stage 1/8; one of seventeen member groups is in.
#   * **`host`** -- a Godot client can join a session but not *host* one yet (the order-1
#     multiplayer gap). `connect`, `leave`, `who`, `net`, `say` and `msg` are backed.
#   * **`pools`** -- the water's connected regions are M20f, not yet ported.
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

## `CTL_SHADOWS` / `CTL_CLOUDS`, the word tables the `setting` and `shadows` verbs speak.
const SHADOW_WORDS: Array[String] = ["off", "planar", "map"]
const CLOUD_WORDS: Array[String] = ["low", "medium", "high"]

## The goat's stats ceiling, and the two camera clamps `ctl.js` reads from `TUNING`.
const STATS_MAX := 100.0
const CAM_PITCH_MIN := 0.08
const CAM_PITCH_MAX := 1.35
const CAM_DIST_MIN := 2.2
const CAM_DIST_MAX := 12.0

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
## The shell the `console` verb drives: it opens, closes, toggles and submits through it.
var console: Console
## The frame, for the `cmd_*` knobs. `null` in a gate that only holds the pure dispatch.
var scene: Node

## `ctl.js`'s `SETTINGS`, as far as the port has them. `bgm`/`sfx` live on `audio.gd`
## because that is what a change has to reach; `cloud` is `SkyDome`'s own step count. The
## three the port cannot honour are recorded here all the same, so `settings` reports the
## scene's shape -- and the verbs that would set them say they are unavailable rather than
## writing a value nothing reads.
var light := true
var shadow := "map"
var sky := true
var cloud := "medium"
var fullscreen := false

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

## `ctlToggle`: `on`, `off`, or the current value flipped. The third argument is how a bare
## `mute` and a bare `lighting` work.
static func ctl_toggle(current: bool, arg: String) -> bool:
	if arg == "on":
		return true
	if arg == "off":
		return false
	return not current

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

## `drawHud`'s `lightingText`: `lit + shadow map`, `lit + planar shadow` or `lit`, which is a
## function of the shadow mode alone -- the scene reads it back off the same switch it just
## used. The HUD's status line is where this lands.
static func lighting_word(shadow: String) -> String:
	if shadow == "map":
		return "lit + shadow map"
	if shadow == "planar":
		return "lit + planar shadow"
	return "lit"

## `drawHud`'s sky word: `shader` while the sky program runs and `billboards` otherwise.
static func sky_word_for(sky: bool) -> String:
	return "shader" if sky else "billboards"

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
				"lighting": light,
				"shadows": shadow,
				"sky": sky,
				"cloud": cloud,
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
			# A Godot client joins but cannot host yet -- the order-1 multiplayer gap.
			return "error host unavailable"
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
			goat.health = clampf(float(health), 0.0, STATS_MAX)
			return "ok health " + num(ctl_round(goat.health))
		"energy":
			var energy: Variant = ctl_arg(parts, 1)
			if energy == null:
				return "error energy expects a number"
			goat.energy = clampf(float(energy), 0.0, STATS_MAX)
			goat.exhausted = goat.energy <= 0.0
			return "ok energy " + num(ctl_round(goat.energy))
		"heal":
			goat.health = STATS_MAX
			goat.energy = STATS_MAX
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
			# The water's connected regions are M20f, not ported yet.
			return "error pools unavailable"
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
			# The port's lighting is Godot's own materials and lights, not the scene's
			# switchable lit program. It arrives with the settings screen.
			return "error lighting unavailable"
		"shadows":
			return "error shadows unavailable"
		"sky":
			return "error sky unavailable"
		"mute":
			var arg: String = parts[1] if parts.size() > 1 else ""
			audio.set_muted(ctl_toggle(audio.muted, arg))
			return "ok mute " + ("on" if audio.muted else "off")

		# ---- mods --------------------------------------------------------
		"mod":
			# The mod surface is stages 1 and 8: one of seventeen member groups is in.
			return "error mod unavailable"

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
			# A mod's registered command would get first refusal here (stage 8). What is left
			# is the console's chat: in a session, anything that is not a command is something
			# to say -- which is what makes the console a chat box. Offline it stays an error,
			# so a typo is still caught rather than broadcast.
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
	var out_pitch: float = clampf(deg_to_rad(float(pitch)), CAM_PITCH_MIN, CAM_PITCH_MAX)
	var out_dist: float = clampf(float(dist), CAM_DIST_MIN, CAM_DIST_MAX)
	_call("cmd_set_camera", [out_yaw, out_pitch, out_dist])
	return "ok camera %s %s %s" % [num(ctl_round(out_yaw)), num(ctl_round(out_pitch)),
		num(ctl_round(out_dist))]

## `settings`: the read-outs the settings screen will drive, at the values the scene has.
func _settings() -> Dictionary:
	return {
		"bgm": int(audio.bgm),
		"sfx": int(audio.sfx),
		"light": light,
		"shadow": shadow,
		"sky": sky,
		"cloud": cloud,
		"reflect": WaterReflect.tier_word(water_reflect.tier()),
		"fullscreen": _is_fullscreen(),
		"herd": bots.count() if bots != null else 0,
	}

## `setting <key> [value]`: the four keys the port can honour -- the two audio gains, the
## water's reflection and the herd's size -- plus `cloud`, which is Godot's sky march's step
## count. The three the port cannot honour (light, shadow, sky) say so rather than writing a
## value nothing reads; the words are in the header.
func _setting(parts: PackedStringArray) -> String:
	var key: String = parts[1] if parts.size() > 1 else ""
	match key:
		"bgm", "sfx":
			var gain: Variant = ctl_arg(parts, 2)
			if gain == null:
				return "error setting " + key + " expects a number"
			var level: float = clampf(roundf(float(gain)), 0.0, 100.0)
			if key == "bgm":
				audio.bgm = level
			else:
				audio.sfx = level
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
			var cloud_level: int = CLOUD_WORDS.find(cloud_word)
			if cloud_level < 0:
				return "error setting cloud expects low|medium|high"
			cloud = cloud_word
			SkyDome.cloud_level = cloud_level
		"light", "shadow", "sky":
			return "error setting " + key + " unavailable"
		_:
			return "error unknown setting: " + key
	return "ok setting " + key

## `ui`: the screen the frame is showing. Only `hud` is a screen the port draws yet -- the
## rest are the menu's, which is this same stage's other half -- so asking for one says so
## rather than freezing the world behind a panel that is not there.
func _ui(parts: PackedStringArray) -> String:
	if parts.size() == 1:
		return "ok " + String(_call("cmd_ui"))
	var screen: String = parts[1]
	if screen != "hud" and screen != "main" and screen != "settings" \
			and screen != "keymap" and screen != "mods":
		return "error ui expects hud|main|settings|keymap|mods"
	if screen != "hud":
		return "error ui " + screen + " is not drawn yet"
	_call("cmd_set_ui", [screen])
	return "ok ui hud"

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

## `connect <ticket> [name]`: join a session the ticket names, asking for a username in the
## console when the line does not carry one -- which is what a ticket's length makes worth
## having. A `--pull`-style flag is skipped anywhere after the verb, as `netJoinArgs` allows.
func _connect(parts: PackedStringArray) -> String:
	if _in_session():
		return "error already in a session (leave first)"
	var args := PackedStringArray()
	for i in range(1, parts.size()):
		if not parts[i].begins_with("-"):
			args.append(parts[i])
	if args.is_empty():
		return "error connect expects a ticket"
	var ticket: String = args[0]
	if args.size() < 2:
		var action := func(answer: String) -> String:
			return String(_call("cmd_join", [ticket, answer.strip_edges()]))
		console.ask("Username?", action)
		return "ok name?"
	return String(_call("cmd_join", [ticket, args[1]]))

## `leave`: end the session.
func _leave() -> String:
	if not _in_session():
		return "error not in a session"
	_call("cmd_leave")
	return "ok leave"

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
	var range2: float = reach * reach
	var r: int = int(ceil(reach / 2.0)) + 1
	var centre: Vector2i = Meadow.cell_at(goat.px, goat.pz)
	var mines: Array = []
	var traps: Array = []
	for cx in range(centre.x - r, centre.x + r + 1):
		for cz in range(centre.y - r, centre.y + r + 1):
			var key_value: int = Meadow.key(cx, cz)
			var mx: float = float(cx * 2 + 1)
			var mz: float = float(cz * 2 + 1)
			var dx: float = mx - goat.px
			var dz: float = mz - goat.pz
			if dx * dx + dz * dz <= range2 and explosions.mine_armed(cx, cz):
				mines.append({
					"x": mx, "z": mz, "key": key_value,
					"dist": ctl_round(sqrt(dx * dx + dz * dz)),
					"moved": explosions.moved.has(key_value),
				})
			if not explosions.trap_at(cx, cz):
				continue
			if meadow.eaten.has(key_value):
				continue
			var t: Dictionary = meadow.tuft_in(cx, cz)
			if t.is_empty():
				continue
			var tdx: float = float(t["x"]) - goat.px
			var tdz: float = float(t["z"]) - goat.pz
			if tdx * tdx + tdz * tdz > range2:
				continue
			traps.append({
				"x": ctl_round(float(t["x"])), "z": ctl_round(float(t["z"])), "key": key_value,
				"dist": ctl_round(sqrt(tdx * tdx + tdz * tdz)),
				"moved": explosions.trap_moved.has(key_value),
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
