// ---- lighting (M4): directional light and projected cast shadows ---------
//
// raylib's default shader is unlit, so the scene is lit by a small custom
// program. `DrawMesh` binds the material shader and ignores `beginShaderMode`, so
// `setModelShader` points the goat's materials at the lit program; the terrain
// (immediate-mode cubes) goes through `beginShaderMode`.
//
// Who deforms an animated mesh is the *engine's* choice, not the scene's: on the
// default build raylib deforms the goat's positions and normals on the CPU and
// uploads them, and a shader lit per-fragment works with no bone data at all. A
// `gpu-skinning` build leaves the deform to the material's shader instead, which
// is why each of the three vertex shader families below exists twice -- see "GPU
// skinning" under the lit programs.
//
// Shadows are a planar projection rather than a shadow map: the goat is drawn a
// second time with a vertex shader that squashes every vertex onto the ground
// along the light direction, filled with a translucent dark colour. On the flat
// terrain this reads as a cast shadow that tracks the sun, with none of the
// bias/acne tuning a depth map needs. A depth-map pass (soft edges, self-shadowing)
// can replace it once the render-texture bindings are wired up.

const GROUND_Y = 0.02;          // plane the planar shadow projects onto, plus
                                // the terrain height under the goat
const SHADOW_ALPHA = 0.34;      // base opacity of the cast shadow

const LIGHT_DIR = [0.4, 0.8, 0.12];   // unit vector pointing at the active body
// The sun's own direction. The two celestial bodies sit at opposite ends of one
// line (`drawCelestial`), so the moon's direction is the negation of this one, and
// the scene's light is whichever of them is up. It is kept separate from
// `LIGHT_DIR` because the *moon's phase* is set by the sun even at night, when the
// scene's light has already flipped to the moon.
const SUN_DIR = [0.4, 0.8, 0.12];
const LIGHT_COLOR = [0.9, 0.9, 0.9];  // rgb, already scaled by intensity
const LIGHT_AMBIENT = [0.2, 0.22, 0.3];

let litShader = -1;
let shadowShader = -1;
let celestialShader = -1;
let celestialUniforms = null;   // the sun's direction, and the camera position
// The water surface's own program (M20b). It is a *sibling* of the lit one rather
// than a member of its skinned family, so `setLitUniforms` and `makeShadowMap`
// reach it explicitly -- `litPrograms`' first two entries are the plain/skinned
// pair by construction, and a third would break that.
let waterShader = -1;
let waterProgram = null;
let waterUniforms = null;       // water.js's own level and colours
let useLighting = true;         // toggled with L
let lightingText = "cube shader";

// ---- GPU skinning (the engine's `gpu-skinning` build) ---------------------
//
// A `gpu-skinning` build loads an animated mesh without its deform buffers, so
// `updateModelAnimation` no longer deforms anything: it fills the bone matrices
// and the *material's shader* has to skin. `rl.GPU_SKINNING` reports which way
// the engine was built (it is a raylib build switch, not a setting), and the
// mechanism is written up in `slag/.notes/gpu-skinning.md`.
//
// Each of the three vertex shader families is therefore compiled twice. The plain
// program is not merely the other build's path: it is the one the grass
// (immediate mode) and the terrain mesh must keep drawing through, because
// neither carries bone data, and a skinned program reads whatever the generic
// attributes hold -- indices 0, weights 1 -- and would deform them by a bone
// matrix left over from the last model drawn.
//
// So: one routing call per animated model as it loads (`modelLoaded`), the
// skinned counterpart of the wanted program at every `setModelShader`
// (`modelShaderFor`, which passes a model that had to keep CPU skinning straight
// through), and every per-frame uniform pushed to each program of the family --
// they are separate GL programs, so a value uploaded to one is invisible to the
// other.
//
// `-1` -- "the shader the model was loaded with", which is how `L` turns the
// lighting off -- has a counterpart too, because raylib's own default program does
// not skin either: `UNLIT_VS_SKIN` is that same unlit program with the bone block
// spliced in, so the `L` view keeps the herd animating on this build.
let gpuSkin = false;            // the loader left the deform buffers out
let skinnedOk = false;          // ...and every skinned program the scene needs compiled
let litShaderSkin = -1;
let shadowShaderSkin = -1;
let depthShaderSkin = -1;
let unlitShaderSkin = -1;
const plainModels = {};         // rigs the skinned programs cannot cover, by handle
let litPrograms = [];           // { shader, uniforms, shadow, sampler }
let shadowPrograms = [];        // { shader, uniforms }
let depthPrograms = [];         // { shader, lightVP }

// The blast light's current state, written by the explosion system
// (`setBlastLight`) and pushed to the shader every frame by `setLitUniforms`. The
// colour is the fireball's and is not per-blast: what varies is where it is and how
// bright, and a bang does not need a palette. Held as flat arrays so the per-frame
// push is array reads rather than property reads.
const BLAST_POS = [0, 0, 0, 0];   // x, y, z, energy
const BLAST_TINT = [1.0, 0.74, 0.45, 1.0];

function setBlastLight(x, y, z, energy) {
    BLAST_POS[0] = x;
    BLAST_POS[1] = y;
    BLAST_POS[2] = z;
    BLAST_POS[3] = energy;
}

// The bone inputs and the matrices `DrawModelEx` uploads. `boneMatrices` has to
// be spelled exactly that -- raylib looks the uniform up by name into
// `SHADER_LOC_MATRIX_BONETRANSFORMS` and feeds it `model.skeleton.boneCount`
// entries -- and the declared size is a ceiling `modelLoaded` checks a rig
// against: a count above it is `GL_INVALID_OPERATION` on the upload, which is not
// an error GL reports to us at draw time but every vertex of the mesh drawn
// through the zero matrix. The goat's rig is 15 bones; 32 mat4s is 512 of the
// 1024 vertex-uniform components GL 3.3 guarantees, which leaves room for the
// scene's own uniforms.
const BONE_MATRICES = 32;

// The inputs are raylib's own names, bound to fixed locations (7 and 8) before it
// links any program. The indices arrive as four *unnormalised* unsigned bytes
// widened to floats -- raylib sets the attribute up with `glVertexAttribPointer`,
// not `glVertexAttribIPointer` -- so they are read as `vec4` and cast with
// `int()`; an `ivec4` here reads garbage.
const SKIN_DECL = [
    "in vec4 vertexBoneIndices;",
    "in vec4 vertexBoneWeights;",
    "uniform mat4 boneMatrices[" + BONE_MATRICES + "];",
    "mat4 skinMatrix() {",
    "    return boneMatrices[int(vertexBoneIndices.x)] * vertexBoneWeights.x",
    "         + boneMatrices[int(vertexBoneIndices.y)] * vertexBoneWeights.y",
    "         + boneMatrices[int(vertexBoneIndices.z)] * vertexBoneWeights.z",
    "         + boneMatrices[int(vertexBoneIndices.w)] * vertexBoneWeights.w;",
    "}",
].join("\n");

// The plain variant's skin matrix is the identity, so the bodies below are one
// text for both programs: `matModel * skin * v` is `matModel * v` exactly as the
// scene drew it before -- a multiply by 1.0 is exact in IEEE 754 -- and only a
// skinned build pays for the weighted sum (the identity is a compile-time fold for
// the shader compiler, and even unfolded it is a few flops per vertex). Skinning
// happens in model space, which is why it lands between `matModel` and the vertex
// and leaves every transform the shader already applied untouched.
const PLAIN_SKIN = "mat4 skinMatrix() { return mat4(1.0); }";

