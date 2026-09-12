// Part 5/12 of the goat scene: the volumetric cloud sky shader.
// ---- sky shader (M5b): volumetric cumulus and cirrus ----------------------
//
// The sky is drawn as one full-screen pass. For each pixel the shader rebuilds
// the camera ray from the camera basis, shades an analytic atmosphere, and then
// raymarches a slab of cloud between `CLOUD_BASE` and `CLOUD_TOP`.
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

const CLOUD_BASE = 5.0;        // world height of the layer bottom
const CLOUD_TOP = 9.5;         // world height of the layer top
const CLOUD_SCALE = 0.055;     // base shape frequency
const CLOUD_DETAIL = 0.35;     // high-frequency edge erosion
const CLOUD_ABSORB = 1.35;     // extinction per unit density
const CIRRUS_LEVEL = 15.0;     // world height of the thin high layer
const CLOUD_SPEED = 0.55;      // how fast the layer drifts with the wind

// March steps per cloud quality setting: low / medium / high.
const CLOUD_STEPS = [6, 12, 22];
const CLOUD_LEVELS = ["low", "medium", "high"];

let skyShader = -1;
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
    "float cloudDensity(vec3 p, vec2 drift, float detailAmt) {",
    "    float y = slabY(p);",
    "    if (y < 0.0 || y > 1.0) return 0.0;",
    // Shear with height (so it is not an extrusion) plus the wind drift.
    "    vec2 q = p.xz * cloudScale + drift + vec2(y * 0.85, y * -0.45);",
    // Domain warp: the cheap trick that turns blobby fBm into billows.
    "    float warp = fbm2(q * 0.5);",
    "    float base = fbm3(q + warp * 0.75);",
    // Soft base, rounded top.
    "    float shape = smoothstep(0.0, 0.22, y) * (1.0 - smoothstep(0.58, 1.0, y));",
    "    float d = base * shape;",
    // Coverage: the threshold falls as cloudiness rises, so the sky goes from a
    // few puffs to solid overcast.
    "    float cover = mix(0.78, 0.14, cloudiness);",
    "    d = max(0.0, d - cover) / max(1.0 - cover, 1e-3);",
    // Erode the edges, but only near a surface -- that is where it reads.
    "    if (detailAmt > 0.001 && d > 0.02 && d < 0.55) {",
    "        d -= detailAmt * fbm2(q * 2.6 + 13.0) * (0.55 - d) * 1.6;",
    "    }",
    "    return clamp(d, 0.0, 1.0);",
    "}",
    // Extinction between a point and the sun: the self-shadow term.
    "float sunTau(vec3 p, vec2 drift) {",
    "    float stepLen = (cloudTop - cloudBase) * 0.28;",
    "    vec3 step = sunDir * stepLen;",
    "    float tau = 0.0;",
    "    for (int i = 0; i < 3; i++) { p += step; tau += cloudDensity(p, drift, 0.0); }",
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
    "    float mu = max(dot(dir, sunDir), 0.0);",
    "    float low = 1.0 - clamp(sunDir.y, 0.0, 1.0);",
    // Forward-scattered glow, wide and warm when the sun is near the horizon.
    "    col += sunColor.rgb * pow(mu, mix(26.0, 3.0, low)) * (0.05 + 0.20 * low) * (1.0 - nightDim);",
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
    "    float cover = mix(0.82, 0.42, cirrus);",
    "    float mask = smoothstep(cover, cover + 0.28, n);",
    "    vec3 c = mix(cloudShadow, cloudLit, 0.55 + 0.45 * clamp(sunDir.y, 0.0, 1.0));",
    "    return mix(behind, c, mask * cirrus * exp(-t * 0.0035) * 0.85);",
    "}",
    // ---- the march ----
    "vec3 cumulus(vec3 behind, vec3 dir) {",
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
    "    float cosT = dot(dir, sunDir);",
    "    float ph = hg(cosT, 0.72) * 0.75 + hg(cosT, -0.28) * 0.40;",
    // No per-pixel jitter: randomising the start offset per pixel is exactly the
    // speckle it was meant to hide, and the exponential steps already stagger the
    // samples.
    "    float trans = 1.0;",
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
    // Forward scattering tints the rim toward the sun colour.
    "            c += cloudLit * sunColor.rgb * ph * sunT * 1.3;",
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
    "    vec3 sky = skyBackground(dir);",
    "    sky = cirrusLayer(dir, sky);",
    "    if (cloudiness > 0.01) sky = cumulus(sky, dir);",
    "    finalColor = vec4(clamp(sky, 0.0, 1.0), 1.0);",
    "}",
].join("\n");

