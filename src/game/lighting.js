// Part 4/12 of the goat scene: the lit shader, the directional light, and both
// the planar and shadow-map cast shadows.
// ---- lighting (M4): directional light and projected cast shadows ---------
//
// raylib's default shader is unlit, so the scene is lit by a small custom
// program. The goat is a CPU-skinned model: raylib deforms its positions *and*
// normals on the CPU and uploads them, so a normal shader lit per-fragment works
// without the bone matrices a GPU-skinning build would need. `DrawMesh` binds
// the material shader and ignores `beginShaderMode`, so `setModelShader` points
// the goat's materials at the lit program; the terrain (immediate-mode cubes)
// goes through `beginShaderMode`.
//
// Shadows are a planar projection rather than a shadow map: the goat is drawn a
// second time with a vertex shader that squashes every vertex onto the ground
// along the light direction, filled with a translucent dark colour. On the flat
// terrain this reads as a cast shadow that tracks the sun, with none of the
// bias/acne tuning a depth map needs. A depth-map pass (soft edges, self-shadowing)
// can replace it once the render-texture bindings are wired up.

const GROUND_Y = 0.02;          // the plane the shadow is projected onto
const SHADOW_ALPHA = 0.34;      // base opacity of the cast shadow

const LIGHT_DIR = [0.4, 0.8, 0.12];   // unit vector pointing at the active body
const LIGHT_COLOR = [0.9, 0.9, 0.9];  // rgb, already scaled by intensity
const LIGHT_AMBIENT = [0.2, 0.22, 0.3];

let litShader = -1;
let shadowShader = -1;
let litUniforms = null;
let shadowUniforms = null;
let useLighting = true;         // toggled with L
let lightingText = "cube shader";

const LIT_VS = [
    "#version 330",
    "in vec3 vertexPosition;",
    "in vec2 vertexTexCoord;",
    "in vec3 vertexNormal;",
    "in vec4 vertexColor;",
    "uniform mat4 mvp;",
    "uniform mat4 matModel;",
    "uniform mat4 matNormal;",
    "out vec2 fragTexCoord;",
    "out vec4 fragColor;",
    "out vec3 fragWorldPos;",
    "out vec3 fragNormal;",
    "void main() {",
    "    vec4 world = matModel * vec4(vertexPosition, 1.0);",
    "    fragWorldPos = world.xyz;",
    "    fragNormal = normalize(mat3(matNormal) * vertexNormal);",
    "    fragTexCoord = vertexTexCoord;",
    "    fragColor = vertexColor;",
    "    gl_Position = mvp * vec4(vertexPosition, 1.0);",
    "}",
].join("\n");

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
    "    finalColor = vec4(color, texel.a);",
    "}",
].join("\n");

const SHADOW_VS = [
    "#version 330",
    "in vec3 vertexPosition;",
    "uniform mat4 matModel;",
    "uniform mat4 matView;",
    "uniform mat4 matProjection;",
    "uniform vec3 lightDir;",
    "uniform float groundY;",
    "uniform float shadowOn;",
    "void main() {",
    "    vec3 world = (matModel * vec4(vertexPosition, 1.0)).xyz;",
    "    if (shadowOn > 0.5 && lightDir.y > 0.06 && world.y > groundY) {",
    "        float t = (world.y - groundY) / lightDir.y;",
    "        vec3 projected = vec3(world.x - lightDir.x*t, groundY, world.z - lightDir.z*t);",
    "        gl_Position = matProjection * matView * vec4(projected, 1.0);",
    "    } else {",
    "        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);",
    "    }",
    "}",
].join("\n");

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
    litUniforms = {
        lightDir: rl.getShaderLocation(litShader, "lightDir"),
        lightColor: rl.getShaderLocation(litShader, "lightColor"),
        ambientColor: rl.getShaderLocation(litShader, "ambientColor"),
        camPos: rl.getShaderLocation(litShader, "camPos"),
    };
    shadowUniforms = shadowShader >= 0 ? {
        lightDir: rl.getShaderLocation(shadowShader, "lightDir"),
        groundY: rl.getShaderLocation(shadowShader, "groundY"),
        shadowOn: rl.getShaderLocation(shadowShader, "shadowOn"),
        shadowAlpha: rl.getShaderLocation(shadowShader, "shadowAlpha"),
    } : null;
    if (haveModel) rl.setModelShader(model, litShader);
    makeShadowMap();
    console.log("lighting: lit shader " + litShader + ", shadow shader " + shadowShader);
}