// The lit program, in both builds. The normal is skinned by `mat3(skin)` rather
// than by an inverse transpose: the CPU pass uses
// `transpose(invert(boneMatrices[i]))`, and for a rigid bone matrix the 3x3 of
// that transpose-inverse *is* the 3x3 of the matrix, so the two agree exactly and
// the shading matches a CPU-skinning build. They diverge only if a bone's bind and
// current pose differ by a non-uniform scale; a uniform one cancels in
// `invert(bind) * current`.
const LIT_VS_HEAD = [
    "#version 330",
    "in vec3 vertexPosition;",
    "in vec2 vertexTexCoord;",
    "in vec3 vertexNormal;",
    "in vec4 vertexColor;",
];
const LIT_VS_MID = [
    "uniform mat4 mvp;",
    "uniform mat4 matModel;",
    "uniform mat4 matNormal;",
    "out vec2 fragTexCoord;",
    "out vec4 fragColor;",
    "out vec3 fragWorldPos;",
    "out vec3 fragNormal;",
];
const LIT_VS_BODY = [
    "void main() {",
    "    mat4 skin = skinMatrix();",
    "    vec4 world = matModel * skin * vec4(vertexPosition, 1.0);",
    "    fragWorldPos = world.xyz;",
    "    fragNormal = normalize(mat3(matNormal) * mat3(skin) * vertexNormal);",
    "    fragTexCoord = vertexTexCoord;",
    "    fragColor = vertexColor;",
    "    gl_Position = mvp * skin * vec4(vertexPosition, 1.0);",
    "}",
];
// One source, the variant spliced in: the two programs cannot drift.
function litVertex(skin) {
    return LIT_VS_HEAD.concat(skin ? SKIN_DECL : PLAIN_SKIN, LIT_VS_MID, LIT_VS_BODY).join("\n");
}
const LIT_VS = litVertex(false);
const LIT_VS_SKIN = litVertex(true);

const LIT_FS = [
    "#version 330",
    "in vec2 fragTexCoord;",
    "in vec4 fragColor;",
    "in vec3 fragWorldPos;",
    "in vec3 fragNormal;",
    "uniform sampler2D texture0;",
    "uniform sampler2D texture1;",
    "uniform vec4 colDiffuse;",
    "uniform vec3 lightDir;",
    "uniform vec4 lightColor;",
    "uniform vec4 ambientColor;",
    "uniform vec3 camPos;",
    "uniform mat4 lightVP;",
    "uniform vec2 shadowTexel;",
    "uniform float shadowBias;",
    "uniform float shadowStrength;",
    // The blast light (M19f): a point light the explosion system drives for a third
    // of a second after a bang. It is a uniform rather than a light in the engine
    // for the reason the sun is: every lit thing already shares this program, so
    // the ground, the goat, the herd and the grass are lit by it for free.
    "uniform vec3 blastPos;",
    "uniform vec4 blastColor;",
    "uniform float blastEnergy;",
    "out vec4 finalColor;",
    // Depth is packed across RGB so 8-bit channels give ~24-bit precision.
    "float unpackDepth(vec3 c) { return dot(c, vec3(1.0, 1.0/255.0, 1.0/65025.0)); }",
    "void main() {",
    "    vec4 texel = texture(texture0, fragTexCoord) * colDiffuse * fragColor;",
    "    vec3 n = normalize(fragNormal);",
    "    vec3 viewDir = normalize(camPos - fragWorldPos);",
    "    if (dot(n, viewDir) < 0.0) n = -n;",
    "    vec3 l = normalize(lightDir);",
    "    float ndl = max(dot(n, l), 0.0);",
    "    float hemi = 0.5 + 0.5 * n.y;",
    "    vec3 ambient = ambientColor.rgb * mix(0.55, 1.05, hemi);",
    "    float shadow = 1.0;",
    "    if (shadowStrength > 0.001) {",
    "        vec4 lclip = lightVP * vec4(fragWorldPos, 1.0);",
    "        vec3 ndc = lclip.xyz / lclip.w;",
    "        vec2 uv = ndc.xy * 0.5 + 0.5;",
    "        float ref = ndc.z * 0.5 + 0.5;",
    "        if (uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0 && ref < 1.0) {",
    "            float sum = 0.0;",
    "            for (int y = -1; y <= 1; y++) {",
    "                for (int x = -1; x <= 1; x++) {",
    "                    vec3 e = texture(texture1, uv + vec2(float(x), float(y))*shadowTexel).rgb;",
    "                    float d = 1.0 - unpackDepth(e);",
    "                    sum += (ref - shadowBias > d) ? 1.0 : 0.0;",
    "                }",
    "            }",
    "            shadow = 1.0 - (sum/9.0)*shadowStrength;",
    "        }",
    "    }",
    "    vec3 diffuse = lightColor.rgb * ndl * shadow;",
    "    vec3 halfV = normalize(l + viewDir);",
    "    float spec = pow(max(dot(n, halfV), 0.0), 24.0) * ndl * shadow * 0.18;",
    "    vec3 color = texel.rgb * (ambient + diffuse) + lightColor.rgb * spec;",
    // The bang's own light. The falloff's half-distance is ten metres, which is
    // about three blast radii -- near enough that standing at the rim still flashes
    // and far enough that a bang across the meadow only warms the grass. The
    // squared-off decay in `blastEnergy` is the scene's; this is the shape.
    "    if (blastEnergy > 0.001) {",
    "        vec3 bd = blastPos - fragWorldPos;",
    "        float bd2 = dot(bd, bd);",
    "        float blastAtt = blastEnergy * (1.0 / (1.0 + bd2 * 0.01));",
    // A point light instead of a directional one, so a wall of ground facing the
    // wrong way stays dark. The half-metre in the reciprocal keeps the normalise
    // finite for a fragment that is standing in the fireball.
    "        float blastNdl = max(dot(n, bd * inversesqrt(bd2 + 0.25)), 0.0);",
    "        color += texel.rgb * blastColor.rgb * (blastAtt * (0.35 + 0.65 * blastNdl));",
    "    }",
    "    finalColor = vec4(color, texel.a);",
    "}",
].join("\n");

