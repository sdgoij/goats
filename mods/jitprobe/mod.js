// A throwaway measurement fixture, not a feature.
//
// The scene's `perf probe` says the same loop costs ~10 ns/iteration in its own
// function and ~600 ns in a function that touches an engine call, and that a
// loop reading a module-level `const` (every hot loop in the scene) stays in the
// hundreds of ns. That points at the engine's compile gates rather than at the
// arithmetics, so this mod measures the gates directly, in the running client,
// with no rebuild: `jitprobe` from the console prints one row per body shape.
//
// Each row is a top-level function measured over N iterations after a warm-up
// call, so the JIT has had its consultation. ns/iter is comparable across rows
// because every row does the same amount of arithmetic per iteration (one add,
// one multiply, one loop increment).
//
// Read it as: ~10 ns/iter = machine code, ~150-700 ns/iter = the interpreter.

const N = 200000;

// Module-level (wrapper-scope) state: a read of these from a nested function is
// an outer-binding read, which is the shape the scene's own `TUNING` reads have.
const SCALAR = 1.5;
const NESTED = { cfg: { radius: 1.5 } };

// Two real functions to call: one is a leaf, the other is not (it reads a
// module-level binding and calls nothing else).
function gAdd(x) { return x + 1.5; }
function gAddDeep(x) { return x + SCALAR; }

// ---- the variants ---------------------------------------------------------

function vArith(n) {                    // params only, no calls, no outer reads
    let s = 0;
    for (let i = 0; i < n; i++) s += i * 3;
    return s;
}

function vOuterRead(n) {                // one outer (wrapper-scope) read
    let s = 0;
    for (let i = 0; i < n; i++) s += i * 3 + SCALAR;
    return s;
}

function vOuterChain(n) {               // one outer read, then two member reads
    let s = 0;
    for (let i = 0; i < n; i++) s += i * 3 + NESTED.cfg.radius;
    return s;
}

function vGlobalRead(n) {               // a genuine global read (`Math`)
    let s = 0;
    for (let i = 0; i < n; i++) s += i * 3 + Math.PI;
    return s;
}

function vCallOuter(n) {                // a call to a module-level function
    let s = 0;
    for (let i = 0; i < n; i++) s += gAddDeep(i);
    return s;
}

function vCallParam(n, f) {             // a call to a *parameter* function
    let s = 0;
    for (let i = 0; i < n; i++) s += f(i);
    return s;
}

function vSqrtGlobal(n) {               // a global read AND a builtin call
    let s = 0;
    for (let i = 0; i < n; i++) s += Math.sqrt(i + 1);
    return s;
}

function vPow(n) {                      // the same value with `** 0.5`
    let s = 0;
    for (let i = 0; i < n; i++) s += (i + 1) ** 0.5;
    return s;
}

function vContinue(n) {                 // a `continue` in the loop
    let s = 0;
    for (let i = 0; i < n; i++) {
        if ((i & 1) === 1) continue;
        s += i * 3;
    }
    return s;
}

function vIfElse(n) {                   // the same, without `continue`
    let s = 0;
    for (let i = 0; i < n; i++) {
        if ((i & 1) === 1) s += 0;
        else s += i * 3;
    }
    return s;
}

function vNested(n) {                   // nested loops, member reads/writes
    const list = NESTED_LIST;
    let s = 0;
    for (let i = 0; i < n; i++) {
        for (let j = 0; j < 7; j++) { s += list[j].x; list[j].x += 0.5; }
    }
    return s;
}

// ---- the two collision shapes, straight from `bots.js` --------------------

// The shape as the scene has it: outer reads, `Math.sqrt`, `continue`.
function collideCurrent(bots, gx, gz) {
    const rad = NESTED.cfg.radius;
    const pr = rad * SCALAR;
    for (let pass = 0; pass < 2; pass++) {
        for (let i = 0; i < bots.length; i++) {
            const b = bots[i];
            const rr = pr + rad * b.spec.scale;
            const dx = b.x - gx;
            const dz = b.z - gz;
            const d2 = dx * dx + dz * dz;
            if (d2 >= rr * rr) continue;
            if (d2 <= 1e-4) {
                b.x = gx + rr;
            } else {
                const d = Math.sqrt(d2);
                const push = (rr - d) / d;
                b.x += dx * push;
                b.z += dz * push;
            }
        }
        for (let i = 0; i < bots.length; i++) {
            const a = bots[i];
            const ar = rad * a.spec.scale;
            for (let j = i + 1; j < bots.length; j++) {
                const b = bots[j];
                const rr = ar + rad * b.spec.scale;
                const dx = b.x - a.x;
                const dz = b.z - a.z;
                const d2 = dx * dx + dz * dz;
                if (d2 >= rr * rr || d2 <= 1e-4) continue;
                const d = Math.sqrt(d2);
                const push = (rr - d) / (2 * d);
                a.x -= dx * push;
                a.z -= dz * push;
                b.x += dx * push;
                b.z += dz * push;
            }
        }
    }
    return bots;
}

