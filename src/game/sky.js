// Part 5/12 of the goat scene: the 2.5D procedural cloud sky shader.
// ---- sky shader (M5): 2.5D procedural clouds -----------------------------
//
// The sky is drawn as one full-screen pass instead of a gradient plus cloud
// billboards. For each pixel the shader rebuilds the camera ray from the camera
// basis, samples the gradient, and looks up animated value-noise fBm on a flat
// cloud layer -- the `radial.divide by dir.y` projection is what compresses the
// clouds toward the horizon, i.e. the parallax. Clouds are shaded by comparing
// the density with a sample taken toward the sun, so they brighten on the sun's
// side and pick up its dawn/dusk color. `B` falls back to the billboard clouds.

const CLOUD_HEIGHT = 6.0;      // world units of the cloud layer
const CLOUD_SCALE = 0.055;     // noise frequency
const CLOUD_SHARP = 0.22;      // softness of the coverage edge
const CLOUD_SPEED = 0.55;      // how fast the layer drifts

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
    "uniform vec2 screenSize;",
    "uniform vec3 camPos;",
    "uniform vec3 camForward;",
    "uniform vec3 camRight;",
    "uniform vec3 camUp;",
    "uniform float tanHalfFov;",
    "uniform float aspect;",
    "uniform vec3 zenithColor;",
    "uniform vec3 horizonColor;",
    "uniform vec3 sunDir;",
    "uniform vec4 sunColor;",
    "uniform float cloudiness;",
    "uniform float time;",
    "uniform vec2 wind;",
    "uniform vec3 cloudLit;",
    "uniform vec3 cloudShadow;",
    "uniform float cloudHeight;",
    "uniform float cloudScale;",
    "uniform float cloudSharp;",
    "uniform float nightDim;",
    "float hash21(vec2 p) { p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }",
    "float vnoise(vec2 p) {",
    "    vec2 i = floor(p); vec2 f = fract(p);",
    "    vec2 u = f * f * (3.0 - 2.0 * f);",
    "    return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),",
    "               mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);",
    "}",
    "float fbm(vec2 p) {",
    "    float v = 0.0; float amp = 0.5;",
    "    for (int i = 0; i < 4; i++) { v += amp * vnoise(p); p = p * 2.03 + 11.7; amp *= 0.5; }",
    "    return v;",
    "}",
    "void main() {",
    "    vec2 uv = gl_FragCoord.xy / screenSize;",
    "    vec2 ndc = vec2(uv.x * 2.0 - 1.0, uv.y * 2.0 - 1.0);",
    "    vec3 dir = normalize(camForward + camRight * (ndc.x * tanHalfFov * aspect)",
    "                                       + camUp * (ndc.y * tanHalfFov));",
    "    float h = dir.y;",
    "    vec3 sky = mix(horizonColor, zenithColor, pow(clamp(h, 0.0, 1.0), 0.55));",
    "    if (cloudiness > 0.01 && h > 0.0) {",
    "        float t = cloudHeight / max(h, 0.035);",
    "        vec2 base = (camPos.xz + dir.xz * t) * cloudScale;",
    "        vec2 drift = wind * (time * 0.01 * 0.55);",
    "        vec2 p = base + drift;",
    "        float n = fbm(p);",
    "        float threshold = mix(0.72, 0.28, cloudiness);",
    "        float d = smoothstep(threshold, threshold + cloudSharp, n);",
    "        float n2 = fbm(p + normalize(sunDir.xz + vec2(1e-4)) * 0.06);",
    "        float d2 = smoothstep(threshold, threshold + cloudSharp, n2);",
    "        float lit = clamp(0.45 + (d - d2) * 3.5 + 0.35 * max(sunDir.y, 0.0), 0.0, 1.0);",
    "        vec3 cloud = mix(cloudShadow, cloudLit, lit);",
    "        float fade = smoothstep(0.0, 0.16, h);",
    "        sky = mix(sky, cloud, d * fade);",
    "    }",
    "    float sunAmt = max(dot(dir, sunDir), 0.0);",
    "    sky += sunColor.rgb * pow(sunAmt, 10.0) * 0.10 * (1.0 - nightDim * 0.5);",
    "    finalColor = vec4(sky, 1.0);",
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
        cloudHeight: rl.getShaderLocation(skyShader, "cloudHeight"),
        cloudScale: rl.getShaderLocation(skyShader, "cloudScale"),
        cloudSharp: rl.getShaderLocation(skyShader, "cloudSharp"),
        nightDim: rl.getShaderLocation(skyShader, "nightDim"),
    };
    console.log("sky: shader " + skyShader);
}

function channelOf(packed, shift) {
    return ((packed >>> shift) & 255) / 255;
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
    rl.setShaderValue(skyShader, skyUniforms.cloudHeight, CLOUD_HEIGHT, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cloudScale, CLOUD_SCALE, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.cloudSharp, CLOUD_SHARP, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(skyShader, skyUniforms.nightDim, 1 - skyLight, rl.SHADER_UNIFORM_FLOAT);
    rl.drawRectangle(0, 0, sw, sh, rl.WHITE);
    rl.endShaderMode();
}