// ---- the water surface (M20b) ---------------------------------------------
//
// The water is a `makeModel` mesh whose vertices carry the *ground* under them and,
// in the texcoord, the deepest water that vertex's basin can hold (`maxDepth`, from
// water.js's fill). The level is one uniform, so the surface is computed per vertex
// and the mesh is never rebuilt as the rain rises -- which is the whole reason the
// field is split the way it is: `F - terrain` is static between terrain rebuilds,
// and the level is not.
//
// The fragment is a *sibling* of `LIT_FS` rather than a second lighting model: the
// same sun, ambient, shadow map and blast light, so a pool sits in the scene rather
// than on it. What it adds is the water's own colour -- the surface takes the deep
// tint with depth -- and the shore, an alpha that fades to nothing as the water runs
// out, which is what keeps a pool from ending on a drawn line. The surface is flat
// here; waves, fresnel and reflections are M20c and M20e.
//
// The shadow and blast terms are *duplicated* from `LIT_FS` deliberately: the lit
// program is the scene's most load-bearing shader and there is no GLSL compiler in
// the harness, so the shared-snippet refactor -- the way `litVertex(skin)` shares the
// vertex -- waits until a real GPU can check both.
const WATER_VS = [
    "#version 330",
    "in vec3 vertexPosition;",     // (x, the ground's height, z)
    "uniform mat4 mvp;",
    "uniform float waterLevel;",
    "out vec3 fragWorldPos;",
    "out float fragDepth;",
    "void main() {",
    // The surface is the table itself, at every vertex: `depth` is how far the ground lies
    // under it and the vertex is lifted by exactly that, so the sheet is level over a whole
    // basin. It used to be capped by the basin's own spill -- which the mesh's texcoord
    // carried -- and that made the surface *not* level: it stopped climbing at a basin's rim
    // while the table over it went on rising, and a cell the flood lets drain out of the
    // grid's edge read dry with water standing over it.
    "    float ground = vertexPosition.y;",
    "    float depth = waterLevel - ground;",
    "    if (depth < 0.0) depth = 0.0;",
    "    fragDepth = depth;",
    // The surface is the ground plus the water standing on it: a level pool, because
    // `depth` is the same everywhere the ground is below the table.
    "    vec3 world = vec3(vertexPosition.x, ground + depth, vertexPosition.z);",
    "    fragWorldPos = world;",
    "    gl_Position = mvp * vec4(world, 1.0);",
    "}",
].join("\n");

const WATER_FS = [
    "#version 330",
    "in vec3 fragWorldPos;",
    "in float fragDepth;",
    "uniform vec3 lightDir;",
    "uniform vec4 lightColor;",
    "uniform vec4 ambientColor;",
    "uniform vec3 camPos;",
    "uniform mat4 lightVP;",
    "uniform vec2 shadowTexel;",
    "uniform float shadowBias;",
    "uniform float shadowStrength;",
    "uniform sampler2D texture1;",
    "uniform vec3 blastPos;",
    "uniform vec4 blastColor;",
    "uniform float blastEnergy;",
    "uniform vec4 waterShallow;",
    "uniform vec4 waterDeep;",
    "uniform float waterShore;",
    // The chop (M20c): the height field's own numbers, the wind that drives it, and the
    // clock it rides.
    "uniform float waterTime;",
    "uniform vec3 waterWave;",     // height, scale, speed
    "uniform vec3 waterWind;",     // the wind's direction (unit) and the gust's share
    "uniform float waterFresnel;",
    "uniform vec3 waterSky;",      // what a reflection sees, until M20e mirrors the world
    // The wake and the splashes (M20d). Three sources at once, named rather than an
    // array on purpose: `getShaderLocation` takes a name, and a fixed handful of
    // uniforms is a question the engine surface can already answer.
    "uniform vec4 waterRipple0;",  // (x, z, the front's radius in metres, strength)
    "uniform vec4 waterRipple1;",
    "uniform vec4 waterRipple2;",
    "out vec4 finalColor;",
    "float unpackDepth(vec3 c) { return dot(c, vec3(1.0, 1.0/255.0, 1.0/65025.0)); }",
    // One ripple's gradient: an expanding front with a damped wave train behind it, which
    // is what a hoof in water leaves. It is summed into the same gradient the chop uses,
    // so a ring tips the reflection and spreads the glitter exactly as a wave does -- and
    // its `strength` is already decayed by the emitter, which keeps the shader stateless
    // about time.
    "vec2 rippleGrad(vec2 p, vec4 r, float w) {",
    "    if (r.w <= 0.001) return vec2(0.0);",
    "    vec2 d = p - r.xy;",
    "    float dist = max(length(d), 1e-3);",
    "    return (d / dist) * (cos((dist - r.z) * w) * w * exp(-dist * 1.2) * r.w);",
    "}",
    // The wave height field, differentiated. It is not *displaced*: the water mesh is the
    // terrain's own 2 m grid and a wave is centimetres across, which no quad that size
    // can carry, so the surface is shaded by the normal the same height field would have
    // had -- evaluated per fragment, which is also what keeps a short wave from aliasing
    // across the grid. Two crossed directions, so the chop does not read as stripes, and
    // the amplitude falls away where the water is thin (a puddle does not chop).
    "vec3 waterNormal(vec2 p, float depth) {",
    "    float amp = waterWave.x * waterWind.z * clamp(depth / max(waterShore, 1e-4), 0.0, 1.0);",
    "    float k = 6.2831853 / max(waterWave.y, 0.05);",
    "    float t = waterTime * waterWave.z;",
    "    vec2 d1 = normalize(waterWind.xy + vec2(0.21, -0.13));",
    "    vec2 d2 = normalize(vec2(-waterWind.y, waterWind.x) + vec2(-0.17, 0.23));",
    "    float p1 = dot(d1, p) * k + t;",
    "    float p2 = dot(d2, p) * k * 1.7 + t * 1.3;",
    "    vec2 grad = d1 * (cos(p1) * k) + d2 * (cos(p2) * k * 1.7 * 0.6);",
    // The rings ride the same amplitude, so one in thin water is as subtle as the chop
    // around it. Three crests per `wave.scale`, which is what a splash looks like.
    "    float rw = 6.2831853 / max(waterWave.y * 3.0, 0.05);",
    "    grad += rippleGrad(p, waterRipple0, rw) + rippleGrad(p, waterRipple1, rw)",
    "        + rippleGrad(p, waterRipple2, rw);",
    // ...and the whole field is faded out where one pixel spans a wave. Every pool past a few
    // metres is seen at a grazing angle, where a pixel covers many crests; a normal field
    // sampled that far below its own frequency does not read as chop, it reads as stripes and
    // glitter *tearing* across the water. `fwidth` is exactly the phase one pixel covers, so
    // the fade lands where the sampling does and the distance settles back into the flat
    // mirror the chop averages to. (Nyquist is a phase step of pi; the fade starts well under
    // it because the specular is a point sample of a tight lobe.)
    "    float phase = max(fwidth(p1), fwidth(p2));",
    "    grad *= 1.0 - smoothstep(0.5, 1.6, phase);",
    "    return normalize(vec3(-grad.x * amp, 1.0, -grad.y * amp));",
    "}",
    "void main() {",
    // A pool is flat only until it is not: the normal comes from the chop, and between
    // them the view, the light and the reflection are all measured against it.
    "    vec3 viewDir = normalize(camPos - fragWorldPos);",
    "    vec3 n = waterNormal(fragWorldPos.xz, fragDepth);",
    "    vec3 l = normalize(lightDir);",
    "    float ndl = max(dot(n, l), 0.0);",
    "    vec3 ambient = ambientColor.rgb * 1.05;",
    "    float shadow = 1.0;",
    "    if (shadowStrength > 0.001) {",
    "        vec4 lclip = lightVP * vec4(fragWorldPos, 1.0);",
    "        vec3 ndc = lclip.xyz / lclip.w;",
    "        vec2 uv = ndc.xy * 0.5 + 0.5;",
    "        float ref = ndc.z * 0.5 + 0.5;",
    "        if (uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0 && ref < 1.0) {",
    "            float sum = 0.0;",
    "            for (int y = -1; y <= 1; y++) {",
    "                for (int x = -1; x <= 1; x++) {",
    "                    vec3 e = texture(texture1, uv + vec2(float(x), float(y))*shadowTexel).rgb;",
    "                    float d = 1.0 - unpackDepth(e);",
    "                    sum += (ref - shadowBias > d) ? 1.0 : 0.0;",
    "                }",
    "            }",
    "            shadow = 1.0 - (sum/9.0)*shadowStrength;",
    "        }",
    "    }",
    // The absorption: the tint runs from the shallow one to the deep one with the water's
    // own *depth*, so a puddle reads thin and a pool reads deep -- the depth, and not how
    // full the basin is, which is what a real pool does (Beer-Lambert). The depth is
    // capped in the vertex shader at the basin's own potential, so a basin filled to its
    // rim reaches the deep tint exactly. `shore` is that share, and the alpha's below.
    "    float shore = clamp(fragDepth / max(waterShore, 1e-4), 0.0, 1.0);",
    "    vec3 texel = mix(waterShallow.rgb, waterDeep.rgb, shore);",
    "    vec3 diffuse = lightColor.rgb * ndl * shadow;",
    "    vec3 halfV = normalize(l + viewDir);",
    // The glitter. A tight lobe over the wave normals is what makes a pool sparkle
    // rather than glow: the ground's 24 is a broad sheen, and the sun's own reflection
    // is a point the chop spreads into a path.
    "    float spec = pow(max(dot(n, halfV), 0.0), 160.0) * ndl * shadow * 0.9;",
    "    vec3 color = texel * (ambient + diffuse) + lightColor.rgb * spec;",
    "    if (blastEnergy > 0.001) {",
    "        vec3 bd = blastPos - fragWorldPos;",
    "        float bd2 = dot(bd, bd);",
    "        float blastAtt = blastEnergy * (1.0 / (1.0 + bd2 * 0.01));",
    "        float blastNdl = max(dot(n, bd * inversesqrt(bd2 + 0.25)), 0.0);",
    "        color += texel * blastColor.rgb * (blastAtt * (0.35 + 0.65 * blastNdl));",
    "    }",
    // The fresnel (M20c): a thin sheet of water is nearly transparent seen from above
    // and nearly a mirror seen along it, which is the single biggest "wet" cue there is.
    // `waterSky` is what the reflection sees until M20e has a real mirror to sample, and
    // it dims with the clock, so night water reflects a dark sky.
    "    float ndv = max(dot(n, viewDir), 0.0);",
    "    float fres = waterFresnel + (1.0 - waterFresnel) * pow(1.0 - ndv, 5.0);",
    "    vec3 refl = reflect(-viewDir, n);",
    "    vec3 sky = waterSky * (0.55 + 0.45 * clamp(refl.y, 0.0, 1.0));",
    "    color = mix(color, sky, fres);",
    // The shore: the same share as the tint's -- a sheet a few centimetres deep is barely
    // there, so the alpha runs out with the depth and the water's edge is a fade rather
    // than a drawn line.
    "    finalColor = vec4(color, waterDeep.a * shore);",
    "}",
].join("\n");

