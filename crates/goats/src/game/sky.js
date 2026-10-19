// ---- sky shader (M5b): volumetric cumulus and cirrus ----------------------
//
// The sky is a full-screen pass per layer: the air and the cloud as two passes
// whenever the cloud layer can be blended over what is under it, so the celestial
// bodies sit behind the clouds rather than in front of them. For each pixel the
// shader rebuilds the camera ray from the camera basis, shades an analytic
// atmosphere, and then raymarches a slab of cloud between
// `TUNING.sky.cloudBase` and `TUNING.sky.cloudTop`.
//
// What makes it read as a volume rather than a texture:
//
//   * The density field is fBm domain-warped in 2D and sheared with height, so
//     the billows have structure instead of being an extrusion, and the layer
//     parallaxes properly as the camera moves.
//   * Each sample casts a short march toward the sun, so the bases darken and
//     the tops stay bright -- self-shadowing, not a fake light term.
//   * Transmittance is Beer-Lambert, and a Henyey-Greenstein phase function
//     gives the forward-scattering rim that brightens the sun's side.
//   * A thin, sheared cirrus layer sits above the cumulus, and distant cloud
//     fades into the horizon haze.
//
// Cost is the reason for every economy here: the light march uses a two-octave
// density without the high-frequency erosion, the erosion is only evaluated
// near a cloud surface, and the step count comes from the `clouds` setting.
// `B` still falls back to the M2 gradient and the noise-puff billboards.
//
// The atmosphere's Rayleigh/Mie split, the dusk horizon rim and the height-lit
// cloud deck are borrowed from Sky3D (github.com/TokisanGames/Sky3D, MIT),
// re-expressed for this display-space two-layer pass rather than copied. The
// palette, the clock and the celestial sprites stay the scene's.

// The slab geometry, density and march steps are `TUNING.sky` (core.js).
const CLOUD_LEVELS = ["low", "medium", "high"];

let skyShader = -1;
let skyNoise = -1;              // the cumulus slice texture (`noiseClouds.png`)
let skyUniforms = null;
let useSkyShader = true;
let skyTime = 0;

const SKY_VS = [
    "#version 330",
    "in vec3 vertexPosition;",
    "uniform mat4 mvp;",
    "void main() { gl_Position = mvp * vec4(vertexPosition, 1.0); }",
].join("\n");

