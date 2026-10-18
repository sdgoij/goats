# The swarm's hosts, and a session's way out: `net.js`'s `PORTALS`, drawn the Godot way.
#
# A host found on the gossip topic is a ring a player can walk into. The position is
# **derived from the ticket**, not assigned by a server, so every client computes the
# same place for the same host and the swarm never has to hand out coordinates. That
# derivation is FNV-1a, written out below rather than taken from `hash()`: the two
# clients have to agree, and Godot's own hash is a different function.
#
# In a session as a *client* the host rings go dark (a session refuses a second join)
# and one amber ring stands ten metres from the spawn: walking into it leaves the
# session. A host has no exit ring -- ending its own session from the meadow would
# disconnect everyone else without a word.
#
# The rings are two `MultiMesh`es of small spheres -- a wide faint haze and a bright
# bead inside it -- because `drawSphereEx` is the only curve the reference scene has, and
# a ring there is a string of them. One pulse drives both, so two rings in view breathe
# together rather than each keeping its own clock.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name Portals
extends Node3D

## Rings drawn: the nearest, so a long swarm list stays cheap.
const DRAWN := 8
## Beads in a ring.
const SEGMENTS := 24
## Ring radius, metres.
const RADIUS := 1.25
## Ring centre above the ground, metres.
const MIDDLE := 1.45
## How close the goat has to be to fall in, metres.
const REACH := 1.6
## The haze bead's radius and the bright one inside it, metres.
const HAZE_SIZE := 0.26
const GLOW_SIZE := 0.11

## The way out of a session: ten metres from the spawn, on the +z side. Deliberately
## not ticket-derived -- this is a local door, not a shared place.
const EXIT_X := 0.0
const EXIT_Z := 10.0

## The hosts the swarm last reported, as the `discovered` event carried them:
## `{ticket, name, clients, protocol}`. `main.gd` keeps this in step with its events.
var hosts: Array = []

## Called with a ticket when the goat walks into that host's ring. `main.gd` wires this to
## its own join so a portal and the console's `connect` are the same act.
var join: Callable

## Called when the goat walks into the amber ring in a session (`main.gd` wires it to
## `cmd_leave`). One Callable rather than a flag, for the same reason as `join`.
var leave: Callable

## The ticket whose ring the goat is standing in. A failed join must not be retried every
## frame: the goat has to step out and back in, which is also what makes a second try
## deliberate rather than a loop.
var _inside := ""
## The same rule for the exit, plus whether the last frame was already a client: joining
## while standing in the exit ring must not leave at once.
var _exit_inside := false
var _was_client := false

var _haze: MultiMesh
var _glow: MultiMesh
var _haze_material: StandardMaterial3D
var _glow_material: StandardMaterial3D

func _ready() -> void:
	_build()

## Build the two `MultiMesh`es, once. Called from `_ready` and from `update`, because a
## `SceneTree` script that adds the node during `_initialize` never sees `_ready` -- the
## same reason `water_splash.gd` builds inside its own `update`.
func _build() -> void:
	if _haze != null:
		return
	_haze_material = _material(Color(90.0 / 255.0, 220.0 / 255.0, 255.0 / 255.0, 0.14))
	_glow_material = _material(Color(170.0 / 255.0, 250.0 / 255.0, 255.0 / 255.0, 0.9))
	_haze = _multimesh(HAZE_SIZE, 6, _haze_material)
	_glow = _multimesh(GLOW_SIZE, 6, _glow_material)
	_add_layer(_haze)
	_add_layer(_glow)

## One MultiMesh of `count` beads. `radial_segments` 6 is `drawSphereEx`'s own resolution:
## a bead is a few pixels across, so more is invisible.
func _multimesh(radius: float, segments: int, material: Material) -> MultiMesh:
	var mesh := MultiMesh.new()
	mesh.transform_format = MultiMesh.TRANSFORM_3D
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = segments
	sphere.rings = 4
	sphere.material = material
	mesh.mesh = sphere
	mesh.instance_count = DRAWN * SEGMENTS
	# A ring is a light, not a surface: the automatic bounds over that many instances at
	# the origin would be a lie the moment a host lands anywhere else.
	mesh.custom_aabb = AABB(Vector3(-512.0, -32.0, -512.0), Vector3(1024.0, 128.0, 1024.0))
	return mesh

## The scene colours are immediate-mode ones, so the beads are unshaded; additive blending
## is what makes two dozen overlaps read as a glow rather than as a string of balls.
func _material(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.albedo_color = colour
	return material

func _add_layer(mesh: MultiMesh) -> void:
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)

## FNV-1a, 32 bits, matching `PORTALS`' `hash` in the scene exactly. The two clients must
## place the same ring for the same ticket, so this cannot be Godot's `hash()`.
static func ticket_hash(text: String) -> int:
	var value: int = 2166136261
	for i in text.length():
		value = value ^ text.unicode_at(i)
		value = (value * 16777619) & 0xFFFFFFFF
	return value

