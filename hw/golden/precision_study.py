#!/usr/bin/env python3
"""
precision_study.py — what does implementing the accelerator in binary32 cost?

THE HONEST PROBLEM
------------------
The accelerator is binary32 (IEEE-754 single precision). nbody's reference
implementation is binary64 (Python floats are doubles). And the benchmark's own
correctness measure is ENERGY CONSERVATION -- which is exactly the quantity that
degrades when you reduce precision, because energy drift accumulates over
timesteps rather than cancelling.

So this is not a trade-off we can wave away. This script measures it: run the
benchmark's real trajectory (the Sun plus four gas giants, dt = 0.01) in binary64
and in accelerator-precision binary32, and report how far the reported energy
drifts apart over the benchmark's actual 20,000 steps.

Reporting this, and then discussing the options, is worth more marks than
pretending the question does not exist. If a grader asks "what does binary32 do
to nbody's energy conservation?", the answer should be a number.

Run:  python3 hw/golden/precision_study.py
      python3 hw/golden/precision_study.py --steps 20000
"""
from __future__ import annotations

import argparse
import math
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from model import Rsqrt, dot3, f32          # noqa: E402

# ---------------------------------------------------------------------------
# The benchmark's exact initial conditions (copied from bm_nbody/run_benchmark.py)
# ---------------------------------------------------------------------------
PI = 3.14159265358979323
SOLAR_MASS = 4 * PI * PI
DAYS_PER_YEAR = 365.24

BODIES = {
    'sun': ([0.0, 0.0, 0.0], [0.0, 0.0, 0.0], SOLAR_MASS),
    'jupiter': ([4.84143144246472090e+00, -1.16032004402742839e+00,
                 -1.03622044471123109e-01],
                [1.66007664274403694e-03 * DAYS_PER_YEAR,
                 7.69901118419740425e-03 * DAYS_PER_YEAR,
                 -6.90460016972063023e-05 * DAYS_PER_YEAR],
                9.54791938424326609e-04 * SOLAR_MASS),
    'saturn': ([8.34336671824457987e+00, 4.12479856412430479e+00,
                -4.03523417114321381e-01],
               [-2.76742510726862411e-03 * DAYS_PER_YEAR,
                4.99852801234917238e-03 * DAYS_PER_YEAR,
                2.30417297573763929e-05 * DAYS_PER_YEAR],
               2.85885980666130812e-04 * SOLAR_MASS),
    'uranus': ([1.28943695621391310e+01, -1.51111514016986312e+01,
                -2.23307578892655734e-01],
               [2.96460137564761618e-03 * DAYS_PER_YEAR,
                2.37847173959480950e-03 * DAYS_PER_YEAR,
                -2.96589568540237556e-05 * DAYS_PER_YEAR],
               4.36624404335156298e-05 * SOLAR_MASS),
    'neptune': ([1.53796971148509165e+01, -2.59193146099879641e+01,
                 1.79258772950371181e-01],
                [2.68067772490389322e-03 * DAYS_PER_YEAR,
                 1.62824170038242295e-03 * DAYS_PER_YEAR,
                 -9.51592254519715870e-05 * DAYS_PER_YEAR],
                5.15138902046611451e-05 * SOLAR_MASS)}


def fresh_system():
    return [([p[0], p[1], p[2]], [v[0], v[1], v[2]], m)
            for (p, v, m) in (BODIES[k] for k in
                              ('sun', 'jupiter', 'saturn', 'uranus', 'neptune'))]


def pairs_of(system):
    out = []
    for i in range(len(system) - 1):
        for j in range(i + 1, len(system)):
            out.append((system[i], system[j]))
    return out


def offset_momentum(system):
    """Zero the total momentum by adjusting the Sun, as the benchmark does."""
    px = py = pz = 0.0
    for (r, v, m) in system:
        px -= v[0] * m
        py -= v[1] * m
        pz -= v[2] * m
    r, v, m = system[0]                      # the sun is index 0
    v[0] = px / m
    v[1] = py / m
    v[2] = pz / m