const SKY_FS = [
    "#version 330",
    "out vec4 finalColor;",
    "uniform vec2  screenSize;",
    "uniform vec3  camPos;",
    "uniform vec3  camForward;",
    "uniform vec3  camRight;",
    "uniform vec3  camUp;",
    "uniform float tanHalfFov;",
    "uniform float aspect;",
    "uniform vec3  zenithColor;",
    "uniform vec3  horizonColor;",
    "uniform vec3  sunDir;",
    // The sun's own direction. `sunDir` is the *active* light -- the sun by
    // day, the moon after dusk -- but the warmth stays on the sun's side for a
    // while after it sets, which is what the horizon rim below reads.
    "uniform vec3  sunTrueDir;",
    "uniform sampler2D cumulus_texture;",
    "uniform vec4  sunColor;",
    "uniform float cloudiness;",
    "uniform float time;",
    "uniform vec2  wind;",
    "uniform vec3  cloudLit;",
    "uniform vec3  cloudShadow;",
    "uniform float cloudBase;",
    "uniform float cloudTop;",
    "uniform float cloudScale;",
    "uniform float cloudDetail;",
    "uniform float cloudAbsorb;",
    "uniform float cirrus;",
    "uniform float cirrusHeight;",
    "uniform float nightDim;",
    "uniform int   cloudSteps;",
    // Which part of the sky this pass draws (`SKY_LAYER_*`): 0 the whole thing,
    // 1 the air alone, 2 the clouds alone -- and the last one premultiplied, so it
    // composites over whatever is already on the screen.
    "uniform float skyLayer;",
    "const float PI = 3.14159265;",
    "const float MAX_DIST = 450.0;",
    // ---- noise ----
    "float hash21(vec2 p) { p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }",
    "float vnoise2(vec2 p) {",
    "    vec2 i = floor(p); vec2 f = fract(p);",
    "    vec2 u = f * f * (3.0 - 2.0 * f);",
    "    return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),",
    "               mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);",
    "}",
    // The body uses three octaves, the warp and the detail two, to keep the
    // per-sample cost down.
    "float fbm3(vec2 p) {",
    "    float v = 0.0; float a = 0.5;",
    "    for (int i = 0; i < 3; i++) { v += a * vnoise2(p); p = p * 2.03 + 11.7; a *= 0.5; }",
    "    return v;",
    "}",
    "float fbm2(vec2 p) {",
    "    float v = 0.0; float a = 0.5;",
    "    for (int i = 0; i < 2; i++) { v += a * vnoise2(p); p = p * 2.11 + 7.3; a *= 0.5; }",
    "    return v;",
    "}",
    // ---- the cumulus slab ----
    "float slabY(vec3 p) { return (p.y - cloudBase) / max(cloudTop - cloudBase, 1e-3); }",
    "float remap(float v, float a, float b, float c, float d) {",
    "    return c + (v - a) * (d - c) / max(b - a, 1e-4);",
    "}",
    // Sky3D's 3D noise from a 2D texture: two z-slices, mixed by the fraction.
    // `p.xy` is in texture repeats and `p.z` selects the slice.
    "float sample_cumulus_noise(vec3 p) {",
    "    vec2 offset = vec2(0.317, 0.123);",
    "    vec2 uv0 = p.xy + offset * floor(p.z);",
    "    vec2 uv1 = uv0 + offset;",
    "    float a = textureLod(cumulus_texture, uv0, 0.0).r;",
    "    float b = textureLod(cumulus_texture, uv1, 0.0).r;",
    "    return mix(a, b, fract(p.z));",
    "}",
    // Sky3D's four octaves. The last two fade with distance through `detailAmt`
    // (and are skipped for the sun march), which is this pass's answer to the
    // texture aliasing at a grazing angle.
    "float calc_cumulus_fbm(vec3 p, float l, float detailAmt) {",
    "    float ret = 0.51749673 * sample_cumulus_noise(p);",
    "    p *= l;",
    "    ret += 0.25584929 * sample_cumulus_noise(p);",
    "    if (detailAmt > 0.001) {",
    "        float hi = clamp(detailAmt * 3.0, 0.0, 1.0);",
    "        p *= l;",
    "        ret += 0.12527603 * hi * sample_cumulus_noise(p);",
    "        p *= l;",
    "        ret += 0.06255931 * hi * sample_cumulus_noise(p);",
    "    }",
    "    return ret;",
    "}",
    "float cloudDensity(vec3 p, vec2 drift, float detailAmt) {",
    "    float y = slabY(p);",
    "    if (y < 0.0 || y > 1.0) return 0.0;",
    // The world slab in texture repeats. Sky3D's own sphere works out to
    // ~0.0003 UV per metre; the slab is shallower, so the scale is a little
    // larger. `drift` is still in the old q units, so it is scaled with it.
    "    vec2 uv = p.xz * 0.001 - drift * 0.0083;",
    "    float slice = (y - 0.5) * 4.0;",
    "    float base = calc_cumulus_fbm(vec3(uv, slice), 2.7, detailAmt);",
    // The texture's fBm is narrow around its mean; expanding that spread is
    // what turns it from a haze into separate cloud bodies.
    "    base = clamp((base - 0.43) * 1.5 + 0.43, 0.0, 1.0);",
    // Sky3D's density: double the field for contrast, then a soft threshold
    // that rises with height. The base stays dense while the top erodes, so
    // the deck rounds off instead of ending on a plane.
    "    float dens = base * 2.0;",
    // `cloudiness` is the scene's 0..1; Sky3D's coverage is 0.15..0.95 over it.
    "    float coverage = mix(0.15, 0.95, cloudiness);",
    "    float cov = 1.0 - coverage;",
    // 3.0 rather than Sky3D's 3.5: bilinear filtering smooths the texture's
    // high tail, but 2.5 covered too much sky at this scale.
    "    float mask = smoothstep(0.0, cov * 3.0 + y, dens);",
    "    dens *= mask;",
    // The remap lands at a full 1.0 in the core; 0.70 keeps the optical depth
    // (and the sun march's self-shadow) in the range the old field had.
    "    dens = remap(dens, 1.0 - mask, 1.0, 0.0, 1.0) * 0.85;",
    // Soft base and top, so the deck does not start or end on a plane.
    "    dens *= smoothstep(0.0, 0.08, y) * (1.0 - smoothstep(0.72, 1.0, y));",
    "    return clamp(dens, 0.0, 1.0);",
    "}",
    // Extinction between a point and the sun: the self-shadow term.
    "float sunTau(vec3 p, vec2 drift) {",
    "    float stepLen = (cloudTop - cloudBase) * 0.28;",
    "    vec3 step = sunDir * stepLen;",
    "    float tau = 0.0;",
    // 0.2 keeps two extra octaves in the self-shadow: with only the first two
    // the density is too low and the cloud bases stay flat.
    "    for (int i = 0; i < 3; i++) { p += step; tau += cloudDensity(p, drift, 0.2); }",
    "    return tau * stepLen;",
    "}",
    // Henyey-Greenstein: a forward lobe is the bright rim on the sun's side, a
    // small negative lobe softens the back.
    "float hg(float cosT, float g) {",
    "    float g2 = g * g;",
    "    float denom = 1.0 + g2 - 2.0 * g * cosT;",
    "    return (1.0 - g2) / (4.0 * PI * pow(max(denom, 1e-3), 1.5));",
    "}",
    // ---- atmosphere ----
    "vec3 skyBackground(vec3 dir) {",
    "    float h = clamp(dir.y, 0.0, 1.0);",
    "    vec3 col = mix(horizonColor, zenithColor, pow(h, 0.45));",
    // The sun's own direction, not `sunDir`: at dusk the light has already
    // flipped to the moon while the warmth is still on the sun's side.
    "    float mu = dot(dir, sunTrueDir);",
    "    float up = clamp(sunTrueDir.y, 0.0, 1.0);",
    "    float low = 1.0 - up;",
    "    float daylight = 1.0 - nightDim;",
    // Sky3D's two lobes: the Rayleigh lobe is the broad sky, the Mie lobe the
    // forward halo. The palette stays the scene's; these only place the light.
    "    float rayleigh = 0.75 * (1.0 + mu * mu);",
    "    float mie = hg(mu, mix(0.82, 0.55, low));",
    "    vec3 warm = mix(vec3(1.0), vec3(1.0, 0.62, 0.38), low);",
    "    col += warm * daylight * (mie * (0.10 + 0.30 * low) + rayleigh * 0.02);",
    // The horizon rim survives a little past sunset, which the old single
    // `pow(mu, ...)` lobe could not do.
    "    float dusk = (1.0 - smoothstep(0.0, 0.35, sunTrueDir.y)) * smoothstep(-0.35, 0.0, sunTrueDir.y);",
    "    col += warm * exp(-h * 5.0) * (0.25 + 0.75 * max(mu, 0.0)) * dusk * 0.45;",
    // NOTE: the sun and moon discs themselves are drawn by `drawCelestial`
    // (world.js) as sprites over this pass, so the shader must not draw one too.
    // Haze hugging the horizon.
    "    col = mix(col, horizonColor, smoothstep(0.13, 0.0, dir.y) * 0.32);",
    "    return col;",
    "}",
    // Thin, stretched, wind-sheared high layer: two octaves, no march.
    "vec3 cirrusLayer(vec3 dir, vec3 behind) {",
    "    if (cirrus < 0.02 || dir.y < 0.03) return behind;",
    "    float t = (cirrusHeight - camPos.y) / dir.y;",
    "    if (t <= 0.0) return behind;",
    "    vec2 p = (camPos.xz + dir.xz * t) * cloudScale * 1.7 + wind * time * 0.006;",
    "    float n = fbm2(vec2(p.x * 0.24, p.y * 1.9));",
    // A second, finer stretch keeps the high layer from reading as one streak.
    "    float n2 = fbm2(vec2(p.x * 0.55 + 7.0, p.y * 3.2 - 3.0));",
    "    n = mix(n, n2, 0.35);",
    "    float cover = mix(0.82, 0.42, cirrus);",
    "    float mask = smoothstep(cover, cover + 0.28, n);",
    "    float dusk = (1.0 - smoothstep(0.0, 0.35, sunTrueDir.y)) * smoothstep(-0.35, 0.0, sunTrueDir.y);",
    "    vec3 c = mix(cloudShadow, cloudLit, 0.55 + 0.45 * clamp(sunDir.y, 0.0, 1.0));",
    "    c *= mix(vec3(1.0), vec3(1.0, 0.74, 0.54), dusk * 0.7);",
    "    return mix(behind, c, mask * cirrus * exp(-t * 0.0035) * 0.85);",
    "}",
    // ---- the march ----
    "vec3 cumulus(vec3 behind, vec3 dir, out float trans) {",
    // The coverage on this ray, which a probe reads back. It has to be written on
    // every path out: an `out` parameter that a return leaves untouched is
    // undefined, and a clear ray is exactly the case that matters most.
    "    trans = 1.0;",
    "    float dy = dir.y;",
    "    if (abs(dy) < 1e-4) return behind;",
    "    float t0 = (cloudBase - camPos.y) / dy;",
    "    float t1 = (cloudTop - camPos.y) / dy;",
    "    if (t0 > t1) { float s = t0; t0 = t1; t1 = s; }",
    "    t0 = max(t0, 0.0);",
    "    if (t1 <= t0) return behind;",
    "    float span = min(t1 - t0, MAX_DIST);",
    // Exponential stepping: samples stay dense near the camera and stretch with
    // distance, where a cloud covers fewer pixels. A uniform step pattern
    // aliases badly at grazing angles, and that aliasing *is* what reads as
    // pixelated noise.
    "    float growth = mix(1.0, 1.4, clamp(span / 120.0, 0.0, 1.0));",
    "    float dt;",
    "    if (growth > 1.0001) {",
    "        dt = span * (growth - 1.0) / (pow(growth, float(cloudSteps)) - 1.0);",
    "    } else {",
    "        dt = span / float(cloudSteps);",
    "    }",
    "    vec2 drift = wind * time * 0.01;",
    "    float dusk = (1.0 - smoothstep(0.0, 0.35, sunTrueDir.y)) * smoothstep(-0.35, 0.0, sunTrueDir.y);",
    "    float cosT = dot(dir, sunDir);",
    "    float ph = hg(cosT, 0.72) * 0.75 + hg(cosT, -0.28) * 0.40;",
    // No per-pixel jitter: randomising the start offset per pixel is exactly the
    // speckle it was meant to hide, and the exponential steps already stagger the
    // samples.
    "    vec3 scatter = vec3(0.0);",
    "    float t = t0 + dt * 0.5;",
    "    for (int i = 0; i < cloudSteps; i++) {",
    "        if (t > t0 + span || trans < 0.02) break;",
    "        vec3 pos = camPos + dir * t;",
    // The erosion is the highest-frequency term, so it fades with distance
    // rather than aliasing.
    "        float dens = cloudDensity(pos, drift, cloudDetail / (1.0 + t * 0.05));",
    "        if (dens > 0.01) {",
    "            float tau = sunTau(pos, drift);",
    // Beer-Lambert along the sun ray, plus the powder term that darkens dense
    // interiors instead of letting them glow.
    "            float sunT = exp(-tau * cloudAbsorb);",
    "            float powder = 1.0 - exp(-tau * cloudAbsorb * 2.0);",
    "            float lum = sunT * mix(0.55, 1.0, powder);",
    "            vec3 c = mix(cloudShadow, cloudLit, clamp(lum, 0.0, 1.0));",
    // Sky3D lights a cloud from its top down (`exp(h)`), which is what keeps an
    // overcast deck from reading as one flat grey sheet.
    "            float cy = clamp((pos.y - cloudBase) / max(cloudTop - cloudBase, 1e-3), 0.0, 1.0);",
    "            c *= 0.68 + 0.62 * cy;",
    // ...and at dusk the whole deck picks up the sun's warmth, even when the
    // direct light has already flipped to the moon.
    "            c *= mix(vec3(1.0), vec3(1.0, 0.70, 0.48), dusk * 0.85);",
    // Forward scattering tints the rim toward the sun colour; at dusk that is
    // the warm sun, not the moon the light has flipped to.
    "            vec3 rimTint = mix(sunColor.rgb, vec3(1.0, 0.62, 0.35), dusk);",
    "            c += cloudLit * rimTint * ph * sunT * 1.4;",
    // Distance haze blends far cloud into the horizon.
    "            c = mix(c, horizonColor, (1.0 - exp(-t * 0.0022)) * 0.55);",
    "            float a = 1.0 - exp(-dens * cloudAbsorb * dt);",
    "            scatter += trans * a * c;",
    "            trans *= 1.0 - a;",
    "        }",
    "        t += dt;",
    "        dt *= growth;",
    "    }",
    "    return behind * trans + scatter;",
    "}",
    "void main() {",
    "    vec2 uv = gl_FragCoord.xy / screenSize;",
    "    vec2 ndc = vec2(uv.x * 2.0 - 1.0, uv.y * 2.0 - 1.0);",
    "    vec3 dir = normalize(camForward + camRight * (ndc.x * tanHalfFov * aspect)",
    "                                       + camUp * (ndc.y * tanHalfFov));",
    "    float trans = 1.0;",
    "    if (skyLayer > 1.5) {",
    // The cloud layer on its own. `cumulus` uses `behind` only where it returns --
    // `behind * trans + scatter` -- so asking it for nothing leaves exactly the
    // light the cloud scattered, and `1 - trans` is what the cloud leaves of the
    // sky behind it. Premultiplied, those two composite over the celestial bodies
    // drawn between this pass and the air, which is what puts a cloud in front of
    // the sun. The cirrus is not in here: a thin high layer is not an occluder.
    "        vec3 scatter = cloudiness > 0.01 ? cumulus(vec3(0.0), dir, trans) : vec3(0.0);",
    "        finalColor = vec4(scatter, 1.0 - trans);",
    "        return;",
    "    }",
    "    vec3 sky = skyBackground(dir);",
    "    sky = cirrusLayer(dir, sky);",
    "    if (skyLayer < 0.5 && cloudiness > 0.01) sky = cumulus(sky, dir, trans);",
    "    finalColor = vec4(clamp(sky, 0.0, 1.0), 1.0);",
    "}",
].join("\n");