// The proposed shape: every outer value is a parameter, `** 0.5` instead of the
// `Math.sqrt` call, `if/else` instead of `continue`.
function collideLeaf(bots, count, gx, gz, rad, pr) {
    for (let pass = 0; pass < 2; pass++) {
        for (let i = 0; i < count; i++) {
            const b = bots[i];
            const rr = pr + rad * b.spec.scale;
            const dx = b.x - gx;
            const dz = b.z - gz;
            const d2 = dx * dx + dz * dz;
            if (d2 < rr * rr) {
                if (d2 <= 1e-4) {
                    b.x = gx + rr;
                } else {
                    const d = d2 ** 0.5;
                    const push = (rr - d) / d;
                    b.x += dx * push;
                    b.z += dz * push;
                }
            }
        }
        for (let i = 0; i < count; i++) {
            const a = bots[i];
            const ar = rad * a.spec.scale;
            for (let j = i + 1; j < count; j++) {
                const b = bots[j];
                const rr = ar + rad * b.spec.scale;
                const dx = b.x - a.x;
                const dz = b.z - a.z;
                const d2 = dx * dx + dz * dz;
                if (d2 < rr * rr && d2 > 1e-4) {
                    const d = d2 ** 0.5;
                    const push = (rr - d) / (2 * d);
                    a.x -= dx * push;
                    a.z -= dz * push;
                    b.x += dx * push;
                    b.z += dz * push;
                }
            }
        }
    }
    return bots;
}

// ---- the structural ladder -------------------------------------------------
//
// Every rung below does the *same* body executions as `collideLeaf` (2 passes x
// (7 player pairs + 21 bot pairs) = 56) and takes nothing but parameters, so the
// ns/iter column is comparable across rungs and against `nested-7`. `collideLeaf`
// runs interpreted despite having no global read, no call and no `continue`, so
// one rung at a time adds structure back until the interpretation appears.

// One player-vs-goat step, straight from `collideLeaf`.
function step1(list, i, gx, gz, rad, pr) {
    const b = list[i];
    const rr = pr + rad * b.spec.scale;
    const dx = b.x - gx;
    const dz = b.z - gz;
    const d2 = dx * dx + dz * dz;
    if (d2 < rr * rr) {
        if (d2 <= 1e-4) {
            b.x = gx + rr;
        } else {
            const d = d2 ** 0.5;
            const push = (rr - d) / d;
            b.x += dx * push;
            b.z += dz * push;
        }
    }
}

// One bot-vs-bot step.
function step2(list, i, j, rad, pr) {
    const a = list[i];
    const b = list[j];
    const rr = rad * a.spec.scale + rad * b.spec.scale;
    const dx = b.x - a.x;
    const dz = b.z - a.z;
    const d2 = dx * dx + dz * dz;
    if (d2 < rr * rr && d2 > 1e-4) {
        const d = d2 ** 0.5;
        const push = (rr - d) / (2 * d);
        a.x -= dx * push;
        a.z -= dz * push;
        b.x += dx * push;
        b.z += dz * push;
    }
}

// r1: one flat loop of player steps, nothing nested.
function r1(list, count, gx, gz, rad, pr) {
    for (let i = 0; i < count; i++) {
        const b = list[i];
        const rr = pr + rad * b.spec.scale;
        const dx = b.x - gx;
        const dz = b.z - gz;
        const d2 = dx * dx + dz * dz;
        if (d2 < rr * rr && d2 > 1e-4) {
            const d = d2 ** 0.5;
            const push = (rr - d) / d;
            b.x += dx * push;
            b.z += dz * push;
        }
    }
    return list;
}

// r2: two flat loops back to back.
function r2(list, count, gx, gz, rad, pr) {
    for (let i = 0; i < count; i++) step1(list, i, gx, gz, rad, pr);
    for (let i = 0; i < count - 1; i++) step2(list, i, i + 1, rad, pr);
    return list;
}

// r3: the pass loop around the two flat loops, body still calls helpers.
function r3(list, count, gx, gz, rad, pr) {
    for (let pass = 0; pass < 2; pass++) {
        for (let i = 0; i < count; i++) step1(list, i, gx, gz, rad, pr);
        for (let i = 0; i < count - 1; i++) step2(list, i, i + 1, rad, pr);
    }
    return list;
}

