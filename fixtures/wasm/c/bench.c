// The benchmark kernel: the shape of the birds flock's `stepFly`, reduced to
// what every arm can run identically.
//
// `stepFly` is an O(n^2) neighbour accumulation -- for each agent, walk every
// other agent and accumulate alignment, cohesion and separation -- and that is
// what this keeps. Two things are deliberately left out so the comparison is
// about the engine rather than about what the kernel happens to need:
//
//   - no trigonometry. Core wasm has no `sin`/`cos`, so a kernel that used them
//     would be measuring the host's transcendental math, and the flock's yaw
//     vectors are the only reason it has any. The record is `{x, z, vx, vz}`.
//   - no imports at all. The host boundary is measured by the arm's call shape
//     (one call per frame), not by a capability, so this module imports nothing.
//
// Arithmetic is f64 with f32 storage, exactly the ABI's rule, so the JavaScript
// arm (whose numbers are always f64) computes the same values in the same order
// and both arms produce the same buffer.
//
// Build: see ../build.sh.

typedef signed int i32;

#define MAX_AGENTS 4096
#define STRIDE 4 // x, z, vx, vz

static float arena[MAX_AGENTS * STRIDE];

static const double COH = 11.0; // the mod's COH
static const double SEP = 3.2;  // the mod's SEP
static const double COH_W = 0.5;
static const double ALI_W = 1.0;
static const double SEP_W = 1.5;

__attribute__((export_name("bench_buffer")))
float *bench_buffer(void) {
    return arena;
}

// The same initial state the JavaScript arm builds, in the module, so a host
// with no way to write the module's memory still benchmarks real work (all
// agents at the origin would skip every separation branch).
__attribute__((export_name("bench_seed")))
void bench_seed(void) {
    for (i32 i = 0; i < MAX_AGENTS; i += 1) {
        arena[i * STRIDE + 0] = (float)((i * 37 % 29) * 0.5);
        arena[i * STRIDE + 1] = (float)((i * 53 % 31) * 0.5);
        arena[i * STRIDE + 2] = 0.0f;
        arena[i * STRIDE + 3] = 0.0f;
    }
}

__attribute__((export_name("bench")))
i32 bench(float *a, i32 count, double dt) {
    for (i32 i = 0; i < count; i += 1) {
        const i32 base = i * STRIDE;
        const double ax = (double)a[base + 0];
        const double az = (double)a[base + 1];
        double aliX = 0.0, aliZ = 0.0, cohX = 0.0, cohZ = 0.0, sepX = 0.0, sepZ = 0.0;
        i32 nA = 0, nC = 0, nS = 0;

        for (i32 j = 0; j < count; j += 1) {
            if (j == i) {
                continue;
            }
            const i32 other = j * STRIDE;
            const double dx = ax - (double)a[other + 0];
            const double dz = az - (double)a[other + 1];
            const double d2 = dx * dx + dz * dz;
            if (d2 < COH * COH) {
                cohX += (double)a[other + 0];
                cohZ += (double)a[other + 1];
                aliX += (double)a[other + 2];
                aliZ += (double)a[other + 3];
                nC += 1;
                nA += 1;
            }
            if (d2 > 1e-4 && d2 < SEP * SEP) {
                // Graded by distance, so a near pair pushes harder -- the mod's
                // comment, and the one place this kernel divides.
                const double d = __builtin_sqrt(d2);
                const double w = (SEP - d) / d;
                sepX += dx * w;
                sepZ += dz * w;
                nS += 1;
            }
        }

        if (nC > 0) {
            cohX /= (double)nC;
            cohZ /= (double)nC;
        }
        if (nA > 0) {
            aliX /= (double)nA;
            aliZ /= (double)nA;
        }
        if (nS > 0) {
            sepX /= (double)nS;
            sepZ /= (double)nS;
        }

        const double vx = (double)a[base + 2] + (cohX * COH_W + aliX * ALI_W + sepX * SEP_W) * dt;
        const double vz = (double)a[base + 3] + (cohZ * COH_W + aliZ * ALI_W + sepZ * SEP_W) * dt;
        a[base + 2] = (float)vx;
        a[base + 3] = (float)vz;
        a[base + 0] = (float)(ax + vx * dt);
        a[base + 1] = (float)(az + vz * dt);
    }
    return count;
}