function makeSkyShader() {
    if (typeof rl.loadShaderFromMemory !== "function") return;
    skyShader = loadGlsl(SKY_VS, SKY_FS);
    if (skyShader < 0 || !rl.isShaderValid(skyShader)) {
        console.log("sky: shader failed to compile - keeping the gradient and billboards");
        skyShader = -1;
        return;
    }
    skyUniforms = {
        screenSize: rl.getShaderLocation(skyShader, "screenSize"),
        camPos: rl.getShaderLocation(skyShader, "camPos"),
        camForward: rl.getShaderLocation(skyShader, "camForward"),
        camRight: rl.getShaderLocation(skyShader, "camRight"),
        camUp: rl.getShaderLocation(skyShader, "camUp"),
        tanHalfFov: rl.getShaderLocation(skyShader, "tanHalfFov"),
        aspect: rl.getShaderLocation(skyShader, "aspect"),
        zenithColor: rl.getShaderLocation(skyShader, "zenithColor"),
        horizonColor: rl.getShaderLocation(skyShader, "horizonColor"),
        sunDir: rl.getShaderLocation(skyShader, "sunDir"),
        sunTrueDir: rl.getShaderLocation(skyShader, "sunTrueDir"),
        cumulusTexture: rl.getShaderLocation(skyShader, "cumulus_texture"),
        sunColor: rl.getShaderLocation(skyShader, "sunColor"),
        cloudiness: rl.getShaderLocation(skyShader, "cloudiness"),
        time: rl.getShaderLocation(skyShader, "time"),
        wind: rl.getShaderLocation(skyShader, "wind"),
        cloudLit: rl.getShaderLocation(skyShader, "cloudLit"),
        cloudShadow: rl.getShaderLocation(skyShader, "cloudShadow"),
        cloudBase: rl.getShaderLocation(skyShader, "cloudBase"),
        cloudTop: rl.getShaderLocation(skyShader, "cloudTop"),
        cloudScale: rl.getShaderLocation(skyShader, "cloudScale"),
        cloudDetail: rl.getShaderLocation(skyShader, "cloudDetail"),
        cloudAbsorb: rl.getShaderLocation(skyShader, "cloudAbsorb"),
        cirrus: rl.getShaderLocation(skyShader, "cirrus"),
        cirrusHeight: rl.getShaderLocation(skyShader, "cirrusHeight"),
        nightDim: rl.getShaderLocation(skyShader, "nightDim"),
        cloudSteps: rl.getShaderLocation(skyShader, "cloudSteps"),
        // Which part of the sky a pass draws, `SKY_LAYER_*` below.
        skyLayer: rl.getShaderLocation(skyShader, "skyLayer"),
    };
    // The cumulus noise is the addon's `noiseClouds.png`, embedded in `ASSETS`.
    // A miss is not fatal -- the shader samples zero and the clouds thin out --
    // but it is named so a missing asset is visible in the log.
    if (typeof rl.loadTexture === "function") skyNoise = rl.loadTexture("noiseClouds.png");
    if (skyNoise >= 0 && typeof rl.setTextureFilter === "function") {
        // raylib loads with point filtering; the slice noise is magnified a lot,
        // and point samples read as blocky clouds.
        rl.setTextureFilter(skyNoise, rl.TEXTURE_FILTER_BILINEAR);
    }
    if (skyNoise < 0) console.log("sky: cumulus texture did not load - clouds will be thin");
    console.log("sky: shader " + skyShader + ", clouds " + CLOUD_LEVELS[SETTINGS.cloud] +
        " (" + TUNING.sky.steps[SETTINGS.cloud] + " steps)");
}

