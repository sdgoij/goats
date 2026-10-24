extends SceneTree

func _initialize() -> void:
	var node := TerrainMesh.new()
	root.add_child(node)
	# Warm up: the first build also makes the material and its 256 px texture.
	node.build(0.0, 0.0)
	var ax := 0.0
	var az := 0.0
	var t0: int = Time.get_ticks_usec()
	var n := 20
	for i in n:
		ax += 32.0
		node.build(ax, az)
	var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0 / float(n)
	print("incremental step (+32 in x): %.2f ms" % ms)

	# The same with a diagonal step, which exposes two strips and a corner.
	t0 = Time.get_ticks_usec()
	for i in n:
		ax += 32.0
		az += 32.0
		node.build(ax, az)
	ms = float(Time.get_ticks_usec() - t0) / 1000.0 / float(n)
	print("incremental step (+32,+32):  %.2f ms" % ms)

	# And a full resample, for the teleport/refresh path.
	var full_ms := 0.0
	for i in 3:
		node.refresh()
		t0 = Time.get_ticks_usec()
		node.refresh()
		full_ms += float(Time.get_ticks_usec() - t0) / 1000.0
	print("full resample (refresh):     %.2f ms" % (full_ms / 3.0))
	node.free()
	quit(0)
