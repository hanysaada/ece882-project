#!/usr/bin/env python3
"""
model.py — bit-accurate golden reference model for the dot3 + rsqrt accelerator.

WHY THIS EXISTS, AND WHY IT IS WRITTEN FIRST
--------------------------------------------
RTL is hard to debug and slow to simulate. A golden model in Python is easy to
inspect, fast to iterate, and can be checked against exact IEEE-754 semantics
using the struct module. So we:

  1. write this model and validate its numerical behaviour,
  2. generate testbench vectors FROM it,
  3. write the SystemVerilog,
  4. assert the RTL reproduces this model bit for bit.

That way a mismatch means "the RTL is wrong", not "one of two unverified things
disagrees".

WHAT THE UNIT COMPUTES
----------------------
Two operations sharing one datapath, both binary32 (IEEE-754 single):

  dot3(ax,ay,az, bx,by,bz) -> ax*bx + ay*by + az*bz
      Three parallel multipliers into a 2-level adder tree.

  rsqrt(x) -> 1/sqrt(x)
      A LUT gives an initial estimate from the exponent and the leading mantissa
      bits; Newton-Raphson then refines it.

From those two, the benchmark kernels are built:

  nbody pair force:  d2 = dot3(d,d);  mag = dt * rsqrt(d2)**3
                     (equivalently dt * d2**-1.5, the quantity the software
                     optimization rewrote as dt/(d2*sqrt(d2)))

  ray-sphere hit:    v = dot3(cp, rv);  disc = r2 - (dot3(cp,cp) - v*v)
                     t = v - sqrt(disc)       [sqrt = x * rsqrt(x)]

THE NEWTON-RAPHSON ITERATION
----------------------------
To compute y = 1/sqrt(x), define f(y) = 1/y^2 - x. Newton's method gives

    y_{n+1} = y_n * (1.5 - 0.5 * x * y_n^2)

Each iteration roughly TRIPLES the number of correct bits (it is quadratically
convergent, and the error term is -1.5*e^2 - ...). Starting from a LUT seed
accurate to ~2^-8, one iteration reaches ~2^-16 and two reach ~2^-32, which
saturates binary32's 24-bit significand.

The iteration count and LUT size are parameters here so the accuracy/area
trade-off can be measured rather than guessed. See sweep_accuracy().

Run:  python3 hw/golden/model.py           # self-test + accuracy sweep
      python3 hw/golden/model.py --vectors # emit testbench vectors
"""
from __future__ import annotations

import argparse
import math
import pathlib
import struct
import sys

# ---------------------------------------------------------------------------
# binary32 helpers. Python floats are binary64, so every intermediate result
# must be explicitly rounded to binary32 to model the hardware honestly.
# ---------------------------------------------------------------------------


