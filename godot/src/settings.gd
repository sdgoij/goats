# The settings (M25): `core.js`'s `SETTINGS`, as one object the console, the menu and the HUD all
# read.
#
# The scene keeps `SETTINGS` in the first part of `core.js` for one reason: *every* later part
# reads it. The menu's screen edits it, `ctl.js`'s `setting` verb writes it, `drawHud` reads two
# of its words back, and `applySettings` -- which lives in `menu.js` -- pushes the whole thing
# into the systems that own the behaviour. A `Settings` object is the same shape, and the reason
# it is an object rather than a handful of fields on the frame is that two owners is how they
# drift: the console saying `cloud high` while the menu still draws `medium` is a bug that only a
# shared value prevents.
#
# `bgm` and `sfx` are here as well as on `audio.gd`, which is `core.js`'s own split: `SETTINGS`
# holds the number a player sets and `applyAudioSettings` pushes it into the module that mixes.
# `Audio.bgm` is therefore the *applied* gain, and the only path to it is `push`.
#
# What a setting means is the scene's, not this object's -- so `apply` is a `Callable` the frame
# hands in, and this file never learns what `cloud high` costs.
#
# Two vocabularies differ from `ctl.js`'s on purpose, and both are the same rule the port has kept
# since stage 5: **a JavaScript fallback for a build without something Godot always has is not
# ported**. There is therefore no `planar` shadow -- that mode is the scene's fallback for a build
# with no shadow map, and Godot's shadow map is always there -- so the shadow vocabulary is two
# words where the scene's is three. `cloud` is the scene's three, because Godot's sky march really
# does have a step count to change.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name Settings
extends RefCounted

## The words the settings screen's combos walk and `setting` names. `SHADOW_NAMES` is the scene's
## `CTL_SHADOWS` less its `planar` (see the header); `CLOUD_NAMES` is `CTL_CLOUDS`.
const SHADOW_NAMES: Array[String] = ["off", "map"]
const CLOUD_NAMES: Array[String] = ["low", "medium", "high"]

## `SETTINGS`, with the scene's own defaults. `fullscreen` is `true` on desktop, so the port
## boots the way the client does; the browser is the exception, because a tab cannot enter
## fullscreen without a gesture, so it starts windowed and leaves the page's own control to the
## player. The screenshot and interop harnesses ask for a window explicitly -- `tools/screenshot.gd`
## clears the setting before the scene boots, because they size it with `--resolution`.
var bgm := 90.0
var sfx := 90.0
var light := true
var shadow := "map"
var sky := true
var cloud := "medium"
var fullscreen := not OS.has_feature("web")

## `applySettings`, handed in by the frame: everything a change has to reach. Called on every
## edit, which is the scene's own shape (`applySettings` runs once per changed control).
var apply: Callable = Callable()

## Push every setting where it belongs. The frame's `apply`, or nothing when there is no frame --
## a gate may hold the values without a scene.
func push() -> void:
	if apply.is_valid():
		apply.call()

## `ctlToggle`: `on`, `off`, or the current value flipped.
static func toggle_word(current: bool, arg: String) -> bool:
	if arg == "on":
		return true
	if arg == "off":
		return false
	return not current

## `drawHud`'s `lightingText`: `lit + shadow map`, `lit + planar shadow` or `lit`, a function of
## the shadow mode alone -- the scene reads it back off the same switch it just used. The planar
## word is kept because it is the scene's own text; the port has no leaf that can hold it.
static func lighting_word(shadow: String) -> String:
	if shadow == "map":
		return "lit + shadow map"
	if shadow == "planar":
		return "lit + planar shadow"
	return "lit"

## `drawHud`'s sky word: `shader` while the sky program runs and `billboards` otherwise.
static func sky_word_for(sky: bool) -> String:
	return "shader" if sky else "billboards"

## A word's index in a combo's table, or `-1` for one the scene does not know -- which `ctl.js`
## answers with an error.
static func index_of(names: Array[String], word: String) -> int:
	return names.find(word)