// The planar blob shadow. The world position carries the pose, so the ground
// projection and the `world.y > groundY` test follow it for free: the blob a
// raised hoof casts moves with the hoof. On a CPU-skinning build that came for
// nothing -- the mesh arrived already deformed -- and with a skinned program it is
// the point of the edit.
// The unlit program raylib's default shader is, which is what the `L` toggle falls
// back to: `mvp` and the vertex colour, texture times `colDiffuse` times that
// colour, nothing else. Only the skinned variant is compiled -- the plain case is
// raylib's own program, which the scene never has to build.
const UNLIT_VS_HEAD = [
    "#version 330",
    "in vec3 vertexPosition;",
    "in vec2 vertexTexCoord;",
    "in vec4 vertexColor;",
    "uniform mat4 mvp;",
    "out vec2 fragTexCoord;",
    "out vec4 fragColor;",
];
const UNLIT_VS_BODY = [
    "void main() {",
    "    fragTexCoord = vertexTexCoord;",
    "    fragColor = vertexColor;",
    "    gl_Position = mvp * skinMatrix() * vec4(vertexPosition, 1.0);",
    "}",
];
function unlitVertex(skin) {
    return UNLIT_VS_HEAD.concat(skin ? SKIN_DECL : PLAIN_SKIN, UNLIT_VS_BODY).join("\n");
}
const UNLIT_VS_SKIN = unlitVertex(true);

const UNLIT_FS = [
    "#version 330",
    "in vec2 fragTexCoord;",
    "in vec4 fragColor;",
    "uniform sampler2D texture0;",
    "uniform vec4 colDiffuse;",
    "out vec4 finalColor;",
    "void main() {",
    "    vec4 texelColor = texture(texture0, fragTexCoord);",
    "    finalColor = texelColor*colDiffuse*fragColor;",
    "}",
].join("\n");

// The celestial bodies (M2): the sun's disc and the moon, one program for both.
// `shaded` is 0 on the sun -- its disc *is* the light, so nothing lights it -- and
// 1 on the moon, which is lit by the sun's direction and so carries a terminator:
// a phase that follows the real sun even at night, when the scene's own light has
// already flipped to the moon. The moon sits at the anti-sun, so on that line the
// phase is full at night and a crescent when the moon is up in the day, which is
// what the geometry says it should be.
const CELESTIAL_VS = [
    "#version 330",
    "in vec3 vertexPosition;",
    "in vec3 vertexNormal;",
    "in vec2 vertexTexCoord;",
    "uniform mat4 mvp;",
    "uniform mat4 matModel;",
    "uniform mat4 matNormal;",
    "out vec3 fragNormal;",
    "out vec3 fragWorldPos;",
    "out vec2 fragTexCoord;",
    "void main() {",
    "    fragNormal = normalize(mat3(matNormal) * vertexNormal);",
    "    fragWorldPos = vec3(matModel * vec4(vertexPosition, 1.0));",
    "    fragTexCoord = vertexTexCoord;",
    "    gl_Position = mvp * vec4(vertexPosition, 1.0);",
    "}",
].join("\n");

const CELESTIAL_FS = [
    "#version 330",
    "in vec3 fragNormal;",
    "in vec3 fragWorldPos;",
    "in vec2 fragTexCoord;",
    "uniform sampler2D texture0;",
    "uniform vec4 colDiffuse;",
    "uniform vec3 camPos;",
    "uniform vec3 sunDir;",
    "uniform float shaded;",
    "out vec4 finalColor;",
    "void main() {",
    // The near face's normal, whichever way the sphere was wound: the mesh is wound
    // outward, and this keeps the terminator on the lit side even where the
    // driver's culling and the winding disagree.
    "    vec3 n = normalize(fragNormal);",
    "    if (dot(n, camPos - fragWorldPos) < 0.0) n = -n;",
    "    vec4 texel = texture(texture0, fragTexCoord) * colDiffuse;",
    // The terminator, with a floor: the moon's dark limb is lit by earthshine
    // rather than cut off, so the body keeps its shape against a dark sky.
    "    float moon = mix(0.12, 1.0, smoothstep(-0.20, 0.30, dot(n, normalize(sunDir))));",
    "    finalColor = vec4(texel.rgb * mix(1.0, moon, shaded), texel.a);",
    "}",
].join("\n");