function channelOf(packed, shift) {
    return ((packed >>> shift) & 255) / 255;
}

// The march steps for the current quality setting.
function cloudLevel() {
    return clamp(Math.round(SETTINGS.cloud), 0, CLOUD_LEVELS.length - 1);
}

function cloudSteps() {
    return TUNING.sky.steps[cloudLevel()];
}

// The view the sky shader is aimed down: the camera, and the forward/right/up basis
// `drawSky` rebuilds every frame. They are module state rather than parameters
// because `drawSky` is called twice a frame -- once per layer -- and both calls have
// to fill in exactly the same uniforms.
const SKY_CAM = [0, 1, 0];
const SKY_FWD = [0, 0, 1];
const SKY_RIGHT = [1, 0, 0];
const SKY_UP = [0, 1, 0];

// Which part of the sky a pass draws. The frame draws the air and the cloud as two
// passes whenever `skySplitOn`, with `drawCelestial` between them, so the bodies
// end up *under* the clouds rather than painted over them; `SKY_LAYER_ALL` is the
// single pass for where that is not available.
const SKY_LAYER_ALL = 0;
const SKY_LAYER_AIR = 1;
const SKY_LAYER_CLOUD = 2;

// Whether the frame can draw the sky in two layers. The cloud layer has to
// *attenuate* what is already on the screen -- the two bodies and the sun's glare,
// drawn between the passes -- which is raylib's premultiplied blend mode. Without
// that, or without the sky shader at all, the sky stays one pass and the bodies are
// drawn over the clouds, which is how M2b first shipped.
function skySplitOn() {
    return skyShader >= 0 && useSkyShader &&
        typeof rl.beginBlendMode === "function" && rl.BLEND_ALPHA_PREMULTIPLY !== undefined;
}