## Where a host's ring stands. The angle and the radius come from two draws off the same
## hash, and the ring's horizontal diameter runs along the tangent -- its face toward the
## middle of the field a player walks out from.
static func placement(ticket: String) -> Dictionary:
	var angle: float = (float(ticket_hash(ticket)) / 4294967296.0) * PI * 2.0
	var spread: float = float(ticket_hash(ticket + "#radius") % 1000) / 1000.0
	var radius: float = 20.0 + spread * 10.0
	return {
		"x": cos(angle) * radius,
		"z": sin(angle) * radius,
		"tangentX": -sin(angle),
		"tangentZ": cos(angle),
	}

## The nearest few hosts, in distance order. A swarm may list hundreds; the meadow only
## has to show the ones a player could walk to.
static func nearest(hosts: Array, px: float, pz: float) -> Array:
	var list: Array = []
	for host: Variant in hosts:
		if not (host is Dictionary):
			continue
		var place: Dictionary = placement(String(host.get("ticket", "")))
		var dx: float = float(place["x"]) - px
		var dz: float = float(place["z"]) - pz
		list.append({"host": host, "place": place, "d2": dx * dx + dz * dz})
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["d2"]) < float(b["d2"]))
	return list.slice(0, DRAWN)

## The exit's own place, for the labels and the walk-in check. It is a constant, but one
## name rather than two keeps the two users from disagreeing.
static func exit_place() -> Dictionary:
	return {"x": EXIT_X, "z": EXIT_Z, "tangentX": 1.0, "tangentZ": 0.0}

## Rebuild this frame's beads and pulse them. `client` picks which rings exist: the amber
## exit while in a session as a client, the discovered hosts otherwise. `main.gd` hides the
## node when neither applies.
func update(px: float, pz: float, client: bool) -> void:
	_build()
	var pulse: float = 0.75 + 0.25 * sin(Engine.get_process_frames() * 0.05)
	var haze_alpha: float = (30.0 + 26.0 * pulse) / 255.0
	var glow_alpha: float = (190.0 + 55.0 * pulse) / 255.0
	var index: int = 0
	if client:
		# Amber, not the hosts' cyan: this ring is a door, not a destination.
		_haze_material.albedo_color = Color(255.0 / 255.0, 170.0 / 255.0, 70.0 / 255.0, haze_alpha)
		_glow_material.albedo_color = Color(255.0 / 255.0, 228.0 / 255.0, 160.0 / 255.0, glow_alpha)
		index = _place_ring(exit_place(), index)
	else:
		_haze_material.albedo_color = Color(90.0 / 255.0, 220.0 / 255.0, 255.0 / 255.0, haze_alpha)
		_glow_material.albedo_color = Color(170.0 / 255.0, 250.0 / 255.0, 255.0 / 255.0, glow_alpha)
		for entry: Dictionary in nearest(hosts, px, pz):
			index = _place_ring(entry["place"], index)
	_haze.visible_instance_count = index
	_glow.visible_instance_count = index

## Place one ring's beads at `index` and return the next free slot.
func _place_ring(place: Dictionary, index: int) -> int:
	var base: float = Terrain.height_at(float(place["x"]), float(place["z"]))
	for j in SEGMENTS:
		var t: float = (float(j) / float(SEGMENTS)) * PI * 2.0
		var along: float = cos(t) * RADIUS
		var up: float = sin(t) * RADIUS
		var bead := Vector3(
			float(place["x"]) + float(place["tangentX"]) * along,
			base + MIDDLE + up,
			float(place["z"]) + float(place["tangentZ"]) * along)
		var transform := Transform3D(Basis(), bead)
		_haze.set_instance_transform(index, transform)
		_glow.set_instance_transform(index, transform)
		index += 1
	return index

## Walking into a ring joins that host; walking into the amber ring in a session leaves
## it. `in_session` is either side of a session, `client` is the joining side (a host has
## no exit), and `menu_open`/`dead` are the scene's own gates. The ring the goat is
## standing in is remembered, so a refused join waits for it to step out -- and the exit
## uses the same rule, so joining while standing in it does not leave instantly.
func step(px: float, pz: float, in_session: bool, client: bool, menu_open: bool, dead: bool) -> void:
	if menu_open or dead:
		return
	if client:
		var ex: float = EXIT_X - px
		var ez: float = EXIT_Z - pz
		var near: bool = ex * ex + ez * ez <= REACH * REACH
		if not _was_client:
			_was_client = true
			_exit_inside = near
			return
		if not near:
			_exit_inside = false
			return
		if _exit_inside:
			return
		_exit_inside = true
		if leave.is_valid():
			leave.call()
		return
	_was_client = false
	_exit_inside = false
	if in_session:
		return
	var found := ""
	for host: Variant in hosts:
		if not (host is Dictionary):
			continue
		var ticket: String = String(host.get("ticket", ""))
		var place: Dictionary = placement(ticket)
		var dx: float = float(place["x"]) - px
		var dz: float = float(place["z"]) - pz
		if dx * dx + dz * dz <= REACH * REACH:
			found = ticket
			break
	if found == "":
		_inside = ""
		return
	if _inside == found:
		return
	_inside = found
	# No `--pull`: fetching a host's mods installs code, and that is consent the player
	# gives with the console, not something a ring can assume.
	if join.is_valid():
		join.call(found)