const SHADOW_VS_HEAD = [
    "#version 330",
    "in vec3 vertexPosition;",
    "uniform mat4 matModel;",
    "uniform mat4 matView;",
    "uniform mat4 matProjection;",
    "uniform vec3 lightDir;",
    "uniform float groundY;",
    "uniform float shadowOn;",
];
const SHADOW_VS_BODY = [
    "void main() {",
    "    vec3 world = (matModel * skinMatrix() * vec4(vertexPosition, 1.0)).xyz;",
    "    if (shadowOn > 0.5 && lightDir.y > 0.06 && world.y > groundY) {",
    "        float t = (world.y - groundY) / lightDir.y;",
    "        vec3 projected = vec3(world.x - lightDir.x*t, groundY, world.z - lightDir.z*t);",
    "        gl_Position = matProjection * matView * vec4(projected, 1.0);",
    "    } else {",
    "        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);",
    "    }",
    "}",
];
function shadowVertex(skin) {
    return SHADOW_VS_HEAD.concat(skin ? SKIN_DECL : PLAIN_SKIN, SHADOW_VS_BODY).join("\n");
}
const SHADOW_VS = shadowVertex(false);
const SHADOW_VS_SKIN = shadowVertex(true);

const SHADOW_FS = [
    "#version 330",
    "uniform float shadowAlpha;",
    "out vec4 finalColor;",
    "void main() { finalColor = vec4(0.02, 0.04, 0.02, shadowAlpha); }",
].join("\n");

// Compile the lit and shadow programs and cache their uniform locations. Must run
// after the window exists (shaders need a GL context).
function makeLighting() {
    // Degrade gracefully on an engine without the shader bindings (the scene then
    // keeps the M2/M3 ambient-tint look).
    if (typeof rl.loadShaderFromMemory !== "function" ||
        typeof rl.setModelShader !== "function" ||
        typeof rl.setShaderValueVector3 !== "function" ||
        typeof rl.setShaderValueVector4 !== "function") {
        console.log("lighting: engine has no shader bindings - using the cube shader");
        litShader = -1;
        lightingText = "cube shader";
        return;
    }
    litShader = rl.loadShaderFromMemory(LIT_VS, LIT_FS);
    if (litShader < 0 || !rl.isShaderValid(litShader)) {
        console.log("lighting: lit shader failed to compile - falling back to the cube shader");
        litShader = -1;
        lightingText = "cube shader";
        return;
    }
    shadowShader = rl.loadShaderFromMemory(SHADOW_VS, SHADOW_FS);
    if (shadowShader < 0 || !rl.isShaderValid(shadowShader)) shadowShader = -1;
    // The celestial bodies' own program (M2). It needs nothing from the rest of the
    // scene but the sun's direction, and if it does not compile the bodies stay on
    // the shader they were built with -- raylib's default, which draws them as flat
    // discs, and no terminator on the moon.
    celestialShader = rl.loadShaderFromMemory(CELESTIAL_VS, CELESTIAL_FS);
    if (celestialShader < 0 || !rl.isShaderValid(celestialShader)) {
        console.log("lighting: celestial shader failed to compile - the bodies draw unshaded");
        celestialShader = -1;
    } else {
        celestialUniforms = {
            sunDir: rl.getShaderLocation(celestialShader, "sunDir"),
            camPos: rl.getShaderLocation(celestialShader, "camPos"),
            shaded: rl.getShaderLocation(celestialShader, "shaded"),
        };
        if (sunMesh >= 0) rl.setModelShader(sunMesh, celestialShader);
        if (moonMesh >= 0) rl.setModelShader(moonMesh, celestialShader);
    }
    // The water surface's program (M20b), compiled before `makeShadowMap` so the map
    // can be attached to it below. It is a `makeModel` mesh with no bone data, like
    // the terrain, so it is never routed through `modelShaderFor`.
    waterShader = rl.loadShaderFromMemory(WATER_VS, WATER_FS);
    if (waterShader < 0 || !rl.isShaderValid(waterShader)) {
        console.log("water: the surface shader did not compile - the pools stay undrawn");
        waterShader = -1;
    } else {
        waterProgram = litProgramInfo(waterShader);
        waterUniforms = {
            level: rl.getShaderLocation(waterShader, "waterLevel"),
            shallow: rl.getShaderLocation(waterShader, "waterShallow"),
            deep: rl.getShaderLocation(waterShader, "waterDeep"),
            shore: rl.getShaderLocation(waterShader, "waterShore"),
            time: rl.getShaderLocation(waterShader, "waterTime"),
            wave: rl.getShaderLocation(waterShader, "waterWave"),
            wind: rl.getShaderLocation(waterShader, "waterWind"),
            fresnel: rl.getShaderLocation(waterShader, "waterFresnel"),
            sky: rl.getShaderLocation(waterShader, "waterSky"),
            ripple0: rl.getShaderLocation(waterShader, "waterRipple0"),
            ripple1: rl.getShaderLocation(waterShader, "waterRipple1"),
            ripple2: rl.getShaderLocation(waterShader, "waterRipple2"),
        };
        console.log("water: surface shader " + waterShader);
    }
    litPrograms = [litProgramInfo(litShader)];
    shadowPrograms = shadowShader >= 0
        ? [{ shader: shadowShader, uniforms: shadowLocations(shadowShader) }] : [];
    // The skinned twins, compiled only where the engine's build needs them. Both
    // families are settled before `makeShadowMap` adds the third, because whether
    // the scene can use GPU skinning at all has to be a load-time answer: a build
    // that has it and a program that does not compile means every animated model
    // needs its CPU pass back, which `modelLoaded` does per model.
    gpuSkin = rl.GPU_SKINNING === true;
    if (gpuSkin) {
        litShaderSkin = loadSkinnedProgram(LIT_VS_SKIN, LIT_FS);
        shadowShaderSkin = shadowShader >= 0 ? loadSkinnedProgram(SHADOW_VS_SKIN, SHADOW_FS) : -1;
        if (litShaderSkin >= 0) litPrograms.push(litProgramInfo(litShaderSkin));
        if (shadowShaderSkin >= 0) {
            shadowPrograms.push({ shader: shadowShaderSkin, uniforms: shadowLocations(shadowShaderSkin) });
        }
        // Not part of `skinnedOk`: this one only draws in the `L` view, so a build
        // that cannot have it should still skin everywhere else.
        unlitShaderSkin = loadSkinnedProgram(UNLIT_VS_SKIN, UNLIT_FS);
        if (unlitShaderSkin < 0) {
            console.log("lighting: the unlit skinned shader did not compile - the L toggle holds the bind pose");
        }
    }
    makeShadowMap();
    // The third family is only knowable now, and only matters where the pass
    // exists at all.
    skinnedOk = gpuSkin && litShaderSkin >= 0 &&
        (shadowShader < 0 || shadowShaderSkin >= 0) &&
        (shadowMode !== SHADOW_MAP || depthShaderSkin >= 0);
    if (gpuSkin && !skinnedOk) {
        console.log("lighting: a skinned program did not compile - the models keep CPU skinning");
    }
    // The models that are already loaded route here: `loadGoat` runs before this
    // step, while the bots and the peers come later and route themselves through
    // `botAdd` and the peer's own load.
    if (haveModel) {
        modelLoaded(model);
        rl.setModelShader(model, modelShaderFor(model, litShader));
    }
    // The terrain is a mesh with no bone data, so it takes the lit program the
    // same way on both builds (`modelShaderFor` is for rigs). The water surface is
    // the same kind of mesh with a program of its own.
    if (terrainMesh >= 0) rl.setModelShader(terrainMesh, litShader);
    if (waterMesh >= 0 && waterShader >= 0) rl.setModelShader(waterMesh, waterShader);
    console.log("lighting: lit shader " + litShader + ", shadow shader " + shadowShader +
        (skinnedOk ? ", skinned" : ""));
}