function makeSkyShader() {
    if (typeof rl.loadShaderFromMemory !== "function") return;
    skyShader = rl.loadShaderFromMemory(SKY_VS, SKY_FS);
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
    };
    console.log("sky: shader " + skyShader + ", clouds " + CLOUD_LEVELS[SETTINGS.cloud] +
        " (" + CLOUD_STEPS[SETTINGS.cloud] + " steps)");
}

function channelOf(packed, shift) {
    return ((packed >>> shift) & 255) / 255;
}

// The march steps for the current quality setting.
function cloudLevel() {
    return clamp(Math.round(SETTINGS.cloud), 0, CLOUD_LEVELS.length - 1);
}

function cloudSteps() {
    return CLOUD_STEPS[cloudLevel()];
}

// Draw the whole sky. `cx/cy/cz` is the camera, `tx/ty/tz` its target; the
// forward/right/up basis is rebuilt here and handed to the shader, which turns
// each pixel back into a view ray.
function drawSky(cx, cy, cz, tx, ty, tz, sw, sh, dt) {
    skyTime += dt;
    let fx = tx - cx, fy = ty - cy, fz = tz - cz;
    const fl = Math.sqrt(fx * fx + fy * fy + fz * fz) || 1;
    fx /= fl; fy /= fl; fz /= fl;
    let rx = -fz, rz = fx;
    const rlen = Math.sqrt(rx * rx + rz * rz) || 1;
    rx /= rlen; rz /= rlen;
    // up = cross(right, forward), with right.y = 0
    const ux = -rz * fy, uy = rz * fx - rx * fz, uz = rx * fy;

    // Overcast greys the clouds; night darkens them.
    const lit = 0.12 + 0.88 * skyLight;
    const shadow = 0.09 + 0.40 * skyLight;
    // The high cirrus only shows up once the sky is broken or overcast.
    const cirrus = clamp((cloudiness - 0.25) * 1.2, 0, 0.85);
    rl.beginShaderMode(skyShader);
    rl.setShaderValueVector2(skyShader, skyUniforms.screenSize, sw, sh);
    rl.setShaderValueVector3(skyShader, skyUniforms.camPos, cx, cy, cz);
    rl.setShaderValueVector3(skyShader, skyUniforms.camForward, fx, fy, fz);
    rl.setShaderValueVector3(skyShader, skyUniforms.camRight, rx, 0, rz);
    rl.setShaderValueVector3(skyShader, skyUniforms.camUp, ux, uy, uz);
    rl.setShaderValue(skyShader, skyUniforms.tanHalfFov, Math.tan(55 * 0.5 * Math.PI / 180),
        rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.aspect, sw / sh, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValueVector3(skyShader, skyUniforms.zenithColor,
        channelOf(skyTop, 24), channelOf(skyTop, 16), channelOf(skyTop, 8));
    rl.setShaderValueVector3(skyShader, skyUniforms.horizonColor,
        channelOf(skyBot, 24), channelOf(skyBot, 16), channelOf(skyBot, 8));
    rl.setShaderValueVector3(skyShader, skyUniforms.sunDir,
        LIGHT_DIR[0], LIGHT_DIR[1], LIGHT_DIR[2]);
    rl.setShaderValueVector4(skyShader, skyUniforms.sunColor,
        LIGHT_COLOR[0], LIGHT_COLOR[1], LIGHT_COLOR[2], 1.0);
    rl.setShaderValue(skyShader, skyUniforms.cloudiness, cloudiness, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.time, skyTime, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValueVector2(skyShader, skyUniforms.wind, windX * CLOUD_SPEED, windZ * CLOUD_SPEED);
    rl.setShaderValueVector3(skyShader, skyUniforms.cloudLit,
        Math.min(1, lit + 0.10 * skyWarm), Math.min(1, lit + 0.02 * skyWarm),
        Math.min(1, lit - 0.06 * skyWarm));
    rl.setShaderValueVector3(skyShader, skyUniforms.cloudShadow,
        shadow * 0.95, shadow * 0.97, shadow * 1.06);
    rl.setShaderValue(skyShader, skyUniforms.cloudBase, CLOUD_BASE, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cloudTop, CLOUD_TOP, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cloudScale, CLOUD_SCALE, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cloudDetail, CLOUD_DETAIL, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cloudAbsorb, CLOUD_ABSORB, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cirrus, cirrus, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cirrusHeight, CIRRUS_LEVEL, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.nightDim, 1 - skyLight, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cloudSteps, cloudSteps(), rl.SHADER_UNIFORM_INT);
    rl.drawRectangle(0, 0, sw, sh, rl.WHITE);
    rl.endShaderMode();
}
