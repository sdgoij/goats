# Does a **reference (JavaScript) client** join a session this scene *hosts*?
#
#   Godot --headless --path godot --script res://tools/verify_host_reference.gd
#
# Every other pairing in this suite is Godot with Godot (`interop.sh hostdeath`, this scene hosting)
# or Godot with `goatsd` (`join`, `refuse`, `pull`, `herd`, `pair`). None of them joins *this
# scene's own host* from the other implementation of the protocol, and that is the one place a
# handshake can break invisibly: a `PROTOCOL_VERSION` bump or a stale extension makes the reference
# client's ALPN never negotiate, so it simply never joins and no Godot-to-Godot mode goes red. This
# probe is the host half of that pairing -- it hosts the real scene and prints the ticket for
# `interop.sh jsjoin` to hand to the reference client, then reports whether a peer actually arrived
# and the herd it published while one was there.
#
# The joiner is a raylib app, so this mode needs a window like `interop.sh shot`; the probe itself
# is headless.
extends SceneTree

## How long the ticket is waited for before giving up on hosting at all, and how long a peer is
## waited for once it is printed. Seconds.
const TICKET_WAIT := 30.0
const PEER_WAIT := 60.0
## How long the host keeps serving after a peer arrives, so the reference client's own `net` read
## (its evidence that it *joined*) happens while this scene is still hosting. Seconds.
const HOLD := 12.0

var _main: Node
var _frames := 0
var _timer := 0.0
var _phase := 0
var _peer := ""
var _failures: Array[String] = []

func _initialize() -> void:
	var packed := load("res://scenes/herd.tscn") as PackedScene
	if packed == null:
		print("FAIL: could not load scenes/herd.tscn")
		quit(1)
		return
	_main = packed.instantiate()
	root.add_child(_main)

func _process(delta: float) -> bool:
	_frames += 1
	# `SceneTree.root` is not inside the tree while `_initialize` runs, so the scene is read a few
	# frames later -- the trap `verify_console.gd` names.
	if _frames < 6:
		return false
	_timer += delta
	match _phase:
		0:
			print("host ->    ", _main.get("commands").call("run", "host referencehost"))
			_phase = 1
			_timer = 0.0
		1:
			# The ticket is what the shell hands the reference client, so it is printed *raw* on a
			# line of its own for `interop.sh` to pick up -- and only once, since a second copy
			# would be a second join.
			var ticket: String = String(_main.get("_net_ticket"))
			if ticket.is_empty():
				if _timer > TICKET_WAIT:
					_failures.append("no ticket within %.0f s; this scene never hosted" % TICKET_WAIT)
					return _finish()
				return false
			print("ticket ", ticket)
			_phase = 2
			_timer = 0.0
		2:
			var peers: Node = _main.get("peers")
			if peers == null:
				_failures.append("the scene has no peer mirror")
				return _finish()
			if peers.call("count") == 0:
				if _timer > PEER_WAIT:
					_failures.append("no peer joined within %.0f s: was the join refused, or is the reference client's protocol version the one this extension speaks?" % PEER_WAIT)
					return _finish()
				return false
			_peer = String((peers.call("names") as Array)[0])
			print("peer:      ", _peer, " joined; holding")
			_phase = 3
			_timer = 0.0
			return false
		3:
			if _timer < HOLD:
				return false
			var bots: Node = _main.get("bots")
			var report: Array = bots.call("report") if bots != null else []
			print("herd:      ", report.size(), " goat(s) published while ", _peer, " was here")
			return _finish()
	return false

func _finish() -> bool:
	if _failures.is_empty():
		print("OK: this scene hosted and a reference client joined and mirrored it")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true