// The lit program's uniform locations. Looked up per program, so a family's two
// programs get their own -- the names are the same, the locations are not.
function litLocations(shader) {
    return {
        lightDir: rl.getShaderLocation(shader, "lightDir"),
        lightColor: rl.getShaderLocation(shader, "lightColor"),
        ambientColor: rl.getShaderLocation(shader, "ambientColor"),
        camPos: rl.getShaderLocation(shader, "camPos"),
        blastPos: rl.getShaderLocation(shader, "blastPos"),
        blastColor: rl.getShaderLocation(shader, "blastColor"),
        blastEnergy: rl.getShaderLocation(shader, "blastEnergy"),
    };
}

function shadowLocations(shader) {
    return {
        lightDir: rl.getShaderLocation(shader, "lightDir"),
        groundY: rl.getShaderLocation(shader, "groundY"),
        shadowOn: rl.getShaderLocation(shader, "shadowOn"),
        shadowAlpha: rl.getShaderLocation(shader, "shadowAlpha"),
    };
}

function litProgramInfo(shader) {
    return { shader: shader, uniforms: litLocations(shader), shadow: null, sampler: -1 };
}

// Compile one skinned variant, or -1 for a caller that can branch on it. A program
// whose *link* fails comes back as raylib's default program rather than as 0, so
// the `boneMatrices` location is the real proof that this program skins.
function loadSkinnedProgram(vertex, fragment) {
    const shader = rl.loadShaderFromMemory(vertex, fragment);
    if (shader < 0 || !rl.isShaderValid(shader)) return -1;
    if (rl.getShaderLocation(shader, "boneMatrices") < 0) {
        console.log("lighting: a skinned shader has no boneMatrices uniform - not using it");
        return -1;
    }
    return shader;
}

// An animated model, right after it loads. A `gpu-skinning` build handed it over
// with no deform buffers, so this is the one place that can give them back: a rig
// the skinned programs cannot cover -- too many bones for `boneMatrices`, or a
// program that did not compile -- has to keep deforming on the CPU, or it draws at
// its bind pose forever. Per model on purpose: the fallback is raylib's own, and
// the rest of the herd does not have to pay for one mod's rig.
function modelLoaded(handle) {
    if (!gpuSkin) return;
    const bones = rl.modelBoneCount(handle);
    if (skinnedOk && bones <= BONE_MATRICES) return;
    if (bones > BONE_MATRICES) {
        console.log("lighting: model " + handle + " has " + bones + " bones, over the skinned " +
            "programs' " + BONE_MATRICES + " - it keeps CPU skinning");
    }
    plainModels[handle] = true;
    if (typeof rl.setModelCpuSkinning === "function") rl.setModelCpuSkinning(handle, true);
}

// The program to route an animated model to, given the plain program for the pass:
// the skinned counterpart, or `plain` where the model has to keep CPU skinning or
// there is no skinned counterpart to give. `-1` says "the shader the model was
// loaded with" -- how the `L` toggle turns the lighting off -- and that has a
// counterpart as well: raylib's own default program does not skin, so leaving it
// would hold every goat in its bind pose for as long as the lighting is off.
function modelShaderFor(handle, plain) {
    if (!skinnedOk || plainModels[handle] === true) return plain;
    if (plain < 0) return unlitShaderSkin;   // -1 as well, where that did not compile
    if (plain === litShader) return litShaderSkin;
    if (plain === shadowShader) return shadowShaderSkin;
    if (plain === depthShader) return depthShaderSkin;
    return plain;
}

// Refresh the light direction and colours from the day/night clock. The two
// bodies `drawCelestial` puts in the sky sit on this same line -- the sun at
// `SUN_DIR`, the moon at its negation -- so the visible disc, the sky's glow, the
// cloud light and the shadow map all agree about where the light is.
function updateLight() {
    const a = ((worldTime - 6) / 12) * Math.PI;   // 0 at 06:00, PI at 18:00
    const sunX = Math.cos(a);
    const sunY = Math.sin(a);
    const tilt = 0.18;                            // push the arc off the XZ plane
    const sunLen = Math.sqrt(sunX * sunX + sunY * sunY + tilt * tilt) || 1;
    SUN_DIR[0] = sunX / sunLen;
    SUN_DIR[1] = sunY / sunLen;
    SUN_DIR[2] = tilt / sunLen;
    const day = sunY > 0;
    // The light is whichever body is up: the sun's direction by day, the moon's --
    // the negation -- after dusk. The flip is therefore exactly at the horizon, which
    // is where `drawCelestial` fades the bodies out as well, so a visible disc and the
    // light never disagree. (A threshold just above zero left a few game-minutes in
    // which the sun was still drawn while the light had already gone to a moon that
    // was still below the horizon.)
    LIGHT_DIR[0] = day ? SUN_DIR[0] : -SUN_DIR[0];
    LIGHT_DIR[1] = day ? SUN_DIR[1] : -SUN_DIR[1];
    LIGHT_DIR[2] = day ? SUN_DIR[2] : -SUN_DIR[2];

    const warm = Math.max(0, Math.min(1, 1 - Math.abs(sunY) / 0.45));
    const intense = day ? 0.30 + 0.70 * skyLight : 0.16;
    if (day) {
        LIGHT_COLOR[0] = intense;
        LIGHT_COLOR[1] = intense * (1 - 0.22 * warm);
        LIGHT_COLOR[2] = intense * (1 - 0.55 * warm);
    } else {
        LIGHT_COLOR[0] = intense * 0.72;
        LIGHT_COLOR[1] = intense * 0.80;
        LIGHT_COLOR[2] = intense;
    }
    LIGHT_AMBIENT[0] = 0.10 + 0.12 * skyLight;
    LIGHT_AMBIENT[1] = 0.12 + 0.13 * skyLight;
    LIGHT_AMBIENT[2] = 0.18 + 0.16 * skyLight;
}

// Push this frame's lit uniforms. Every program of the family gets them: they are
// separate GL programs, so a value uploaded to the plain one is invisible to the
// skinned one the animated models are routed to. (`setShaderValue*` enables the
// shader it is given, which does not disturb an open `beginShaderMode` block -- a
// batch flush re-binds the program raylib recorded there.)
function setLitUniforms(cx, cy, cz) {
    for (let i = 0; i < litPrograms.length; i++) setLitUniformsOn(litPrograms[i], cx, cy, cz);
    // The water surface shares this frame's light, so it gets the same push. Its own
    // uniforms (the level and the colours) are water.js's, pushed as it draws.
    if (waterProgram !== null) setLitUniformsOn(waterProgram, cx, cy, cz);
}