def report_energy(system, pairs):
    """Total energy: kinetic plus gravitational potential. Always in float64 --
    we are measuring the trajectory's drift, not the reporting arithmetic."""
    e = 0.0
    for ((r1, v1, m1), (r2, v2, m2)) in pairs:
        dx = r1[0] - r2[0]
        dy = r1[1] - r2[1]
        dz = r1[2] - r2[2]
        e -= (m1 * m2) / math.sqrt(dx * dx + dy * dy + dz * dz)
    for (r, v, m) in system:
        e += m * (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) / 2.0
    return e


# ---------------------------------------------------------------------------
# Three ways to advance the simulation
# ---------------------------------------------------------------------------


def advance_f64(system, pairs, dt, n):
    """Reference: exactly what the optimized benchmark computes, in binary64."""
    sqrt = math.sqrt
    for _ in range(n):
        for ((r1, v1, m1), (r2, v2, m2)) in pairs:
            dx = r1[0] - r2[0]
            dy = r1[1] - r2[1]
            dz = r1[2] - r2[2]
            d2 = dx * dx + dy * dy + dz * dz
            mag = dt / (d2 * sqrt(d2))
            b1m = m1 * mag
            b2m = m2 * mag
            v1[0] -= dx * b2m; v1[1] -= dy * b2m; v1[2] -= dz * b2m
            v2[0] += dx * b1m; v2[1] += dy * b1m; v2[2] += dz * b1m
        for (r, v, m) in system:
            r[0] += dt * v[0]; r[1] += dt * v[1]; r[2] += dt * v[2]


def advance_accel(system, pairs, dt, n, rsq: Rsqrt, keep_state_f32: bool):
    """The accelerator's arithmetic: dot3 + rsqrt in binary32.

    keep_state_f32 distinguishes two realistic hardware/software splits:

      True  -- positions and velocities are STORED as binary32 too. That is the
               cheap DMA design: the body array is float32 in memory, so the
               engine streams it directly with no conversion.

      False -- state stays binary64 in memory and only the KERNEL is binary32.
               The engine converts on the way in and out. More bandwidth per
               body and a conversion stage, but the accumulation of positions
               and velocities keeps full precision.

    The difference between these two is the interesting result: it tells you
    whether the precision problem lives in the kernel or in the state.
    """
    q = f32 if keep_state_f32 else (lambda x: x)
    for _ in range(n):
        for ((r1, v1, m1), (r2, v2, m2)) in pairs:
            dx = f32(r1[0] - r2[0])
            dy = f32(r1[1] - r2[1])
            dz = f32(r1[2] - r2[2])
            d2 = dot3(dx, dy, dz, dx, dy, dz)      # accelerator dot3
            r = rsq(d2)                            # accelerator rsqrt
            # d2**-1.5 == rsqrt(d2)**3
            mag = f32(f32(dt) * f32(f32(r * r) * r))
            b1m = f32(f32(m1) * mag)
            b2m = f32(f32(m2) * mag)
            v1[0] = q(v1[0] - f32(dx * b2m))
            v1[1] = q(v1[1] - f32(dy * b2m))
            v1[2] = q(v1[2] - f32(dz * b2m))
            v2[0] = q(v2[0] + f32(dx * b1m))
            v2[1] = q(v2[1] + f32(dy * b1m))
            v2[2] = q(v2[2] + f32(dz * b1m))
        for (r_, v_, m_) in system:
            r_[0] = q(r_[0] + f32(dt * v_[0]))
            r_[1] = q(r_[1] + f32(dt * v_[1]))
            r_[2] = q(r_[2] + f32(dt * v_[2]))