// r4: the same three levels, loops inline, body identical to `collideLeaf`.
function r4(list, count, gx, gz, rad, pr) {
    for (let pass = 0; pass < 2; pass++) {
        for (let i = 0; i < count; i++) step1(list, i, gx, gz, rad, pr);
        for (let i = 0; i < count; i++) {
            const a = list[i];
            for (let j = i + 1; j < count; j++) {
                step2(list, i, j, rad, pr);
            }
        }
    }
    return list;
}

// r5: r4 with the inner pair loop inline (no helper call).
function r5(list, count, gx, gz, rad, pr) {
    for (let pass = 0; pass < 2; pass++) {
        for (let i = 0; i < count; i++) step1(list, i, gx, gz, rad, pr);
        for (let i = 0; i < count; i++) {
            const a = list[i];
            for (let j = i + 1; j < count; j++) {
                const b = list[j];
                const rr = rad * a.spec.scale + rad * b.spec.scale;
                const dx = b.x - a.x;
                const dz = b.z - a.z;
                const d2 = dx * dx + dz * dz;
                if (d2 < rr * rr && d2 > 1e-4) {
                    const d = d2 ** 0.5;
                    const push = (rr - d) / (2 * d);
                    a.x -= dx * push;
                    a.z -= dz * push;
                    b.x += dx * push;
                    b.z += dz * push;
                }
            }
        }
    }
    return list;
}

// r6: r5 without the `const` declarations inside the inner loop body.
function r6(list, count, gx, gz, rad, pr) {
    for (let pass = 0; pass < 2; pass++) {
        for (let i = 0; i < count; i++) step1(list, i, gx, gz, rad, pr);
        for (let i = 0; i < count; i++) {
            const a = list[i];
            const ar = rad * a.spec.scale;
            for (let j = i + 1; j < count; j++) {
                const rr = ar + rad * list[j].spec.scale;
                const dx = list[j].x - a.x;
                const dz = list[j].z - a.z;
                const d2 = dx * dx + dz * dz;
                if (d2 < rr * rr && d2 > 1e-4) {
                    const d = d2 ** 0.5;
                    const push = (rr - d) / (2 * d);
                    a.x -= dx * push;
                    a.z -= dz * push;
                    list[j].x += dx * push;
                    list[j].z += dz * push;
                }
            }
        }
    }
    return list;
}

// r7: r5 with the inner loop bound independent of the outer index.
function r7(list, count, gx, gz, rad, pr) {
    for (let pass = 0; pass < 2; pass++) {
        for (let i = 0; i < count; i++) step1(list, i, gx, gz, rad, pr);
        for (let i = 0; i < count; i++) {
            const a = list[i];
            for (let j = 0; j < count; j++) {
                if (j > i) {
                    const b = list[j];
                    const rr = rad * a.spec.scale + rad * b.spec.scale;
                    const dx = b.x - a.x;
                    const dz = b.z - a.z;
                    const d2 = dx * dx + dz * dz;
                    if (d2 < rr * rr && d2 > 1e-4) {
                        const d = d2 ** 0.5;
                        const push = (rr - d) / (2 * d);
                        a.x -= dx * push;
                        a.z -= dz * push;
                        b.x += dx * push;
                        b.z += dz * push;
                    }
                }
            }
        }
    }
    return list;
}

// r8: r5 with the pass loop unrolled.
function r8(list, count, gx, gz, rad, pr) {
    for (let i = 0; i < count; i++) step1(list, i, gx, gz, rad, pr);
    for (let i = 0; i < count; i++) {
        const a = list[i];
        for (let j = i + 1; j < count; j++) {
            const b = list[j];
            const rr = rad * a.spec.scale + rad * b.spec.scale;
            const dx = b.x - a.x;
            const dz = b.z - a.z;
            const d2 = dx * dx + dz * dz;
            if (d2 < rr * rr && d2 > 1e-4) {
                const d = d2 ** 0.5;
                const push = (rr - d) / (2 * d);
                a.x -= dx * push;
                a.z -= dz * push;
                b.x += dx * push;
                b.z += dz * push;
            }
        }
    }
    for (let i = 0; i < count; i++) step1(list, i, gx, gz, rad, pr);
    for (let i = 0; i < count; i++) {
        const a = list[i];
        for (let j = i + 1; j < count; j++) {
            const b = list[j];
            const rr = rad * a.spec.scale + rad * b.spec.scale;
            const dx = b.x - a.x;
            const dz = b.z - a.z;
            const d2 = dx * dx + dz * dz;
            if (d2 < rr * rr && d2 > 1e-4) {
                const d = d2 ** 0.5;
                const push = (rr - d) / (2 * d);
                a.x -= dx * push;
                a.z -= dz * push;
                b.x += dx * push;
                b.z += dz * push;
            }
        }
    }
    return list;
}