// Draw one layer of the sky. `cx/cy/cz` is the camera, `tx/ty/tz` its target; the
// forward/right/up basis is rebuilt here and handed to the shader, which turns
// each pixel back into a view ray. `layer` is `SKY_LAYER_*`, the whole sky by
// default.
function drawSky(cx, cy, cz, tx, ty, tz, sw, sh, dt, layer) {
    if (layer === undefined) layer = SKY_LAYER_ALL;
    // The cloud field's clock advances once a frame, in whichever layer is drawn
    // first: both layers read the one `time` uniform, so they agree about where the
    // clouds are.
    if (layer !== SKY_LAYER_CLOUD) skyTime += dt;
    let fx = tx - cx, fy = ty - cy, fz = tz - cz;
    const fl = Math.sqrt(fx * fx + fy * fy + fz * fz) || 1;
    fx /= fl; fy /= fl; fz /= fl;
    let rx = -fz, rz = fx;
    const rlen = Math.sqrt(rx * rx + rz * rz) || 1;
    rx /= rlen; rz /= rlen;
    SKY_CAM[0] = cx; SKY_CAM[1] = cy; SKY_CAM[2] = cz;
    SKY_FWD[0] = fx; SKY_FWD[1] = fy; SKY_FWD[2] = fz;
    SKY_RIGHT[0] = rx; SKY_RIGHT[1] = 0; SKY_RIGHT[2] = rz;
    // up = cross(right, forward), with right.y = 0
    SKY_UP[0] = -rz * fy; SKY_UP[1] = rz * fx - rx * fz; SKY_UP[2] = rx * fy;

    rl.beginShaderMode(skyShader);
    setSkyUniforms(sw, sh, layer);
    // The cloud layer is a *compositing* pass: it returns premultiplied light and
    // the transmittance it leaves behind it, so the blend has to be ONE /
    // ONE-MINUS-SRC-ALPHA. The default alpha blend would not attenuate the bodies
    // under it -- it would draw a second helping of sky over them.
    if (layer === SKY_LAYER_CLOUD) rl.beginBlendMode(rl.BLEND_ALPHA_PREMULTIPLY);
    rl.drawRectangle(0, 0, sw, sh, rl.WHITE);
    if (layer === SKY_LAYER_CLOUD) rl.endBlendMode();
    rl.endShaderMode();
}