def f32(x: float) -> float:
    """Round a Python (binary64) float to the nearest binary32 value."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


def f32_bits(x: float) -> int:
    """The 32-bit pattern of x as an unsigned integer (for RTL comparison)."""
    return struct.unpack("<I", struct.pack("<f", x))[0]


def bits_f32(b: int) -> float:
    """Inverse of f32_bits."""
    return struct.unpack("<f", struct.pack("<I", b & 0xFFFFFFFF))[0]


def ulp_error(approx: float, exact: float) -> float:
    """Error in units of the last place of the binary32 result.

    ULP is the right unit for hardware accuracy: 'within 2 ULP' is a statement
    about the last two bits of the significand, independent of magnitude, which
    is what a hardware spec needs to promise.
    """
    if exact == 0.0:
        return 0.0 if approx == 0.0 else float("inf")
    ea = f32_bits(f32(exact))
    aa = f32_bits(f32(approx))
    return abs(ea - aa)          # adjacent binary32 values differ by 1 in bits


# ---------------------------------------------------------------------------
# dot3 — three multipliers into a 2-level adder tree
# ---------------------------------------------------------------------------


def dot3(ax, ay, az, bx, by, bz) -> float:
    """Three parallel binary32 multiplies, then a 2-level adder tree.

    The tree shape is FIXED and must match the RTL exactly, because IEEE-754
    addition is not associative: (p0+p1)+p2 and p0+(p1+p2) can differ in the
    last bit. We commit to ((p0+p1)+p2), which is a 2-level tree: level 1 adds
    p0+p1 (and passes p2 through), level 2 adds the result to p2.
    """
    p0 = f32(f32(ax) * f32(bx))
    p1 = f32(f32(ay) * f32(by))
    p2 = f32(f32(az) * f32(bz))
    s01 = f32(p0 + p1)           # adder tree level 1
    return f32(s01 + p2)         # adder tree level 2


# ---------------------------------------------------------------------------
# rsqrt — LUT seed + Newton-Raphson
# ---------------------------------------------------------------------------

LUT_BITS_DEFAULT = 6      # index width -> 2**6 = 64 entries
NR_ITERS_DEFAULT = 2


def build_rsqrt_lut(lut_bits: int = LUT_BITS_DEFAULT) -> list[int]:
    """Seed table for 1/sqrt, indexed by {exponent parity, top mantissa bits}.

    INDEXING SCHEME (chosen so hardware needs no arithmetic at all)
    ---------------------------------------------------------------
    Write x = 1.man * 2**E with man in [0,1) and E the unbiased exponent. To take
    a square root the exponent must be even, so fold the odd bit into the
    mantissa:

        E even -> mm = 1 + man        in [1,2),  k = E/2
        E odd  -> mm = 2 + 2*man      in [2,4),  k = (E-1)/2

    and then 1/sqrt(x) = (1/sqrt(mm)) * 2**(-k).

    So the table is indexed by ONE parity bit (E's low bit) concatenated with the
    top (lut_bits-1) mantissa bits:

        idx = {E[0], man[22 : 23-(lut_bits-1)]}

    In hardware that is a bit concatenation -- no multiply, no divide, no compare.
    An earlier version of this model indexed by (mm-1)/3, which needed a constant
    multiply in the RTL and was got wrong twice. Choosing the representation so
    the hardware is trivial is the better engineering answer.

    Each entry stores 1/sqrt at the MIDPOINT of its bucket, which halves the
    worst-case seed error compared with using the left edge.

    Values of 1/sqrt(mm) over mm in [1,4) lie in (0.5, 1.0], so 16-bit Q2.14
    fixed point covers the range with headroom.
    """
    half = 1 << (lut_bits - 1)          # entries per parity
    lut = []
    for parity in (0, 1):
        for j in range(half):
            man_lo = j / half
            man_hi = (j + 1) / half
            if parity == 0:             # E even: mm = 1 + man
                lo, hi = 1.0 + man_lo, 1.0 + man_hi
            else:                       # E odd:  mm = 2 + 2*man
                lo, hi = 2.0 + 2.0 * man_lo, 2.0 + 2.0 * man_hi
            mid = 0.5 * (lo + hi)
            lut.append(int(round((1.0 / math.sqrt(mid)) * (1 << 14))))
    return lut


class Rsqrt:
    """Model of the rsqrt pipeline: exponent split, LUT seed, N Newton steps."""

    def __init__(self, lut_bits: int = LUT_BITS_DEFAULT,
                 nr_iters: int = NR_ITERS_DEFAULT):
        self.lut_bits = lut_bits
        self.nr_iters = nr_iters
        self.lut = build_rsqrt_lut(lut_bits)

    # -- the seed stage ----------------------------------------------------
    def seed(self, x: float) -> float:
        """Initial estimate of 1/sqrt(x): exponent split plus one table lookup.

        Works directly on the binary32 FIELDS, exactly as the RTL does, rather
        than on the Python float value. That is deliberate: the model must mirror
        the hardware's operations, not merely its result.

            x = 1.man * 2**E
            E even -> mm = 1 + man,     k = E/2
            E odd  -> mm = 2 + 2*man,   k = (E-1)/2
            1/sqrt(x) = (1/sqrt(mm)) * 2**(-k)

        idx = {E[0], top (lut_bits-1) mantissa bits}  -- a bit concatenation.
        """
        bits = f32_bits(f32(x))
        exp_field = (bits >> 23) & 0xFF
        man_field = bits & 0x7FFFFF
        E = exp_field - 127                      # unbiased exponent

        parity = E & 1
        k = (E - parity) >> 1                    # E even -> E/2 ; odd -> (E-1)/2

        # top (lut_bits - 1) bits of the 23-bit mantissa
        j = man_field >> (23 - (self.lut_bits - 1))
        idx = (parity << (self.lut_bits - 1)) | j

        seed_m = self.lut[idx] / (1 << 14)       # ~= 1/sqrt(mm)
        return f32(math.ldexp(seed_m, -k))

    # -- one Newton-Raphson step ------------------------------------------
    @staticmethod
    def nr_step(y: float, x: float) -> float:
        """y <- y * (1.5 - 0.5 * x * y^2), all in binary32.

        Costs, per iteration, in hardware: 3 multiplies (y*y, x*y2, y*t) plus
        one multiply by the constant 0.5 (a free exponent decrement) and one
        subtract from the constant 1.5. So ~3 multipliers and 1 adder per stage.
        """
        y2 = f32(y * y)
        xy2 = f32(f32(x) * y2)
        t = f32(1.5 - f32(0.5 * xy2))
        return f32(y * t)

    def __call__(self, x: float) -> float:
        if x <= 0.0 or math.isnan(x) or math.isinf(x):
            # The hardware flags these rather than producing a number; the
            # software wrapper must not hand them to the accelerator. nbody
            # never does (d2 > 0 for distinct bodies) and raytrace guards
            # discriminant < 0 before taking a root.
            return float("nan")
        y = self.seed(x)
        for _ in range(self.nr_iters):
            y = self.nr_step(y, x)
        return y

    def sqrt(self, x: float) -> float:
        """sqrt(x) = x * rsqrt(x) -- no separate square-root unit needed."""
        if x == 0.0:
            return 0.0
        return f32(f32(x) * self(x))


# ---------------------------------------------------------------------------
# The two benchmark kernels, expressed in accelerator primitives
# ---------------------------------------------------------------------------



def ray_kernel(cx, cy, cz, rvx, rvy, rvz, radius2, rsq: Rsqrt):
    """pe_ray.sv's exact operation order, in binary32.

    Returns (t, hit). On a miss t is meaningless -- the hardware substitutes 1.0
    into rsqrt so the unit never sees a negative input, and flags the miss
    separately, so this model must do the same to stay bit-exact.
    """
    v = dot3(cx, cy, cz, rvx, rvy, rvz)
    cc = dot3(cx, cy, cz, cx, cy, cz)
    v2 = f32(v * v)
    s1 = f32(cc - v2)
    disc = f32(f32(radius2) - s1)
    miss = (disc < 0.0)
    rs_in = f32(1.0) if miss else disc
    rs = rsq(rs_in)
    sq = f32(rs_in * rs) if miss else f32(disc * rs)
    t = f32(v - sq)
    return t, (not miss)


def nbody_pair(dx, dy, dz, dt, rsqrt: Rsqrt) -> float:
    """dt * (dx^2+dy^2+dz^2)**-1.5, computed as dt * rsqrt(d2)**3.

    d2**-1.5 == (d2**-0.5)**3 == rsqrt(d2)**3, so the same rsqrt unit that
    raytrace needs also produces nbody's inverse-cube-distance factor. That
    identity is the whole reason one accelerator serves both benchmarks.
    """
    d2 = dot3(dx, dy, dz, dx, dy, dz)
    r = rsqrt(d2)
    return f32(f32(dt) * f32(f32(r * r) * r))


def ray_sphere(cx, cy, cz, rvx, rvy, rvz, radius2, rsqrt: Rsqrt):
    """Sphere.intersectionTime in accelerator primitives.

    Mirrors the optimized Python exactly:
        v    = cp . rv
        disc = r2 - (cp.cp - v*v)
        t    = v - sqrt(disc)     (None if disc < 0)
    """
    v = dot3(cx, cy, cz, rvx, rvy, rvz)
    cc = dot3(cx, cy, cz, cx, cy, cz)
    disc = f32(f32(radius2) - f32(cc - f32(v * v)))
    if disc < 0.0:
        return None
    return f32(v - rsqrt.sqrt(disc))


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def sweep_accuracy(lut_bits: int, nr_iters: int, n: int = 20000):
    """Max/mean ULP error of rsqrt over a wide input range.

    Sweeps geometrically over many octaves, because rsqrt's relative error is
    what matters and it repeats every two octaves of exponent.
    """
    r = Rsqrt(lut_bits, nr_iters)
    worst = 0.0
    total = 0.0
    worst_x = None
    for i in range(n):
        # 1e-6 .. 1e6, geometric
        x = 10.0 ** (-6.0 + 12.0 * i / (n - 1))
        approx = r(x)
        exact = 1.0 / math.sqrt(x)
        u = ulp_error(approx, exact)
        total += u
        if u > worst:
            worst, worst_x = u, x
    return worst, total / n, worst_x


def self_test() -> int:
    fails = 0

    print("=" * 72)
    print("dot3 — exactness against a directly-computed binary32 reference")
    print("=" * 72)
    cases = [
        (1.0, 2.0, 3.0, 4.0, 5.0, 6.0),
        (0.0, 0.0, 0.0, 1.0, 1.0, 1.0),
        (1e-4, 2e-4, 3e-4, 1e-4, 2e-4, 3e-4),
        (1234.5, -678.25, 0.125, -1.5, 2.25, 1024.0),
        (4.84143144246472090, -1.16032004402742839, -0.103622044471123109,
         4.84143144246472090, -1.16032004402742839, -0.103622044471123109),
    ]
    for c in cases:
        got = dot3(*c)
        # same tree shape, computed independently
        p = [f32(f32(c[i]) * f32(c[i + 3])) for i in range(3)]
        want = f32(f32(p[0] + p[1]) + p[2])
        ok = f32_bits(got) == f32_bits(want)
        fails += not ok
        print(f"  {'OK  ' if ok else 'FAIL'} dot3{c[:3]}·{c[3:]} = {got:.9g} "
              f"(bits 0x{f32_bits(got):08x})")

    print()
    print("=" * 72)
    print("rsqrt — accuracy vs LUT size and Newton-Raphson iteration count")
    print("=" * 72)
    print("  Each NR iteration roughly triples the number of correct bits.")
    print(f"  {'lut_bits':>8} {'entries':>8} {'iters':>6} {'max ULP':>10} {'mean ULP':>10}")
    grid = {}
    for lb in (4, 6, 8):
        for it in (0, 1, 2, 3):
            worst, mean, _ = sweep_accuracy(lb, it, 4000)
            grid[(lb, it)] = worst
            print(f"  {lb:>8} {1 << lb:>8} {it:>6} {worst:>10.1f} {mean:>10.2f}")

    # The design point we commit to in the RTL.
    print()
    lb, it = LUT_BITS_DEFAULT, NR_ITERS_DEFAULT
    worst, mean, wx = sweep_accuracy(lb, it, 20000)
    print(f"  DESIGN POINT: lut_bits={lb} ({1 << lb} entries), nr_iters={it}")
    print(f"    max {worst:.1f} ULP, mean {mean:.2f} ULP (worst at x={wx:.6g})")
    if worst > 4:
        print(f"    FAIL: expected <= 4 ULP at the design point")
        fails += 1
    else:
        print(f"    OK: within 4 ULP of the exact binary32 result")

    print()
    print("=" * 72)
    print("nbody kernel — accelerator primitives vs the software expression")
    print("=" * 72)
    r = Rsqrt()
    # the benchmark's real Sun-Jupiter separation
    for (dx, dy, dz) in [(4.84143144246472090, -1.16032004402742839,
                          -0.103622044471123109),
                         (1.0, 1.0, 1.0),
                         (0.5, -0.25, 0.125)]:
        got = nbody_pair(dx, dy, dz, 0.01, r)
        d2 = dx * dx + dy * dy + dz * dz
        want = 0.01 * d2 ** -1.5            # binary64 software result
        rel = abs(got - want) / abs(want)
        ok = rel < 1e-5                     # binary32 has ~1e-7 relative eps
        fails += not ok
        print(f"  {'OK  ' if ok else 'FAIL'} d=({dx:.4g},{dy:.4g},{dz:.4g}) "
              f"hw={got:.9g} sw={want:.9g} rel={rel:.2e}")

    print()
    print("=" * 72)
    print("ray-sphere kernel — hit and miss cases")
    print("=" * 72)
    # a ray pointing straight at a unit sphere 10 away, and one that misses
    for label, args, expect_hit in [
        ("head-on hit", (0.0, 0.0, -10.0, 0.0, 0.0, -1.0, 4.0), True),
        ("clean miss ", (0.0, 8.0, -10.0, 0.0, 0.0, -1.0, 4.0), False),
    ]:
        t = ray_sphere(*args, r)
        ok = (t is not None) == expect_hit
        fails += not ok
        print(f"  {'OK  ' if ok else 'FAIL'} {label}: t={t}")

    print()
    print("=" * 72)
    if fails:
        print(f"SELF-TEST FAILED: {fails} check(s)")
    else:
        print("SELF-TEST PASSED")
    return 1 if fails else 0


# ---------------------------------------------------------------------------
def emit_vectors(out_dir: pathlib.Path, n: int = 512):
    """Write testbench stimulus/response files for the RTL to be checked against.

    Format: whitespace-separated hex, one case per line, so a SystemVerilog
    testbench can $fscanf them directly.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    r = Rsqrt()

    # dot3: ax ay az bx by bz -> result
    with (out_dir / "dot3_vectors.hex").open("w") as fh:
        for i in range(n):
            vals = []
            for k in range(6):
                # spread over several octaves and both signs
                e = ((i * 7 + k * 13) % 21) - 10
                s = -1.0 if (i + k) % 3 == 0 else 1.0
                vals.append(f32(s * (1.0 + ((i * 31 + k * 17) % 97) / 97.0)
                                * 2.0 ** e))
            res = dot3(*vals)
            fh.write(" ".join(f"{f32_bits(v):08x}" for v in vals)
                     + f" {f32_bits(res):08x}\n")

    # rsqrt: x -> result
    with (out_dir / "rsqrt_vectors.hex").open("w") as fh:
        for i in range(n):
            x = 10.0 ** (-6.0 + 12.0 * i / (n - 1))
            fh.write(f"{f32_bits(f32(x)):08x} {f32_bits(r(f32(x))):08x}\n")

    # pe_pair: dx dy dz dt m1 m2 -> dv1x dv1y dv1z dv2x dv2y dv2z mag
    # Computed with exactly the accelerator's operation order so the RTL can be
    # checked bit-exact: dot3 tree shape, rsqrt via LUT+NR, then r*r, *r, *dt,
    # *mass, *delta -- each rounded to binary32 at every step.
    with (out_dir / "pe_pair_vectors.hex").open("w") as fh:
        for i in range(n):
            # spread over several octaves, both signs, avoiding d2 == 0
            e = ((i * 5) % 13) - 6
            dx = f32(((-1.0) ** i) * (1.0 + (i % 17) / 17.0) * 2.0 ** e)
            dy = f32(((-1.0) ** (i // 2)) * (1.0 + (i % 11) / 11.0) * 2.0 ** (e + 1))
            dz = f32(((-1.0) ** (i // 3)) * (1.0 + (i % 7) / 7.0) * 2.0 ** (e - 1))
            dt = f32(0.01)
            m1 = f32(1.0 + (i % 23) / 23.0)
            m2 = f32(1.0 + (i % 29) / 29.0)
            d2 = dot3(dx, dy, dz, dx, dy, dz)
            rr = r(d2)
            r3 = f32(f32(rr * rr) * rr)
            mag = f32(f32(dt) * r3)
            b1m = f32(f32(m1) * mag)
            b2m = f32(f32(m2) * mag)
            outs = [f32(dx * b2m), f32(dy * b2m), f32(dz * b2m),
                    f32(dx * b1m), f32(dy * b1m), f32(dz * b1m), mag]
            ins = [dx, dy, dz, dt, m1, m2]
            fh.write(" ".join(f"{f32_bits(v):08x}" for v in ins + outs) + "\n")

    # pe_ray: cx cy cz rvx rvy rvz radius2 -> t hit
    # Ray direction is normalised, matching Ray.__init__ in the benchmark.
    # Includes deliberate MISSES so the hit flag and the negative-discriminant
    # path are both exercised -- a testbench that only feeds hits would not
    # discover that rsqrt must never see a negative input.
    with (out_dir / "pe_ray_vectors.hex").open("w") as fh:
        import random as _rnd
        _rnd.seed(20260907)
        for i in range(n):
            # sphere centre offset, spread over octaves
            e = ((i * 3) % 11) - 5
            cx = f32(((-1.0) ** i) * (1.0 + (i % 13) / 13.0) * 2.0 ** e)
            cy = f32(((-1.0) ** (i // 2)) * (1.0 + (i % 9) / 9.0) * 2.0 ** e)
            cz = f32(((-1.0) ** (i // 3)) * (1.0 + (i % 5) / 5.0) * 2.0 ** e)
            # a normalised direction
            ux, uy, uz = (_rnd.uniform(-1, 1) for _ in range(3))
            nrm = math.sqrt(ux * ux + uy * uy + uz * uz) or 1.0
            rvx, rvy, rvz = (f32(ux / nrm), f32(uy / nrm), f32(uz / nrm))
            # half the cases have a radius large enough to hit, half too small
            cc_true = math.sqrt(cx * cx + cy * cy + cz * cz)
            rad = f32(cc_true * (1.2 if (i % 2 == 0) else 0.15))
            radius2 = f32(rad * rad)
            tt, hh = ray_kernel(cx, cy, cz, rvx, rvy, rvz, radius2, r)
            ins = [cx, cy, cz, rvx, rvy, rvz, radius2]
            fh.write(" ".join(f"{f32_bits(v):08x}" for v in ins)
                     + f" {f32_bits(tt):08x} {1 if hh else 0}\n")

    # accel_top system-level vectors: the nbody body array in and out.
    # Simulates NSTEPS timesteps using EXACTLY the accelerator's operation order
    # and datapath structure (subtract to form deltas, dot3, rsqrt, r*r, *r, *dt,
    # *mass, *delta, then accumulate and integrate), all in binary32. So the RTL
    # can be checked bit-exact end to end, not merely "close".
    emit_accel_vectors(out_dir, r)

    # the rsqrt seed LUT, for $readmemh
    with (out_dir / "rsqrt_lut.hex").open("w") as fh:
        for v in r.lut:
            fh.write(f"{v:04x}\n")

    print(f"  wrote dot3_vectors.hex   ({n} cases)")
    print(f"  wrote rsqrt_vectors.hex  ({n} cases)")
    print(f"  wrote pe_pair_vectors.hex ({n} cases)")
    print(f"  wrote pe_ray_vectors.hex  ({n} cases)")
    print(f"  wrote rsqrt_lut.hex      ({len(r.lut)} entries, Q2.14)")



# ---------------------------------------------------------------------------
# accel_top system-level vectors
# ---------------------------------------------------------------------------
ACCEL_NSTEPS = 4          # must match tb_accel_top.sv


def _nbody_initial():
    """The benchmark's own five bodies, after offset_momentum, as binary32."""
    PI = 3.14159265358979323
    SOLAR_MASS = 4 * PI * PI
    DPY = 365.24
    raw = [
        ([0.0, 0.0, 0.0], [0.0, 0.0, 0.0], SOLAR_MASS),
        ([4.84143144246472090, -1.16032004402742839, -0.103622044471123109],
         [1.66007664274403694e-03 * DPY, 7.69901118419740425e-03 * DPY,
          -6.90460016972063023e-05 * DPY], 9.54791938424326609e-04 * SOLAR_MASS),
        ([8.34336671824457987, 4.12479856412430479, -0.403523417114321381],
         [-2.76742510726862411e-03 * DPY, 4.99852801234917238e-03 * DPY,
          2.30417297573763929e-05 * DPY], 2.85885980666130812e-04 * SOLAR_MASS),
        ([12.8943695621391310, -15.1111514016986312, -0.223307578892655734],
         [2.96460137564761618e-03 * DPY, 2.37847173959480950e-03 * DPY,
          -2.96589568540237556e-05 * DPY], 4.36624404335156298e-05 * SOLAR_MASS),
        ([15.3796971148509165, -25.9193146099879641, 0.179258772950371181],
         [2.68067772490389322e-03 * DPY, 1.62824170038242295e-03 * DPY,
          -9.51592254519715870e-05 * DPY], 5.15138902046611451e-05 * SOLAR_MASS),
    ]
    # offset_momentum in float64, exactly as the benchmark does, then quantise
    px = py = pz = 0.0
    for (r_, v_, m_) in raw:
        px -= v_[0] * m_
        py -= v_[1] * m_
        pz -= v_[2] * m_
    r0, v0, m0 = raw[0]
    v0[0] = px / m0
    v0[1] = py / m0
    v0[2] = pz / m0
    return [([f32(c) for c in r_], [f32(c) for c in v_], f32(m_))
            for (r_, v_, m_) in raw]


def _accel_step(bodies, dt, rsq, npart: int = 4):
    """One timestep, mirroring accel_top.sv's structure and precision exactly.

    IMPORTANT: this deliberately does NOT use Newton's third law, and it sums
    through NPART partial accumulators in round-robin. Both choices come from the
    hardware, and both change the binary32 result, so the model must copy them or
    a bit-exact comparison is meaningless:

      * i-outer, all-j-inner, force on i only. The hardware does this because
        accumulating onto body j as well would be a read-after-write hazard on a
        shared location while results are in flight. Cost: n(n-1) pairs instead
        of n(n-1)/2.
      * NPART partial accumulators, reduced as (p0+p1)+(p2+p3). The hardware needs
        them to cover the adder's 3-cycle latency without stalling. Floating-point
        addition is not associative, so the partition and the reduction tree shape
        are part of the specification.
    """
    n = len(bodies)
    # snapshot positions: within a timestep all pair forces use the positions at
    # the START of the step, which the hardware also does because it only writes
    # positions in the integrate phase.
    for i in range(n):
        (ri, vi, mi) = bodies[i]
        px_ = [f32(0.0)] * npart
        py_ = [f32(0.0)] * npart
        pz_ = [f32(0.0)] * npart
        k = 0
        for j in range(n):
            if j == i:
                continue
            (rj, vj, mj) = bodies[j]
            dx = f32(ri[0] - rj[0])
            dy = f32(ri[1] - rj[1])
            dz = f32(ri[2] - rj[2])
            d2 = dot3(dx, dy, dz, dx, dy, dz)
            rr = rsq(d2)
            r3 = f32(f32(rr * rr) * rr)
            mag = f32(f32(dt) * r3)
            b2m = f32(f32(mj) * mag)          # pe_pair's dv1 uses m2
            d1x = f32(dx * b2m)
            d1y = f32(dy * b2m)
            d1z = f32(dz * b2m)
            px_[k] = f32(px_[k] + f32(-d1x))
            py_[k] = f32(py_[k] + f32(-d1y))
            pz_[k] = f32(pz_[k] + f32(-d1z))
            k = (k + 1) % npart
        # reduction tree: (p0+p1) + (p2+p3)
        sx = f32(f32(px_[0] + px_[1]) + f32(px_[2] + px_[3]))
        sy = f32(f32(py_[0] + py_[1]) + f32(py_[2] + py_[3]))
        sz = f32(f32(pz_[0] + pz_[1]) + f32(pz_[2] + pz_[3]))
        vi[0] = f32(vi[0] + sx)
        vi[1] = f32(vi[1] + sy)
        vi[2] = f32(vi[2] + sz)

    # integrate positions
    for (r_, v_, m_) in bodies:
        r_[0] = f32(r_[0] + f32(f32(dt) * v_[0]))
        r_[1] = f32(r_[1] + f32(f32(dt) * v_[1]))
        r_[2] = f32(r_[2] + f32(f32(dt) * v_[2]))


def emit_accel_vectors(out_dir: pathlib.Path, rsq: Rsqrt,
                       nsteps: int = ACCEL_NSTEPS):
    """Write the body array before and after nsteps timesteps.

    Layout is 8 words per body -- x y z vx vy vz mass pad -- matching
    accel_top.sv's documented memory layout.
    """
    dt = f32(0.01)
    bodies = _nbody_initial()

    with (out_dir / "accel_input.hex").open("w") as fh:
        for (r_, v_, m_) in bodies:
            for w in (r_[0], r_[1], r_[2], v_[0], v_[1], v_[2], m_, 0.0):
                fh.write(f"{f32_bits(f32(w)):08x}\n")

    for _ in range(nsteps):
        _accel_step(bodies, dt, rsq)

    with (out_dir / "accel_expected.hex").open("w") as fh:
        for (r_, v_, m_) in bodies:
            for w in (r_[0], r_[1], r_[2], v_[0], v_[1], v_[2], m_, 0.0):
                fh.write(f"{f32_bits(f32(w)):08x}\n")

    print(f"  wrote accel_input.hex     (5 bodies x 8 words)")
    print(f"  wrote accel_expected.hex  (after {nsteps} timesteps)")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--vectors", action="store_true",
                    help="emit testbench vectors into hw/tb/vectors/")
    a = ap.parse_args()
    rc = self_test()
    if a.vectors:
        print()
        print("Emitting testbench vectors")
        emit_vectors(pathlib.Path(__file__).resolve().parent.parent / "tb" / "vectors")
    sys.exit(rc)