// ---- isolating the disqualifier in `collideLeaf` --------------------------
//
// r1 (a single flat loop, single `if`) is compiled; `collideLeaf` is not, and
// its only structural difference from r5 is that the player step is written
// *inline* as a two-level `if` with declarations in the inner block.

// cb: `collideLeaf` with the player step as one `if` (dead-centre case dropped).
function cb(list, count, gx, gz, rad, pr) {
    for (let pass = 0; pass < 2; pass++) {
        for (let i = 0; i < count; i++) {
            const b = list[i];
            const rr = pr + rad * b.spec.scale;
            const dx = b.x - gx;
            const dz = b.z - gz;
            const d2 = dx * dx + dz * dz;
            if (d2 < rr * rr && d2 > 1e-4) {
                const d = d2 ** 0.5;
                const push = (rr - d) / d;
                b.x += dx * push;
                b.z += dz * push;
            }
        }
        for (let i = 0; i < count; i++) {
            const a = list[i];
            for (let j = i + 1; j < count; j++) {
                const b = list[j];
                const rr = rad * a.spec.scale + rad * b.spec.scale;
                const dx = b.x - a.x;
                const dz = b.z - a.z;
                const d2 = dx * dx + dz * dz;
                if (d2 < rr * rr && d2 > 1e-4) {
                    const d = d2 ** 0.5;
                    const push = (rr - d) / (2 * d);
                    a.x -= dx * push;
                    a.z -= dz * push;
                    b.x += dx * push;
                    b.z += dz * push;
                }
            }
        }
    }
    return list;
}

// cc: cb plus the dead-centre case as an `else if` (the production shape).
function cc(list, count, gx, gz, rad, pr) {
    for (let pass = 0; pass < 2; pass++) {
        for (let i = 0; i < count; i++) {
            const b = list[i];
            const rr = pr + rad * b.spec.scale;
            const dx = b.x - gx;
            const dz = b.z - gz;
            const d2 = dx * dx + dz * dz;
            if (d2 < rr * rr && d2 > 1e-4) {
                const d = d2 ** 0.5;
                const push = (rr - d) / d;
                b.x += dx * push;
                b.z += dz * push;
            } else if (d2 < rr * rr) {
                b.x = gx + rr;
            }
        }
        for (let i = 0; i < count; i++) {
            const a = list[i];
            for (let j = i + 1; j < count; j++) {
                const b = list[j];
                const rr = rad * a.spec.scale + rad * b.spec.scale;
                const dx = b.x - a.x;
                const dz = b.z - a.z;
                const d2 = dx * dx + dz * dz;
                if (d2 < rr * rr && d2 > 1e-4) {
                    const d = d2 ** 0.5;
                    const push = (rr - d) / (2 * d);
                    a.x -= dx * push;
                    a.z -= dz * push;
                    b.x += dx * push;
                    b.z += dz * push;
                }
            }
        }
    }
    return list;
}

// cd: one flat loop holding exactly `collideLeaf`'s player block, nested `if`
// and inner-block declarations included. Compare with r1 (same loop, one `if`).
function cd(list, count, gx, gz, rad, pr) {
    for (let i = 0; i < count; i++) {
        const b = list[i];
        const rr = pr + rad * b.spec.scale;
        const dx = b.x - gx;
        const dz = b.z - gz;
        const d2 = dx * dx + dz * dz;
        if (d2 < rr * rr) {
            if (d2 <= 1e-4) {
                b.x = gx + rr;
            } else {
                const d = d2 ** 0.5;
                const push = (rr - d) / d;
                b.x += dx * push;
                b.z += dz * push;
            }
        }
    }
    return list;
}

// ce: cd with the inner block's declarations hoisted out (no declaration inside
// a nested block) -- separates the nested `if` from the inner-block `const`s.
function ce(list, count, gx, gz, rad, pr) {
    let d = 0;
    let push = 0;
    for (let i = 0; i < count; i++) {
        const b = list[i];
        const rr = pr + rad * b.spec.scale;
        const dx = b.x - gx;
        const dz = b.z - gz;
        const d2 = dx * dx + dz * dz;
        if (d2 < rr * rr) {
            if (d2 <= 1e-4) {
                b.x = gx + rr;
            } else {
                d = d2 ** 0.5;
                push = (rr - d) / d;
                b.x += dx * push;
                b.z += dz * push;
            }
        }
    }
    return list;
}

// ---- is it a budget or a rule? ---------------------------------------------
//
// `cb` is compiled and `collideLeaf` is not, and the two deltas between them are
// small: `collideLeaf` hoists `const ar` out of its inner pair loop, and writes
// its player step as a nested `if` with declarations in the inner block. `cd`
// shows the nested `if` is fine on its own and `r6` shows a hoisted `ar` is fine
// on its own, so either the two together trip something, or the body is simply
// over a size budget (`collideLeaf` carries the most declarations of any body
// here). x1/x2/x3 add the deltas one at a time; pad4/pad8/pad16 add unused
// frame declarations to `cb` to look for a cliff.