// The sky shader's uniforms for one view: the basis above, the screen, and which
// layer of the sky this pass is (`SKY_LAYER_*`).
function setSkyUniforms(sw, sh, layer) {
    // Overcast greys the clouds; night darkens them.
    const lit = 0.12 + 0.88 * skyLight;
    const shadow = 0.09 + 0.40 * skyLight;
    // The high cirrus only shows up once the sky is broken or overcast.
    const cirrus = clamp((cloudiness - 0.25) * 1.2, 0, 0.85);
    if (skyNoise >= 0) {
        rl.setShaderValueTexture(skyShader, skyUniforms.cumulusTexture, skyNoise);
    }
    rl.setShaderValueVector2(skyShader, skyUniforms.screenSize, sw, sh);
    rl.setShaderValueVector3(skyShader, skyUniforms.camPos, SKY_CAM[0], SKY_CAM[1], SKY_CAM[2]);
    rl.setShaderValueVector3(skyShader, skyUniforms.camForward, SKY_FWD[0], SKY_FWD[1], SKY_FWD[2]);
    rl.setShaderValueVector3(skyShader, skyUniforms.camRight, SKY_RIGHT[0], SKY_RIGHT[1], SKY_RIGHT[2]);
    rl.setShaderValueVector3(skyShader, skyUniforms.camUp, SKY_UP[0], SKY_UP[1], SKY_UP[2]);
    rl.setShaderValue(skyShader, skyUniforms.tanHalfFov, Math.tan(55 * 0.5 * Math.PI / 180),
        rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.aspect, sw / sh, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValueVector3(skyShader, skyUniforms.zenithColor,
        channelOf(skyTop, 24), channelOf(skyTop, 16), channelOf(skyTop, 8));
    rl.setShaderValueVector3(skyShader, skyUniforms.horizonColor,
        channelOf(skyBot, 24), channelOf(skyBot, 16), channelOf(skyBot, 8));
    rl.setShaderValueVector3(skyShader, skyUniforms.sunDir,
        LIGHT_DIR[0], LIGHT_DIR[1], LIGHT_DIR[2]);
    rl.setShaderValueVector3(skyShader, skyUniforms.sunTrueDir,
        SUN_DIR[0], SUN_DIR[1], SUN_DIR[2]);
    rl.setShaderValueVector4(skyShader, skyUniforms.sunColor,
        LIGHT_COLOR[0], LIGHT_COLOR[1], LIGHT_COLOR[2], 1.0);
    rl.setShaderValue(skyShader, skyUniforms.cloudiness, cloudiness, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.time, skyTime, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValueVector2(skyShader, skyUniforms.wind, windX * TUNING.sky.speed, windZ * TUNING.sky.speed);
    rl.setShaderValueVector3(skyShader, skyUniforms.cloudLit,
        Math.min(1, lit + 0.10 * skyWarm), Math.min(1, lit + 0.02 * skyWarm),
        Math.min(1, lit - 0.06 * skyWarm));
    rl.setShaderValueVector3(skyShader, skyUniforms.cloudShadow,
        shadow * 0.95, shadow * 0.97, shadow * 1.06);
    rl.setShaderValue(skyShader, skyUniforms.cloudBase, TUNING.sky.cloudBase, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cloudTop, TUNING.sky.cloudTop, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cloudScale, TUNING.sky.scale, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cloudDetail, TUNING.sky.detail, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cloudAbsorb, TUNING.sky.absorb, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cirrus, cirrus, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cirrusHeight, TUNING.sky.cirrusLevel, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.nightDim, 1 - skyLight, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cloudSteps, cloudSteps(), rl.SHADER_UNIFORM_INT);
    rl.setShaderValue(skyShader, skyUniforms.skyLayer, layer, rl.SHADER_UNIFORM_FLOAT);
}