// Refresh the light direction and colours from the day/night clock. The sun and
// moon are the same two bodies `drawCelestial` arcs across the sky, so the light
// and the visible disc always agree.
function updateLight() {
    const a = ((worldTime - 6) / 12) * Math.PI;   // 0 at 06:00, PI at 18:00
    const sunX = Math.cos(a);
    const sunY = Math.sin(a);
    const tilt = 0.18;                            // push light off the XZ plane
    const day = sunY > 0.02;
    let lx = sunX, ly = sunY, lz = tilt;
    if (!day) {
        lx = -sunX; ly = -sunY; lz = -tilt;       // the moon takes over
    }
    const len = Math.sqrt(lx * lx + ly * ly + lz * lz) || 1;
    LIGHT_DIR[0] = lx / len;
    LIGHT_DIR[1] = ly / len;
    LIGHT_DIR[2] = lz / len;

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

function setLitUniforms(cx, cy, cz) {
    rl.setShaderValueVector3(litShader, litUniforms.lightDir,
        LIGHT_DIR[0], LIGHT_DIR[1], LIGHT_DIR[2]);
    rl.setShaderValueVector4(litShader, litUniforms.lightColor,
        LIGHT_COLOR[0], LIGHT_COLOR[1], LIGHT_COLOR[2], 1.0);
    rl.setShaderValueVector4(litShader, litUniforms.ambientColor,
        LIGHT_AMBIENT[0], LIGHT_AMBIENT[1], LIGHT_AMBIENT[2], 1.0);
    rl.setShaderValueVector3(litShader, litUniforms.camPos, cx, cy, cz);
    if (litShadow !== null) {
        setMatrixOn(litShader, litShadow.lightVP, LIGHT_MATRIX);
        rl.setShaderValueVector2(litShader, litShadow.texel, 1 / SHADOW_SIZE, 1 / SHADOW_SIZE);
        rl.setShaderValue(litShader, litShadow.bias, SHADOW_BIAS, rl.SHADER_UNIFORM_FLOAT);
        rl.setShaderValue(litShader, litShadow.strength, shadowStrengthNow, rl.SHADER_UNIFORM_FLOAT);
        // The terrain goes through the batch path, which never sees the model's
        // material map 1, so bind the shadow sampler explicitly for it.
        if (shadowStrengthNow > 0.001 && shadowSamplerLoc >= 0) {
            rl.setShaderValueTexture(litShader, shadowSamplerLoc, shadowColor);
        }
    }
}

function setShadowUniforms() {
    rl.setShaderValueVector3(shadowShader, shadowUniforms.lightDir,
        LIGHT_DIR[0], LIGHT_DIR[1], LIGHT_DIR[2]);
    rl.setShaderValue(shadowShader, shadowUniforms.groundY, GROUND_Y, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(shadowShader, shadowUniforms.shadowOn, 1.0, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(shadowShader, shadowUniforms.shadowAlpha,
        SHADOW_ALPHA * (0.35 + 0.65 * skyLight), rl.SHADER_UNIFORM_FLOAT);
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
// shader does not otherwise use. The terrain (batch path) has no materials, so it
// is handed the sampler with `setShaderValueTexture` instead.

const SHADOW_OFF = 0;
const SHADOW_PLANAR = 1;
const SHADOW_MAP = 2;

const SHADOW_SIZE = 1024;
const SHADOW_HALF = 7.0;      // half-width of the light's box, in world units
const SHADOW_DIST = 22.0;     // how far the light sits from its centre
const SHADOW_NEAR = 1.0;
const SHADOW_FAR = 48.0;
const SHADOW_BIAS = 0.0018;
const SHADOW_STRENGTH = 0.85; // how dark a fully-shadowed sample gets
const SHADOW_MAP_INDEX = 1;   // MATERIAL_MAP_METALNESS -> sampler `texture1`
// The map only spans a SHADOW_HALF box around the goat, so every tuft inside it
// is exactly the grass shadow the lit shader can sample (anything outside would
// project to out-of-range uv and be ignored). The small margin catches tufts
// just outside whose short shadow leans into the box.
const SHADOW_GRASS_HALF = SHADOW_HALF + 2.0;
const SHADOW_GRASS_CULL2 = SHADOW_GRASS_HALF * SHADOW_GRASS_HALF;

let shadowMapReady = false;
let shadowMode = SHADOW_PLANAR;
let shadowRT = -1;
let shadowColor = -1;
let depthShader = -1;
let depthUniforms = null;
let litShadow = null;         // locations of the lit shader's shadow uniforms
let shadowSamplerLoc = -1;
const LIGHT_MATRIX = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
let shadowStrengthNow = 0;

const DEPTH_VS = [
    "#version 330",
    "in vec3 vertexPosition;",
    "uniform mat4 matModel;",
    "uniform mat4 lightVP;",
    "out vec4 vClip;",
    "void main() {",
    "    vClip = lightVP * matModel * vec4(vertexPosition, 1.0);",
    "    gl_Position = vClip;",
    "}",
].join("\n");

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

// Orthographic world -> light-clip matrix: x/y span a SHADOW_HALF box around
// (cx, cy, cz), z runs SHADOW_NEAR..SHADOW_FAR along the light direction, with
// the light at distance SHADOW_DIST.
//
// The 16 values are the matrix in COLUMN-major order, which is what
// `SetShaderValueMatrix` uploads and GLSL reads: the R/U/L basis vectors are the
// columns and the translation lands in the last four. Listing them row-major
// instead transposes the basis, which leaves the box pinned near the world
// origin -- the shadow then only appears while the goat is still near spawn and
// fades out (and comes back) as it walks away and returns.
function buildLightMatrix(cx, cy, cz) {
    const L = unit3(LIGHT_DIR);
    const up = Math.abs(L[1]) > 0.95 ? [0, 0, 1] : [0, 1, 0];
    const R = unit3(cross3(up, L));
    const U = cross3(L, R);
    const k = 2 / (SHADOW_FAR - SHADOW_NEAR);
    const dL = dot3([cx, cy, cz], L);
    const dR = dot3([cx, cy, cz], R);
    const dU = dot3([cx, cy, cz], U);
    const t2 = k*(SHADOW_DIST + dL) - k*SHADOW_NEAR - 1;
    return [
        R[0]/SHADOW_HALF, U[0]/SHADOW_HALF, -k*L[0], 0,
        R[1]/SHADOW_HALF, U[1]/SHADOW_HALF, -k*L[1], 0,
        R[2]/SHADOW_HALF, U[2]/SHADOW_HALF, -k*L[2], 0,
        -dR/SHADOW_HALF, -dU/SHADOW_HALF, t2, 1,
    ];
}

function setMatrixOn(shader, loc, m) {
    rl.setShaderValueMatrix(shader, loc,
        m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7],
        m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15]);
}

// Build the render texture and depth program. Needs the window (GL) and the lit
// shader already compiled.
function makeShadowMap() {
    if (typeof rl.loadRenderTexture !== "function" || typeof rl.setModelTexture !== "function" ||
        typeof rl.setShaderValueMatrix !== "function" || typeof rl.setShaderValueTexture !== "function") {
        console.log("shadow map: engine lacks the bindings - keeping the planar shadow");
        return;
    }
    shadowSamplerLoc = rl.getShaderLocation(litShader, "texture1");
    litShadow = {
        lightVP: rl.getShaderLocation(litShader, "lightVP"),
        texel: rl.getShaderLocation(litShader, "shadowTexel"),
        bias: rl.getShaderLocation(litShader, "shadowBias"),
        strength: rl.getShaderLocation(litShader, "shadowStrength"),
    };
    shadowRT = rl.loadRenderTexture(SHADOW_SIZE, SHADOW_SIZE);
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
    depthUniforms = { lightVP: rl.getShaderLocation(depthShader, "lightVP") };
    if (haveModel) rl.setModelTexture(model, SHADOW_MAP_INDEX, shadowColor);
    shadowMapReady = true;
    shadowMode = SHADOW_MAP;
    console.log("shadow map: rt " + shadowRT + " color " + shadowColor +
        " depth shader " + depthShader + " sampler loc " + shadowSamplerLoc);
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
    shadowStrengthNow = SHADOW_STRENGTH * low * (0.35 + 0.65 * skyLight);
}

// Render the goat and the near grass from the light's point of view into the
// shadow texture.
function renderShadowMap() {
    if (!shadowMapReady || !haveModel || shadowStrengthNow <= 0.001) return;
    rl.beginTextureMode(shadowRT);
    rl.clearBackground(rl.color(0, 0, 0, 255));
    rl.beginMode3D(0, 0, 0, goat.px, 0, goat.pz, 45);
    // Grass casts too. It is immediate-mode geometry, so unlike the model it goes
    // through the batch path with `beginShaderMode`; drawing it first lets the
    // goat's depth win wherever the two overlap. The tufts are swayed by the
    // same `drawTufts` the visible pass uses, so the shadow tracks the wind.
    rl.beginShaderMode(depthShader);
    setMatrixOn(depthShader, depthUniforms.lightVP, LIGHT_MATRIX);
    drawTufts(goat, rl.WHITE, SHADOW_GRASS_CULL2, SHADOW_GRASS_CULL2);
    rl.endShaderMode();
    rl.setModelShader(model, depthShader);
    // Detach the shadow target while it is the framebuffer's own attachment.
    rl.setModelTexture(model, SHADOW_MAP_INDEX, -1);
    setMatrixOn(depthShader, depthUniforms.lightVP, LIGHT_MATRIX);
    drawModelGoat(goat, rl.WHITE);
    drawBotsShadow();
    rl.setModelTexture(model, SHADOW_MAP_INDEX, shadowColor);
    rl.setModelShader(model, litShader);
    rl.endMode3D();
    rl.endTextureMode();
}