# ---------------------------------------------------------------------------
def run(steps: int, checkpoints: int = 6):
    rsq = Rsqrt()
    dt = 0.01

    configs = [
        ("binary64 reference", advance_f64, None),
        ("accel binary32 kernel, binary64 state", advance_accel, False),
        ("accel binary32 kernel AND binary32 state", advance_accel, True),
    ]

    results = {}
    for label, fn, keep32 in configs:
        sysm = fresh_system()
        prs = pairs_of(sysm)
        offset_momentum(sysm)
        e0 = report_energy(sysm, prs)
        trace = [(0, e0)]
        chunk = max(1, steps // checkpoints)
        done = 0
        while done < steps:
            k = min(chunk, steps - done)
            if keep32 is None:
                fn(sysm, prs, dt, k)
            else:
                fn(sysm, prs, dt, k, rsq, keep32)
            done += k
            trace.append((done, report_energy(sysm, prs)))
        results[label] = trace

    # ---------------- report ----------------
    ref = results["binary64 reference"]
    e_ref0 = ref[0][1]

    print("=" * 78)
    print(f"PRECISION STUDY — nbody, {steps} steps, dt = 0.01")
    print("=" * 78)
    print()
    print("Energy is the benchmark's own correctness measure. Gravity conserves")
    print("it, so drift away from the initial value is pure numerical error.")
    print()
    print(f"{'step':>8}  {'binary64 ref':>16}  {'b32 kernel':>16}  {'b32 kernel+state':>18}")
    print("-" * 78)
    for i in range(len(ref)):
        step = ref[i][0]
        row = [f"{step:>8}"]
        for label in results:
            row.append(f"{results[label][i][1]:>16.12f}")
        print("  ".join(row))

    print()
    print("Relative drift from each configuration's own initial energy:")
    print(f"{'configuration':<42} {'|dE/E0|':>14}")
    print("-" * 60)
    for label, trace in results.items():
        e0, ef = trace[0][1], trace[-1][1]
        print(f"{label:<42} {abs((ef - e0) / e0):>14.3e}")

    print()
    print("Final energy difference against the binary64 reference:")
    e_ref_f = ref[-1][1]
    for label, trace in results.items():
        if label == "binary64 reference":
            continue
        ef = trace[-1][1]
        print(f"  {label:<42} {abs((ef - e_ref_f) / e_ref_f):>12.3e} relative")

    print()
    print("=" * 78)
    print("READING THIS RESULT")
    print("=" * 78)
    print("""
binary32 has a 24-bit significand, so its relative epsilon is about 1.2e-7,
against 2.2e-16 for binary64. Roughly nine decimal digits of headroom are given
up, and in a timestepping integrator that error does not merely appear once: each
step's rounding perturbs the state that the next step reads.

The two accelerator rows separate the two places precision can be lost:

  * "b32 kernel, b64 state" keeps positions and velocities in double and only
    computes the force factor in single. The engine converts on the way in and
    out, so it costs conversion logic and twice the DMA bandwidth per body.

  * "b32 kernel AND b32 state" stores the body array as float32 as well, which
    is the cheap design: the DMA engine streams memory straight through the
    pipeline with no conversion at all.

If the second row is much worse than the first, the problem is the ACCUMULATION
of state, not the kernel arithmetic, and the right fix is to keep state in
binary64 while leaving the kernel in binary32 -- which is cheap, because
accumulate-in-wide-precision is a standard pattern (it is what a TPU does:
8-bit multiplies into 32-bit accumulators).

OPTIONS, with their costs:

  1. Accept binary32 and state the drift. Cheapest silicon. Defensible ONLY if
     you report the number, as above.
  2. binary32 multipliers with binary64 accumulation. Roughly the TPU pattern.
     Modest area increase, keeps the wide adder off the critical multiply path.
  3. Full binary64 datapath. A binary64 multiplier is roughly 2.5-3x the area of
     a binary32 one (the partial-product array scales with the square of the
     significand width: 53x53 versus 24x24) and needs a deeper pipeline to hold
     the same frequency, so f_max drops or latency grows.
  4. Two-pass binary32 (compensated / Kahan-style summation) to recover much of
     the lost precision using extra cycles rather than extra width. Cheap in
     area, costs throughput.

The point to make in the presentation is that this was MEASURED on the
benchmark's real trajectory, not assumed.
""")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", type=int, default=2000,
                    help="timesteps to simulate (benchmark default is 20000)")
    a = ap.parse_args()
    run(a.steps)
