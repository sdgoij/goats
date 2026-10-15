# One client of a *pair*: joins the session `GOATSD_TICKET` names and holds it for a fixed
# window, reporting whether the other player's goat was ever there and whether it settled.
#
#   GOATSD_TICKET=<ticket> "Godot" --headless --path godot --script res://tools/verify_peers_live.gd
#
# `godot/tools/interop.sh pair` starts `goatsd` and two of these at once, which is the only way
# to prove the thing this exists for: a `peer` frame is what a client gets for *somebody else's*
# goat, so one client alone can never see one. Both ends publish their own goat (a joined scene
# does, `main.gd` `_publish_pose`), the server relays each to the other, and each end's mirror
# either places a goat or does not.
#
# **It holds the whole window rather than quitting on first sight, and that is not politeness.**
# A client that sees a peer and leaves at once takes its own pose with it, so the *other* end --
# which joined a moment later -- never gets one, and the pair tests one direction only. Both
# ends running the same wall-clock window is what makes each end's result a statement about the
# other's poses too.
#
# It runs the real scene (`scenes/herd.tscn`) rather than a bare bridge, because the point is the
# whole path: the bridge's `peer` event, `main.gd`'s dispatch, `peers.gd`'s placement and the
# clip it settles on. What it cannot check is what the goat *looks* like -- a picture's question,
# and the one this shares with every other slice.
extends SceneTree

## How long both ends hold the session, in seconds. Long enough for two processes to race the
## join handshake, exchange poses at 20 Hz and ease onto each other, and short enough that a
## failure is not a coffee break.
const WINDOW := 15.0

## How much of the window a peer has to have been there for. Not zero: a single frame of a peer
## is a handshake, and what this claims is a goat that *stayed*.
const HELD := 2.0

var _main: Node = null
var _started := 0
var _held := 0.0
var _seen := {}
var _frames := 0

func _initialize() -> void:
	if OS.get_environment("GOATSD_TICKET").is_empty():
		print("FAIL: GOATSD_TICKET is not set; a pair needs a session to meet in")
		quit(1)
		return
	var packed := load("res://scenes/herd.tscn") as PackedScene
	_main = packed.instantiate()
	root.add_child(_main)
	_started = Time.get_ticks_msec()

func _process(delta: float) -> bool:
	_frames += 1
	# `_initialize` has already said why if there is no scene here (no ticket, or a failed
	# load); a second line of complaint per frame would bury it.
	if _main == null:
		return true
	var peers: Object = _main.get("peers")
	if peers == null:
		print("FAIL: the scene has no peer mirror")
		quit(1)
		return true
	var seen: Array = peers.call("names")
	if not seen.is_empty():
		for name in seen:
			_seen[name] = true
		_held += delta
	var waited: float = float(Time.get_ticks_msec() - _started) / 1000.0
	if waited < WINDOW:
		return false

	print("peers seen: ", _seen.keys(), " held %.1f s of %.0f, %d frame(s)"
		% [_held, WINDOW, _frames])
	for line in peers.call("describe"):
		print(line)
	if _held < HELD:
		print("FAIL: no peer held the session for even %.1f s" % HELD)
		quit(1)
		return true
	print("OK: a Godot client mirrors the other player's goat, gap %.4f m"
		% float(peers.call("worst_gap")))
	quit(0)
	return true