function setLitUniformsOn(program, cx, cy, cz) {
    const shader = program.shader;
    const u = program.uniforms;
    rl.setShaderValueVector3(shader, u.lightDir,
        LIGHT_DIR[0], LIGHT_DIR[1], LIGHT_DIR[2]);
    rl.setShaderValueVector4(shader, u.lightColor,
        LIGHT_COLOR[0], LIGHT_COLOR[1], LIGHT_COLOR[2], 1.0);
    rl.setShaderValueVector4(shader, u.ambientColor,
        LIGHT_AMBIENT[0], LIGHT_AMBIENT[1], LIGHT_AMBIENT[2], 1.0);
    rl.setShaderValueVector3(shader, u.camPos, cx, cy, cz);
    rl.setShaderValueVector3(shader, u.blastPos,
        BLAST_POS[0], BLAST_POS[1], BLAST_POS[2]);
    rl.setShaderValueVector4(shader, u.blastColor,
        BLAST_TINT[0], BLAST_TINT[1], BLAST_TINT[2], 1.0);
    rl.setShaderValue(shader, u.blastEnergy, BLAST_POS[3],
        rl.SHADER_UNIFORM_FLOAT);
    if (program.shadow === null) return;
    setMatrixOn(shader, program.shadow.lightVP, LIGHT_MATRIX);
    rl.setShaderValueVector2(shader, program.shadow.texel,
        1 / TUNING.lighting.shadow.size, 1 / TUNING.lighting.shadow.size);
    rl.setShaderValue(shader, program.shadow.bias, TUNING.lighting.shadow.bias, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(shader, program.shadow.strength, shadowStrengthNow, rl.SHADER_UNIFORM_FLOAT);
    // The grass and the cube fallback are immediate-mode geometry, which never
    // sees the model's material map 1, so bind the shadow sampler explicitly for
    // the batch path.
    if (shadowStrengthNow > 0.001 && program.sampler >= 0) {
        rl.setShaderValueTexture(shader, program.sampler, shadowColor);
    }
}

function setShadowUniforms() {
    for (let i = 0; i < shadowPrograms.length; i++) {
        const program = shadowPrograms[i];
        const shader = program.shader;
        const u = program.uniforms;
        rl.setShaderValueVector3(shader, u.lightDir,
            LIGHT_DIR[0], LIGHT_DIR[1], LIGHT_DIR[2]);
        rl.setShaderValue(shader, u.groundY,
            GROUND_Y + terrainHeight(goat.px, goat.pz), rl.SHADER_UNIFORM_FLOAT);
        rl.setShaderValue(shader, u.shadowOn, 1.0, rl.SHADER_UNIFORM_FLOAT);
        rl.setShaderValue(shader, u.shadowAlpha,
            SHADOW_ALPHA * (0.35 + 0.65 * skyLight), rl.SHADER_UNIFORM_FLOAT);
    }
}

// Push this frame's celestial uniforms: the sun's direction (the moon's light, and
// the sun's own) and the camera position, which the fragment shader uses to pick
// the near face's normal.
function setCelestialUniforms(cx, cy, cz) {
    if (celestialShader < 0) return;
    rl.setShaderValueVector3(celestialShader, celestialUniforms.sunDir,
        SUN_DIR[0], SUN_DIR[1], SUN_DIR[2]);
    rl.setShaderValueVector3(celestialShader, celestialUniforms.camPos, cx, cy, cz);
}

// ---- shadow map (M4b) ----------------------------------------------------
//
// A depth-only pass renders the goat (and the grass inside the light's box)
// from the light's point of view into a render texture; the lit shader
// projects each fragment into that view and
// compares depths with a 3x3 PCF kernel, so the goat self-shadows and the
// terrain takes a proper (perspective-correct) shadow. Depth is packed across
// RGB and stored as `1 - depth`, so the cleared-black background reads as "far".
//
// Getting an extra texture into a *model* draw is the awkward part: `DrawMesh`
// binds a material's map `i` to texture unit `i` and feeds `texture{i}` from it,
// while `setShaderValueTexture` picks a unit that those maps then overwrite. So
// the shadow map lives in every material's map 1 (metalness), which the lit
// shader does not otherwise use -- for the goat, the herd and the terrain mesh
// alike. The grass and the cube fallback are immediate-mode (batch) draws with no
// materials, so they get the sampler with `setShaderValueTexture` instead.

const SHADOW_OFF = 0;
const SHADOW_PLANAR = 1;
const SHADOW_MAP = 2;

const SHADOW_MAP_INDEX = 1;   // MATERIAL_MAP_METALNESS -> sampler `texture1`
// The map's size, box and depth range are `TUNING.lighting.shadow` (core.js).
// The map only spans a `half` box around the goat, so every tuft inside it is
// exactly the grass shadow the lit shader can sample (anything outside would
// project to out-of-range uv and be ignored). The small margin catches tufts
// just outside whose short shadow leans into the box.
function shadowGrassCull2() {
    const half = TUNING.lighting.shadow.half + 2.0;
    return half * half;
}

let shadowMapReady = false;
let shadowMode = SHADOW_PLANAR;
let shadowRT = -1;
let shadowColor = -1;
let depthShader = -1;
const LIGHT_MATRIX = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
let shadowStrengthNow = 0;

const DEPTH_VS_HEAD = [
    "#version 330",
    "in vec3 vertexPosition;",
    "uniform mat4 matModel;",
    "uniform mat4 lightVP;",
    "out vec4 vClip;",
];
// Skinning is model space, so it goes exactly where `vertexPosition` was: after
// `matModel`'s operands and before `lightVP`.
const DEPTH_VS_BODY = [
    "void main() {",
    "    vClip = lightVP * matModel * skinMatrix() * vec4(vertexPosition, 1.0);",
    "    gl_Position = vClip;",
    "}",
];
function depthVertex(skin) {
    return DEPTH_VS_HEAD.concat(skin ? SKIN_DECL : PLAIN_SKIN, DEPTH_VS_BODY).join("\n");
}
const DEPTH_VS = depthVertex(false);
const DEPTH_VS_SKIN = depthVertex(true);

const DEPTH_FS = [
    "#version 330",
    "in vec4 vClip;",
    "out vec4 finalColor;",
    "vec3 packDepth(float d) {",
    "    vec3 enc = fract(vec3(1.0, 255.0, 65025.0)*d);",
    "    enc -= enc.yzz*vec3(1.0/255.0, 1.0/255.0, 0.0);",
    "    return enc;",
    "}",
    "void main() {",
    "    float depth = vClip.z/vClip.w*0.5 + 0.5;",
    "    finalColor = vec4(packDepth(clamp(1.0 - depth, 0.0, 0.999)), 1.0);",
    "}",
].join("\n");

function cross3(a, b) {
    return [a[1]*b[2] - a[2]*b[1], a[2]*b[0] - a[0]*b[2], a[0]*b[1] - a[1]*b[0]];
}
function dot3(a, b) {
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}
function unit3(v) {
    const l = Math.sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]) || 1;
    return [v[0]/l, v[1]/l, v[2]/l];
}

