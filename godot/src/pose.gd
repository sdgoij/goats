# The pose: how a fraction through a clip becomes the frame a goat is drawn at.
#
# `model.js` `poseModelOn` is one function the whole scene draws through -- the player's goat, the
# bots, the peers and the mirrored herd all end up in it -- and this is its transcription:
#
#     function poseModelOn(handle, info, phase) {
#         if (info === null || info === undefined || info.frames < 1) return false;
#         const last = info.frames - 1;
#         let frame = phase * last;
#         if (frame > last) frame = last;
#         rl.updateModelAnimation(handle, info.index, frame);
#         return true;
#     }
#
# Two things about it are the whole of the rule, and the port had both wrong while the line was
# inlined in four places. The phase is **clamped and never wrapped**: a phase of 1.0 is the clip's
# last frame, so a one-shot that has run out holds the pose it ended in -- and the one that shows it
# is the death, which lies there for `herd.deathLinger` seconds after its clip is over, so every
# corpse in the port stood back up a few seconds after it fell. And the clamp is **unconditional**,
# which is the loop's own far edge too: a loop phase of exactly 1.0 is the rounded 0.9996 the wire
# carries, which the scene poses at the clip's end rather than as a lap back to its beginning.
#
# "The clip's last frame" is one hair *short* of its length here, and that is the one place this
# differs from raylib. `AnimationPlayer.seek` treats a time at or past the end as *finished* and
# stops the player, and a stopped player poses nothing at all: the goat drops back to its rest pose,
# which is standing. `HELD` is that hair -- a tenth of a millisecond, so the frame under it is the
# last frame by any measure, and nowhere near the frame before it.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name Pose
extends RefCounted

## How far short of the clip's end the last frame is asked for. See the header: Godot *stops* a
## player sought to exactly its length, and a stopped player poses nothing.
const HELD := 0.0001

## Pose `anim` on `clip` at `phase`, a fraction through the clip -- the loop's own or a one-shot's,
## which does not matter here because the rule is the same for both: the reference's clamp is
## one-sided at the top, and a phase is never negative on either side of the wire (a one-shot's is
## clamped where it is made, a loop's is in `[0, 1)`).
##
## The caller owns *which* clip is playing (it is the one that knows a gait or a role changed);
## this owns where in it the goat stands. Answers `poseModelOn`'s own `false` when there is no clip
## to pose, so a caller can leave the goat as it was.
static func on(anim: AnimationPlayer, clip: String, phase: float) -> bool:
	if anim == null or clip.is_empty() or not anim.has_animation(clip):
		return false
	var animation: Animation = anim.get_animation(clip)
	var at: float = float(animation.length)
	var fraction: float = minf(clampf(phase, 0.0, 1.0), 1.0 - HELD)
	anim.seek(fraction * at, true)
	return true
