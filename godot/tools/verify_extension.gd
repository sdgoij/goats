# Load test for the GDExtension: proves Godot loaded the Rust library from
# `crates/godot`, registered the generated classes, and can call into them.
#
#   Godot --headless --path godot --script res://tools/verify_extension.gd
#
# A non-zero exit makes it usable as a gate. It is the companion to
# `verify_model.gd`, and like it, it is a SceneTree script so it needs no scene.
extends SceneTree

# Every class `crates/godot` registers. A stub library would have none of them,
# so their presence *is* the load proof.
const CLASSES := ["ModHost", "NetBridge"]

func _initialize() -> void:
	var failures: Array[String] = []

	for name in CLASSES:
		if not ClassDB.class_exists(name):
			print("FAIL: %s is not registered - the GDExtension did not load" % name)
			print("      (is the library present under res://addons/goats_godot/bin/?)")
			quit(1)
			return
		print("class registered: %-10s extends Node: %s"
			% [name, ClassDB.is_parent_class(name, "Node")])

	# A call only native code can answer: the JavaScript engine evaluates it.
	var mods: Object = ClassDB.instantiate("ModHost")
	var evaluated: String = mods.call("eval_js", "1 + 1")
	print("ModHost.eval_js(\"1 + 1\") -> ", evaluated)
	if evaluated != "ok":
		failures.append("ModHost.eval_js did not answer: " + evaluated)
	mods.free()

	# The bridge answers before it has a session: its event queue is empty.
	var net: Object = ClassDB.instantiate("NetBridge")
	var events: PackedStringArray = net.call("poll_events")
	print("NetBridge.poll_events() -> ", events.size(), " event(s)")
	if events.size() != 0:
		failures.append("a fresh NetBridge should have no events")
	net.free()

	if failures.is_empty():
		print("OK: the GDExtension loads and answers from Rust")
		quit(0)
	else:
		for f in failures:
			print("FAIL: ", f)
		quit(1)
