# Does a *Godot host* keep publishing a herd that moves while a joined client dies and respawns?
#
#   Godot --headless --path godot --script res://tools/verify_herd_host.gd
#
# The other half of `verify_herd_death.gd`, and the half a `goatsd` session cannot reach: `goatsd` is
# a Rust host, so a probe joined to it can only show that *this* end mirrors a herd that moves -- it
# can say nothing about whether this scene, hosting, keeps *publishing* one. The report this exists
# for is "the host's herd is frozen when a joined client's player dies and respawns", and a herd
# freezes on a client for exactly two reasons: the host stopped publishing, or the host published a
# herd that was standing still. This probe tells those apart.
#
#   * the publishing path is `_world_frame`, which `main.gd` stamps on every snapshot it sends, so
#     the frame count since it last moved *is* the host's outbound clock. A stall is a host that
#     stopped sending -- which freezes every client at once, and is invisible to `bots.report()`.
#   * the herd's own answer is `bots.report()`, which is what the snapshot carried.
#
# The death is the *client's*, so this end only learns of it the way it learns everything a peer
# does: the gait the session relays. Nothing here drives the joiner -- `interop.sh hostdeath` starts
# it with the ticket this probe prints, and reads both ends afterwards.
extends SceneTree

## How long the ticket is waited for before giving up on hosting at all, how long a join is waited
## for once it is printed, and how long the peer's own death is waited for once it has arrived. The
## joiner settles for three seconds and then kills itself, so that last one is that wait with room
## around it. Seconds.
const TICKET_WAIT := 30.0
const PEER_WAIT := 60.0
const DEATH_WAIT := 30.0
## How long the herd settles before the first sample, and how long it is watched after the peer gets
## up. Seconds.
const SETTLE := 3.0
const WATCH := 3.0
## The least the herd has to move for "the host is still publishing a herd that moves" to be true. A
## walking bot covers about a metre a second, so a tenth of a metre is far below any real motion and
## far above the easing's own noise -- the same bound `verify_herd_death.gd` uses.
const MOTION := 0.1
## The longest the publishing clock may stand still for before it is a stall rather than jitter.
## `main.gd` publishes every `WORLD_EVERY` (6) frames, so 90 frames is a second and a half of
## nothing: far past any throttle, and far short of a frozen world.
const STALL_FRAMES := 90

var _main: Node
var _frames := 0
var _timer := 0.0
var _phase := 0
var _peer := ""
var _before := {}
var _mid := {}
## The worst publishing gap seen since the peer settled, and where. Frames.
var _worst_gap := 0
var _worst_at := ""
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
	var bots: Node = _main.get("bots")
	var peers: Node = _main.get("peers")
	if bots == null or peers == null:
		_failures.append("the scene has no herd or no peer mirror")
		return _finish()
	# From the first sample onward the publishing clock is watched every frame: it is the one number
	# that separates "the host stopped sending" from "the host sent a herd that stood still".
	if _phase >= 3:
		_sample_gap()
	match _phase:
		0:
			print("host ->    ", _main.get("commands").call("run", "host herdhost"))
			_phase = 1
			_timer = 0.0
		1:
			# The ticket is what the shell hands the joiner, so it is printed *raw* on its own line
			# for `interop.sh` to pick up -- and only once, since a second copy would be a second
			# join.
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
			if int(peers.call("count")) == 0:
				if _timer > PEER_WAIT:
					_failures.append("no peer joined within %.0f s (was the join refused?)" % PEER_WAIT)
					return _finish()
				return false
			_peer = String((peers.call("names") as Array)[0])
			print("peer:      ", _peer, " joined; settling")
			_phase = 3
			_timer = 0.0
		3:
			if _timer < SETTLE:
				return false
			_before = _positions(bots)
			print("before:    ", _before.size(), " goat(s), ", _gap(), " frame(s) since the last snapshot")
			_phase = 4
			_timer = 0.0
		4:
			if _gait(peers) == "dead":
				_mid = _positions(bots)
				print("peer dead: ", _peer, " is dead; ", _mid.size(), " goat(s) sampled")
				_phase = 5
				_timer = 0.0
				return false
			if _timer > DEATH_WAIT:
				_failures.append("the peer never sent a dead gait within %.0f s" % DEATH_WAIT)
				return _finish()
			return false
		5:
			# The watch starts when the peer gets up, and the dead window is compared on its own:
			# the report was about the death and the respawn both, so a herd that stops for the one
			# and resumes for the other must not be averaged into one passing number.
			if _gait(peers) != "dead":
				print("peer up:   ", _peer, " got up; watching")
				_compare(_mid, _positions(bots), "while the peer's goat lay dead")
				_phase = 6
				_timer = 0.0
				return false
			if _timer > DEATH_WAIT:
				_failures.append("the peer stayed dead for longer than %.0f s" % DEATH_WAIT)
				return _finish()
			return false
		6:
			if _timer < WATCH:
				return false
			var after := _positions(bots)
			print("after:     ", after.size(), " goat(s), ", _gap(), " frame(s) since the last snapshot")
			_compare(_before, after, "across the peer's death and respawn")
			return _finish()
	return false

## The herd's own positions by index, which is what its snapshot carries. `bots.report()` has no
## index of its own -- a host's herd is an array in order, so the array *is* the index.
func _positions(bots: Node) -> Dictionary:
	var out := {}
	var at := 0
	for row: Dictionary in bots.call("report"):
		out[at] = Vector2(float(row.get("x", 0.0)), float(row.get("z", 0.0)))
		at += 1
	return out

## The gait a peer last sent, or "" for a peer this end has not seen a snapshot from.
func _gait(peers: Node) -> String:
	var report: Dictionary = peers.call("report_of", _peer)
	return String(report.get("gait", ""))

## Frames since the last world snapshot this host sent, which is its outbound clock. Read off
## `main.gd` rather than kept here because it is the *sending* half that is in question.
func _gap() -> int:
	return Engine.get_process_frames() - int(_main.get("_world_frame"))

## Take the publishing clock's worst reading so far. Only meaningful once a snapshot has been sent,
## which is why nothing samples it before the peer has arrived and settled.
func _sample_gap() -> void:
	var gap: int = _gap()
	if gap > _worst_gap:
		_worst_gap = gap
		_worst_at = "phase %d" % _phase

## What the herd did across one window, and whether that counts as moving.
func _compare(from: Dictionary, to: Dictionary, window: String) -> void:
	if from.is_empty() or to.is_empty():
		_failures.append("there was no herd to compare " + window)
		return
	var moved := 0
	var most := 0.0
	for index in from:
		if not to.has(index):
			continue
		var distance: float = (from[index] as Vector2).distance_to(to[index] as Vector2)
		most = maxf(most, distance)
		if distance > MOTION:
			moved += 1
	print("motion:    ", moved, " of ", from.size(), " goat(s) moved ", window,
		", most %.3f m" % most)
	if most <= MOTION:
		_failures.append("this host's herd did not move %s (most was %.3f m)" % [window, most])

func _finish() -> bool:
	print("publishing: worst gap ", _worst_gap, " frame(s) at ", _worst_at)
	if _failures.is_empty() and _worst_gap > STALL_FRAMES:
		_failures.append("this host stopped publishing for %d frames (%s)"
			% [_worst_gap, _worst_at])
	if _failures.is_empty():
		print("OK: this host keeps publishing a herd that moves through a peer's death and respawn")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true