function x1(list, count, gx, gz, rad, pr) {
    for (let pass = 0; pass < 2; pass++) {
        for (let i = 0; i < count; i++) {
            const b = list[i];
            const rr = pr + rad * b.spec.scale;
            const dx = b.x - gx;
            const dz = b.z - gz;
            const d2 = dx * dx + dz * dz;
            if (d2 < rr * rr && d2 > 1e-4) {
                const d = d2 ** 0.5;
                const push = (rr - d) / d;
                b.x += dx * push;
                b.z += dz * push;
            }
        }
        for (let i = 0; i < count; i++) {
            const a = list[i];
            const ar = rad * a.spec.scale;
            for (let j = i + 1; j < count; j++) {
                const b = list[j];
                const rr = ar + rad * b.spec.scale;
                const dx = b.x - a.x;
                const dz = b.z - a.z;
                const d2 = dx * dx + dz * dz;
                if (d2 < rr * rr && d2 > 1e-4) {
                    const d = d2 ** 0.5;
                    const push = (rr - d) / (2 * d);
                    a.x -= dx * push;
                    a.z -= dz * push;
                    b.x += dx * push;
                    b.z += dz * push;
                }
            }
        }
    }
    return list;
}

function x2(list, count, gx, gz, rad, pr) {
    for (let pass = 0; pass < 2; pass++) {
        for (let i = 0; i < count; i++) {
            const b = list[i];
            const rr = pr + rad * b.spec.scale;
            const dx = b.x - gx;
            const dz = b.z - gz;
            const d2 = dx * dx + dz * dz;
            if (d2 < rr * rr) {
                if (d2 <= 1e-4) {
                    b.x = gx + rr;
                } else {
                    const d = d2 ** 0.5;
                    const push = (rr - d) / d;
                    b.x += dx * push;
                    b.z += dz * push;
                }
            }
        }
        for (let i = 0; i < count; i++) {
            const a = list[i];
            for (let j = i + 1; j < count; j++) {
                const b = list[j];
                const rr = rad * a.spec.scale + rad * b.spec.scale;
                const dx = b.x - a.x;
                const dz = b.z - a.z;
                const d2 = dx * dx + dz * dz;
                if (d2 < rr * rr && d2 > 1e-4) {
                    const d = d2 ** 0.5;
                    const push = (rr - d) / (2 * d);
                    a.x -= dx * push;
                    a.z -= dz * push;
                    b.x += dx * push;
                    b.z += dz * push;
                }
            }
        }
    }
    return list;
}

// `padN` is `cb` with N unused frame declarations in the inner pair body.
function padBody(list, count, rad, pad, sink) {
    for (let i = 0; i < count; i++) {
        const a = list[i];
        for (let j = i + 1; j < count; j++) {
            const b = list[j];
            const rr = rad * a.spec.scale + rad * b.spec.scale;
            const dx = b.x - a.x;
            const dz = b.z - a.z;
            const d2 = dx * dx + dz * dz;
            let u1 = 0, u2 = 0, u3 = 0, u4 = 0, u5 = 0, u6 = 0, u7 = 0, u8 = 0;
            let u9 = 0, u10 = 0, u11 = 0, u12 = 0, u13 = 0, u14 = 0, u15 = 0, u16 = 0;
            if (pad > 0) u1 = b.x;
            if (pad > 1) u2 = b.z;
            if (pad > 2) u3 = a.x;
            if (pad > 3) u4 = a.z;
            if (pad > 4) u5 = b.x;
            if (pad > 5) u6 = b.z;
            if (pad > 6) u7 = a.x;
            if (pad > 7) u8 = a.z;
            if (pad > 8) u9 = b.x;
            if (pad > 9) u10 = b.z;
            if (pad > 10) u11 = a.x;
            if (pad > 11) u12 = a.z;
            if (pad > 12) u13 = b.x;
            if (pad > 13) u14 = b.z;
            if (pad > 14) u15 = a.x;
            if (pad > 15) u16 = a.z;
            sink += u1 + u2 + u3 + u4 + u5 + u6 + u7 + u8;
            sink += u9 + u10 + u11 + u12 + u13 + u14 + u15 + u16;
            if (d2 < rr * rr && d2 > 1e-4) {
                const d = d2 ** 0.5;
                const push = (rr - d) / (2 * d);
                a.x -= dx * push;
                a.z -= dz * push;
                b.x += dx * push;
                b.z += dz * push;
            }
        }
    }
    return sink;
}

