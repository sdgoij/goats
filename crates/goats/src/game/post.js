// ---- anti-aliasing -------------------------------------------------------
//
// The raylib facade opens the window with `FLAG_WINDOW_HIGHDPI` and overwrites
// any config flags set before it, so the scene cannot ask GLFW for MSAA. The
// frame instead renders into an off-screen target and resolves it with FXAA.
// HUD and menus are drawn after the resolve, so text stays crisp.
//
// The harness records texture modes rather than switching targets, so it keeps
// the direct path: `harnessObserve` is the one global only the harness defines.

let fxaaShader = -1;
let fxaaResolution = -1;
let sceneTarget = -1;
let sceneTargetColor = -1;
let sceneTargetW = 0;
let sceneTargetH = 0;
let useAA = SETTINGS.aa;        // the running answer; `SETTINGS.aa` is the wish

const POST_VS = [
    "#version 330",
    "in vec3 vertexPosition;",
    "in vec2 vertexTexCoord;",
    "uniform mat4 mvp;",
    "out vec2 fragTexCoord;",
    "void main() {",
    "    fragTexCoord = vertexTexCoord;",
    "    gl_Position = mvp * vec4(vertexPosition, 1.0);",
    "}",
].join("\n");

// FXAA's luma edge test, direction estimate and the two-tap blend. The
// constants are the console-quality set: 0.0312 is the absolute threshold and
// 0.125 the relative one, which is what keeps flat sky and grass untouched.
const POST_FS = [
    "#version 330",
    "in vec2 fragTexCoord;",
    "uniform sampler2D texture0;",
    "uniform vec2 resolution;",
    "out vec4 finalColor;",
    "float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }",
    "void main() {",
    "    vec2 texel = 1.0 / resolution;",
    "    vec3 nw = texture(texture0, fragTexCoord + vec2(-1.0, -1.0) * texel).rgb;",
    "    vec3 ne = texture(texture0, fragTexCoord + vec2( 1.0, -1.0) * texel).rgb;",
    "    vec3 sw = texture(texture0, fragTexCoord + vec2(-1.0,  1.0) * texel).rgb;",
    "    vec3 se = texture(texture0, fragTexCoord + vec2( 1.0,  1.0) * texel).rgb;",
    "    vec3 m  = texture(texture0, fragTexCoord).rgb;",
    "    float lnw = luma(nw), lne = luma(ne), lsw = luma(sw), lse = luma(se), lm = luma(m);",
    "    float lmin = min(lm, min(min(lnw, lne), min(lsw, lse)));",
    "    float lmax = max(lm, max(max(lnw, lne), max(lsw, lse)));",
    "    float range = lmax - lmin;",
    "    if (range < max(0.0312, lmax * 0.125)) {",
    "        finalColor = vec4(m, 1.0);",
    "        return;",
    "    }",
    "    vec2 dir = vec2(-((lnw + lne) - (lsw + lse)), ((lnw + lsw) - (lne + lse)));",
    "    float reduce = max((lnw + lne + lsw + lse) * 0.03125, 0.0078125);",
    "    float rcp = 1.0 / (min(abs(dir.x), abs(dir.y)) + reduce);",
    "    dir = clamp(dir * rcp, vec2(-8.0), vec2(8.0)) * texel;",
    "    vec3 a = 0.5 * (texture(texture0, fragTexCoord + dir * (1.0 / 3.0 - 0.5)).rgb +",
    "                    texture(texture0, fragTexCoord + dir * (2.0 / 3.0 - 0.5)).rgb);",
    "    vec3 b = a * 0.5 + 0.25 * (texture(texture0, fragTexCoord + dir * -0.5).rgb +",
    "                               texture(texture0, fragTexCoord + dir * 0.5).rgb);",
    "    float lb = luma(b);",
    "    finalColor = vec4((lb < lmin || lb > lmax) ? a : b, 1.0);",
    "}",
].join("\n");

function aaSupported() {
    return typeof harnessObserve === "undefined" &&
        typeof rl.loadRenderTexture === "function" &&
        typeof rl.beginTextureMode === "function" &&
        typeof rl.endTextureMode === "function" &&
        typeof rl.renderTextureColor === "function" &&
        typeof rl.drawTexture === "function" &&
        typeof rl.loadShaderFromMemory === "function";
}

function makePost() {
    if (!aaSupported()) return;
    fxaaShader = loadGlsl(POST_VS, POST_FS);
    if (fxaaShader < 0 || !rl.isShaderValid(fxaaShader)) {
        // A headless or stripped `rl` answers -1 here; that is a fallback, not a
        // scene failure, so it is not logged as one.
        fxaaShader = -1;
        return;
    }
    fxaaResolution = rl.getShaderLocation(fxaaShader, "resolution");
}

// The scene target is the screen at 1:1, remade when full-screen or a resize
// changes the drawable. Returns whether the frame should render into it.
function sceneTargetEnsure() {
    if (!useAA || fxaaShader < 0 || !aaSupported()) return false;
    if (sceneTarget >= 0 && sceneTargetW === screenW && sceneTargetH === screenH) return true;
    if (sceneTarget >= 0 && typeof rl.unloadRenderTexture === "function") {
        rl.unloadRenderTexture(sceneTarget);
    }
    sceneTarget = rl.loadRenderTexture(screenW, screenH);
    if (sceneTarget < 0 ||
        (typeof rl.isRenderTextureValid === "function" && !rl.isRenderTextureValid(sceneTarget))) {
        sceneTarget = -1;
        sceneTargetColor = -1;
        sceneTargetW = 0;
        sceneTargetH = 0;
        console.log("post: no render texture for FXAA - drawing the scene directly");
        return false;
    }
    sceneTargetColor = rl.renderTextureColor(sceneTarget);
    // The FXAA taps land between texels; point sampling would turn them into
    // the same pixel and leave the aliasing they are meant to remove.
    if (typeof rl.setTextureFilter === "function" &&
        typeof rl.TEXTURE_FILTER_BILINEAR === "number") {
        rl.setTextureFilter(sceneTargetColor, rl.TEXTURE_FILTER_BILINEAR);
    }
    sceneTargetW = screenW;
    sceneTargetH = screenH;
    return true;
}

// Resolve the target onto the screen. The negative source height is raylib's
// flip: a render texture's rows run bottom-up relative to the window.
function drawSceneAA() {
    if (sceneTarget >= 0 && sceneTargetColor >= 0 && fxaaShader >= 0) {
        const blend = typeof rl.beginBlendMode === "function" &&
            typeof rl.endBlendMode === "function";
        if (blend) rl.beginBlendMode(rl.BLEND_ALPHA);
        rl.beginShaderMode(fxaaShader);
        if (fxaaResolution >= 0) {
            rl.setShaderValueVector2(fxaaShader, fxaaResolution, screenW, screenH);
        }
        rl.drawTexture(sceneTargetColor, 0, 0, screenW, -screenH,
            0, 0, screenW, screenH, 1.0);
        rl.endShaderMode();
        if (blend) rl.endBlendMode();
    }
}