// Orthographic world -> light-clip matrix: x/y span the `TUNING.lighting.shadow`
// half-width box around (cx, cy, cz), z runs its near..far range along the light
// direction, with the light at its `dist`.
//
// The 16 values are the matrix in COLUMN-major order, which is what
// `SetShaderValueMatrix` uploads and GLSL reads: the R/U/L basis vectors are the
// columns and the translation lands in the last four. Listing them row-major
// instead transposes the basis, which leaves the box pinned near the world
// origin -- the shadow then only appears while the goat is still near spawn and
// fades out (and comes back) as it walks away and returns.
function buildLightMatrix(cx, cy, cz) {
    const shadow = TUNING.lighting.shadow;
    const L = unit3(LIGHT_DIR);
    const up = Math.abs(L[1]) > 0.95 ? [0, 0, 1] : [0, 1, 0];
    const R = unit3(cross3(up, L));
    const U = cross3(L, R);
    const k = 2 / (shadow.far - shadow.near);
    const dL = dot3([cx, cy, cz], L);
    const dR = dot3([cx, cy, cz], R);
    const dU = dot3([cx, cy, cz], U);
    const t2 = k*(shadow.dist + dL) - k*shadow.near - 1;
    return [
        R[0]/shadow.half, U[0]/shadow.half, -k*L[0], 0,
        R[1]/shadow.half, U[1]/shadow.half, -k*L[1], 0,
        R[2]/shadow.half, U[2]/shadow.half, -k*L[2], 0,
        -dR/shadow.half, -dU/shadow.half, t2, 1,
    ];
}

function setMatrixOn(shader, loc, m) {
    rl.setShaderValueMatrix(shader, loc,
        m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7],
        m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15]);
}

// The shadow map's uniforms on one lit program, and the sampler for the batch
// path: the grass and the cube fallback are immediate-mode geometry with no
// materials, so they get the map by hand (`setShaderValueTexture`) while a model
// gets it as material map 1. Every program of the lit family needs its own
// locations, so this runs once per program.
function attachShadowMap(program) {
    program.sampler = rl.getShaderLocation(program.shader, "texture1");
    program.shadow = {
        lightVP: rl.getShaderLocation(program.shader, "lightVP"),
        texel: rl.getShaderLocation(program.shader, "shadowTexel"),
        bias: rl.getShaderLocation(program.shader, "shadowBias"),
        strength: rl.getShaderLocation(program.shader, "shadowStrength"),
    };
}

// Build the render texture and depth program. Needs the window (GL) and the lit
// shader already compiled.
function makeShadowMap() {
    if (typeof rl.loadRenderTexture !== "function" || typeof rl.setModelTexture !== "function" ||
        typeof rl.setShaderValueMatrix !== "function" || typeof rl.setShaderValueTexture !== "function") {
        console.log("shadow map: engine lacks the bindings - keeping the planar shadow");
        return;
    }
    attachShadowMap(litPrograms[0]);
    if (litPrograms.length > 1) attachShadowMap(litPrograms[1]);
    // The water surface receives the same shadow the ground does, so a pool in the
    // goat's shadow goes dark with it.
    if (waterProgram !== null) attachShadowMap(waterProgram);
    shadowRT = rl.loadRenderTexture(TUNING.lighting.shadow.size, TUNING.lighting.shadow.size);
    if (shadowRT < 0 || !rl.isRenderTextureValid(shadowRT)) {
        shadowRT = -1;
        console.log("shadow map: no render texture - keeping the planar shadow");
        return;
    }
    shadowColor = rl.renderTextureColor(shadowRT);
    depthShader = rl.loadShaderFromMemory(DEPTH_VS, DEPTH_FS);
    if (depthShader < 0 || !rl.isShaderValid(depthShader)) {
        depthShader = -1;
        console.log("shadow map: depth shader failed to compile - keeping the planar shadow");
        return;
    }
    // The pass draws models too, so a `gpu-skinning` build needs the skinned depth
    // program as well: without it the goats land in the map at their bind pose,
    // which is the kind of wrong nobody looks at twice.
    depthShaderSkin = gpuSkin ? loadSkinnedProgram(DEPTH_VS_SKIN, DEPTH_FS) : -1;
    depthPrograms = [{ shader: depthShader, lightVP: rl.getShaderLocation(depthShader, "lightVP") }];
    if (depthShaderSkin >= 0) {
        depthPrograms.push({
            shader: depthShaderSkin,
            lightVP: rl.getShaderLocation(depthShaderSkin, "lightVP"),
        });
    }
    if (haveModel) rl.setModelTexture(model, SHADOW_MAP_INDEX, shadowColor);
    if (terrainMesh >= 0) rl.setModelTexture(terrainMesh, SHADOW_MAP_INDEX, shadowColor);
    if (waterMesh >= 0) rl.setModelTexture(waterMesh, SHADOW_MAP_INDEX, shadowColor);
    shadowMapReady = true;
    shadowMode = SHADOW_MAP;
    console.log("shadow map: rt " + shadowRT + " color " + shadowColor +
        " depth shader " + depthShader + (depthShaderSkin >= 0 ? "+" + depthShaderSkin : "") +
        " sampler loc " + litPrograms[0].sampler);
}

// Refresh the light matrix and shadow strength for this frame.
function updateShadow() {
    shadowStrengthNow = 0;
    if (shadowMode !== SHADOW_MAP || !shadowMapReady) return;
    // Keep the light's box centred on the goat, snapped so it doesn't shimmer.
    const cx = Math.round(goat.px * 2) / 2;
    const cz = Math.round(goat.pz * 2) / 2;
    const m = buildLightMatrix(cx, 0.7, cz);
    for (let i = 0; i < 16; i++) LIGHT_MATRIX[i] = m[i];
    // Fade the shadow out as the light drops toward the horizon.
    const low = Math.min(1, Math.max(0, (LIGHT_DIR[1] - 0.06) / 0.25));
    shadowStrengthNow = TUNING.lighting.shadow.strength * low * (0.35 + 0.65 * skyLight);
}

// The light matrix lives at a location per depth program, so every one of them
// gets it. `setShaderValue*` enables the shader it is given, which does not
// disturb the open `beginShaderMode` block around the grass: a batch flush
// re-binds the program raylib recorded there.
function setDepthMatrix() {
    for (let i = 0; i < depthPrograms.length; i++) {
        setMatrixOn(depthPrograms[i].shader, depthPrograms[i].lightVP, LIGHT_MATRIX);
    }
}

// Render the goat and the near grass from the light's point of view into the
// shadow texture.
function renderShadowMap() {
    if (!shadowMapReady || !haveModel || shadowStrengthNow <= 0.001) return;
    rl.beginTextureMode(shadowRT);
    rl.clearBackground(rl.color(0, 0, 0, 255));
    rl.beginMode3D(0, 0, 0, goat.px, 0, goat.pz, 45);
    // Grass casts too. It is immediate-mode geometry, so it can only go through
    // the plain program with `beginShaderMode` -- unlike the models below, which
    // are routed through `modelShaderFor`. Drawing it first lets the goat's depth
    // win wherever the two overlap. The tufts are swayed by the same `drawTufts`
    // the visible pass uses, so the shadow tracks the wind.
    setDepthMatrix();
    rl.beginShaderMode(depthShader);
    drawTufts(goat, rl.WHITE, shadowGrassCull2(), shadowGrassCull2());
    rl.endShaderMode();
    perfMark("shadow_grass");
    rl.setModelShader(model, modelShaderFor(model, depthShader));
    // Detach the shadow target while it is the framebuffer's own attachment.
    rl.setModelTexture(model, SHADOW_MAP_INDEX, -1);
    setDepthMatrix();
    drawModelGoat(goat, rl.WHITE);
    perfMark("shadow_goat");
    drawBotsShadow();
    drawPeersShadow();
    perfMark("shadow_bots");
    rl.setModelTexture(model, SHADOW_MAP_INDEX, shadowColor);
    rl.setModelShader(model, modelShaderFor(model, litShader));
    rl.endMode3D();
    rl.endTextureMode();
    perfMark("shadow_tail");
}