function padN(list, count, gx, gz, rad, pr, pad) {
    let sink = 0;
    for (let pass = 0; pass < 2; pass++) {
        for (let i = 0; i < count; i++) step1(list, i, gx, gz, rad, pr);
        sink += padBody(list, count, rad, pad, sink);
    }
    return sink;
}

function pad0(list, count, gx, gz, rad, pr) { return padN(list, count, gx, gz, rad, pr, 0); }
function pad4(list, count, gx, gz, rad, pr) { return padN(list, count, gx, gz, rad, pr, 4); }
function pad8(list, count, gx, gz, rad, pr) { return padN(list, count, gx, gz, rad, pr, 8); }
function pad16(list, count, gx, gz, rad, pr) { return padN(list, count, gx, gz, rad, pr, 16); }

let NESTED_LIST = [];
function makeList(n) {
    const list = [];
    for (let i = 0; i < n; i++) {
        list.push({ x: (i % 5) - 2, z: (i % 3) - 1, spec: { scale: 0.8 + (i % 4) * 0.1 } });
    }
    return list;
}

// ---- the harness ----------------------------------------------------------

// Warm the callee first: a loop body compiles on its first consult, a
// straight-line body after `JIT_COMPILE_THRESHOLD` (16) of them, so three
// timing runs are plenty for either.
function timeIt(fn, args, iters, perIter) {
    fn.apply(null, args);
    fn.apply(null, args);
    const t0 = rl.getTime();
    for (let k = 0; k < iters; k++) fn.apply(null, args);
    const t1 = rl.getTime();
    return ((t1 - t0) / (iters * perIter)) * 1e9;
}

// Deliberately no padStart/padEnd: this fixture must not depend on a builtin
// that the engine might not have installed.
function pad(text, width) {
    let s = "" + text;
    while (s.length < width) s += " ";
    return s;
}

function row(label, ns) {
    let value = ns.toFixed(1);
    while (value.length < 9) value = " " + value;
    return pad(label, 18) + value + " ns/iter";
}

function probeAll() {
    NESTED_LIST = makeList(7);
    const bots = makeList(7);
    const lines = [];
    lines.push("jitprobe N=" + N + " (10 ns/iter = compiled, 150+ = interpreter)");
    lines.push(row("arith", timeIt(vArith, [N], 1, N)));
    lines.push(row("outer-read", timeIt(vOuterRead, [N], 1, N)));
    lines.push(row("outer-chain", timeIt(vOuterChain, [N], 1, N)));
    lines.push(row("global-read", timeIt(vGlobalRead, [N], 1, N)));
    lines.push(row("call-outer", timeIt(vCallOuter, [N], 1, N)));
    lines.push(row("call-param", timeIt(vCallParam, [N, gAdd], 1, N)));
    lines.push(row("sqrt-global", timeIt(vSqrtGlobal, [N], 1, N)));
    lines.push(row("pow-half", timeIt(vPow, [N], 1, N)));
    lines.push(row("continue", timeIt(vContinue, [N], 1, N)));
    lines.push(row("if-else", timeIt(vIfElse, [N], 1, N)));
    lines.push(row("nested-7", timeIt(vNested, [N], 1, N * 7)));
    // 7 bots: 2 passes x (7 player pairs + 21 bot pairs) = 56 pair steps.
    lines.push(row("collide-current", timeIt(collideCurrent, [bots, 0, 0], 2000, 56)));
    lines.push(row("collide-leaf", timeIt(collideLeaf, [bots, 7, 0, 0, 1.5, 1.5], 2000, 56)));
    // The ladder: every rung executes the same 56 body steps, so these numbers
    // are directly comparable with each other and with `nested-7`.
    const L = [bots, 7, 0, 0, 1.5, 1.5];
    lines.push("-- ladder (56 body steps per call, params only) --");
    lines.push(row("r1 flat", timeIt(r1, [bots, 7, 0, 0, 1.5, 1.5], 2000, 7)));
    lines.push(row("r2 two flat", timeIt(r2, [L], 2000, 13)));
    lines.push(row("r3 pass+2 flat", timeIt(r3, [L], 2000, 26)));
    lines.push(row("r4 pass+flat+call", timeIt(r4, [L], 2000, 98)));
    lines.push(row("r5 r4 inline pair", timeIt(r5, [L], 2000, 98)));
    lines.push(row("r6 no inner const", timeIt(r6, [L], 2000, 98)));
    lines.push(row("r7 j from 0", timeIt(r7, [L], 2000, 112)));
    lines.push(row("r8 unrolled", timeIt(r8, [L], 2000, 98)));
    lines.push("-- isolating collideLeaf's player block --");
    lines.push(row("cd nested-if", timeIt(cd, [bots, 7, 0, 0, 1.5, 1.5], 2000, 7)));
    lines.push(row("ce nested-if hoisted", timeIt(ce, [bots, 7, 0, 0, 1.5, 1.5], 2000, 7)));
    lines.push(row("cb one-if", timeIt(cb, [L], 2000, 98)));
    lines.push(row("cc one-if+else-if", timeIt(cc, [L], 2000, 98)));
    lines.push("-- the two deltas, one at a time --");
    lines.push(row("x1 ar hoist", timeIt(x1, [L], 2000, 98)));
    lines.push(row("x2 nested-if", timeIt(x2, [L], 2000, 98)));
    lines.push(row("x3 collideLeaf", timeIt(collideLeaf, [L], 2000, 98)));
    lines.push("-- frame-padding ladder --");
    lines.push(row("pad0", timeIt(pad0, [L], 2000, 98)));
    lines.push(row("pad4", timeIt(pad4, [L], 2000, 98)));
    lines.push(row("pad8", timeIt(pad8, [L], 2000, 98)));
    lines.push(row("pad16", timeIt(pad16, [L], 2000, 98)));
    return lines.join("\n");
}

goats.command("jitprobe-repeat", function () {
    // The same body measured three times in a row, and a body defined later in
    // this file with byte-identical source to `vGlobalRead`. If a row is slow
    // on its first measurement and fast on the next, the absolute numbers
    // above are warm-up artifacts; if the copy is fast while the original is
    // slow, it is the body's identity (a sticky verdict), not its code.
    const bots = makeList(7);
    const L = [bots, 7, 0, 0, 1.5, 1.5];
    const lines = ["jitprobe-repeat (three runs each)"];
    // [name, fn, args, perIter, iters]
    const bodies = [
        ["arith", vArith, [N], N, 1],
        ["global-read", vGlobalRead, [N], N, 1],
        ["global-read-copy", vGlobalReadCopy, [N], N, 1],
        ["cc", cc, [L], 98, 500],
        ["collideLeaf", collideLeaf, [L], 98, 500],
        ["collideCurrent", collideCurrent, [bots, 0, 0], 56, 500],
    ];
    for (let b = 0; b < bodies.length; b++) {
        const name = bodies[b][0];
        const times = [];
        for (let k = 0; k < 3; k++) {
            times.push(timeIt(bodies[b][1], bodies[b][2], bodies[b][4], bodies[b][3]).toFixed(1));
        }
        lines.push(row(name, 0).slice(0, 18) + times.join("  "));
    }
    return lines.join("\n");
});

// Byte-identical to `vGlobalRead`, defined late in the file on purpose.
function vGlobalReadCopy(n) {
    let s = 0;
    for (let i = 0; i < n; i++) s += i * 3 + Math.PI;
    return s;
}

// ---- does a compiled body survive between frames? --------------------------
//
// The scene's `collide` phase fell from 0.49 ms to 0.22 ms when its body stopped
// reading globals, but a compiled body doing this arithmetic should cost a few
// microseconds, not two hundred. The scene calls the kernel once per frame, so
// this measures exactly that: one call per frame from inside the scene's own
// update path, timed with the same two `rl.getTime()` calls the scene's phases
// use. A per-call cost of a few us means the compiled entry is being recreated
// every frame; tens of ns means it is stable and the scene's remaining cost is
// elsewhere.

let frameArmed = false;
let frameCalls = 0;
let frameUs = 0;
let frameUs2 = 0;
let frameBots = null;

function frameTick(dt) {
    if (!frameArmed) return;
    const t0 = rl.getTime();
    cc(frameBots, 7, 0, 0, 1.5, 1.5);
    const t1 = rl.getTime();
    cc(frameBots, 7, 0, 0, 1.5, 1.5);
    const t2 = rl.getTime();
    frameUs += (t1 - t0) * 1e6;
    frameUs2 += (t2 - t1) * 1e6;
    frameCalls += 1;
}

goats.on("update", frameTick);

goats.command("jitprobe-frame", function (parts) {
    const verb = parts[1] === undefined ? "" : parts[1];
    if (frameBots === null) frameBots = makeList(7);
    if (verb === "on") {
        frameArmed = true;
        frameCalls = 0;
        frameUs = 0;
        frameUs2 = 0;
        return "ok jitprobe-frame on";
    }
    if (verb === "off") {
        frameArmed = false;
        return "ok jitprobe-frame off";
    }
    if (frameCalls === 0) return "jitprobe-frame: no frames measured";
    // The empty baseline: what the same two `rl.getTime()` calls cost with no
    // call between them, which is the floor this measurement can resolve.
    let base = 0;
    for (let i = 0; i < 2000; i++) {
        const a = rl.getTime();
        const b = rl.getTime();
        base += (b - a) * 1e6;
    }
    return "jitprobe-frame calls " + frameCalls +
        " us/call1 " + (frameUs / frameCalls).toFixed(2) +
        " us/call2 " + (frameUs2 / frameCalls).toFixed(2) +
        " (floor " + (base / 2000).toFixed(2) + ")";
});

goats.command("jitprobe-one", function () {
    // One call, then a burst of the same call, then an empty measurement -- all
    // from one command context, so the only thing that changes is how the callee
    // is reached.
    const bots = makeList(7);
    let base = 0;
    for (let i = 0; i < 500; i++) {
        const a = rl.getTime();
        const b = rl.getTime();
        base += (b - a) * 1e6;
    }
    const t0 = rl.getTime();
    cc(bots, 7, 0, 0, 1.5, 1.5);
    const t1 = rl.getTime();
    const t2 = rl.getTime();
    for (let i = 0; i < 200; i++) cc(bots, 7, 0, 0, 1.5, 1.5);
    const t3 = rl.getTime();
    return "jitprobe-one first " + ((t1 - t0) * 1e6).toFixed(2) +
        " us, burst " + (((t3 - t2) * 1e6) / 200).toFixed(2) +
        " us/call, floor " + (base / 500).toFixed(2);
});

goats.command("jitprobe-call", function () {
    // The same body, the same argument values, the same context -- reached two
    // ways. `apply` is how the earlier table's rows were measured (through
    // `timeIt`); a direct call is how the scene reaches its own kernels.
    const bots = makeList(7);
    const args = [bots, 7, 0, 0, 1.5, 1.5];
    const lines = [];

    function directBurst(n) {
        const t0 = rl.getTime();
        for (let i = 0; i < n; i++) cc(bots, 7, 0, 0, 1.5, 1.5);
        const t1 = rl.getTime();
        return ((t1 - t0) * 1e6) / n;
    }

    function applyBurst(n) {
        const t0 = rl.getTime();
        for (let i = 0; i < n; i++) cc.apply(null, args);
        const t1 = rl.getTime();
        return ((t1 - t0) * 1e6) / n;
    }

    lines.push("direct  " + directBurst(200).toFixed(2) + " us/call");
    lines.push("apply   " + applyBurst(200).toFixed(2) + " us/call");
    lines.push("direct2 " + directBurst(200).toFixed(2) + " us/call");
    lines.push("apply2  " + applyBurst(200).toFixed(2) + " us/call");
    // A body with no loops at all, for contrast: the same two call forms on
    // something too small to have a nested-loop body.
    lines.push("tiny    " + tinyCall(bots));
    return lines.join("\n");
});

function tiny(x) {
    return x[0].x + x[6].z;
}

function tinyCall(bots) {
    const n = 2000;
    const t0 = rl.getTime();
    for (let i = 0; i < n; i++) tiny(bots);
    const t1 = rl.getTime();
    const direct = ((t1 - t0) * 1e6) / n;
    const t2 = rl.getTime();
    for (let i = 0; i < n; i++) tiny.apply(null, [bots]);
    const t3 = rl.getTime();
    return "direct " + direct.toFixed(2) + " us, apply " + (((t3 - t2) * 1e6) / n).toFixed(2) + " us";
}

goats.command("jitprobe", function () {
    return probeAll();
});

// ---- the global-binding rule ----------------------------------------------
//
// `global-read` (a `Math.PI` read) is the slowest row in the table by far, which
// would mean any body that names a true global object falls off the compiled
// path entirely -- a very broad claim, so it gets its own command: a value read
// off the global object and a *call* to a function that lives on it. The scene
// calls its own top-level functions constantly, so whether the call form is
// affected decides how much of the scene this rule covers.

let globalInstalled = false;
if (typeof globalThis !== "undefined") {
    globalThis.PROBE_SCALAR = 1.5;
    globalThis.PROBE_FN = function (x) { return x + 1.5; };
    globalInstalled = true;
}

function vGlobalValue(n) {
    let s = 0;
    for (let i = 0; i < n; i++) s += i * 3 + PROBE_SCALAR;
    return s;
}

function vGlobalFnCall(n) {
    let s = 0;
    for (let i = 0; i < n; i++) s += PROBE_FN(i);
    return s;
}

function vLocalFnCall(n) {
    let s = 0;
    for (let i = 0; i < n; i++) s += gAdd(i);
    return s;
}

goats.command("jitprobe-globals", function () {
    if (!globalInstalled) return "jitprobe-globals: no globalThis";
    const lines = [];
    lines.push("jitprobe-globals N=" + N);
    lines.push(row("outer-fn-call", timeIt(vLocalFnCall, [N], 1, N)));
    lines.push(row("global-fn-call", timeIt(vGlobalFnCall, [N], 1, N)));
    lines.push(row("global-value", timeIt(vGlobalValue, [N], 1, N)));
    return lines.join("\n");
});

goats.on("shutdown", function () {});
