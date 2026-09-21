#!/usr/bin/env python3
"""
make_variants.py — generate optimization variants from the pristine baselines.

Why generate instead of hand-writing each file: a variant must differ from its
predecessor ONLY in the one change being measured. Applying an explicit,
asserted string patch guarantees that. If a patch's anchor text is not found
byte-for-byte, we abort rather than silently producing an unpatched file.

Variants are CUMULATIVE: v2 = v1 + one change. The delta between consecutive
variants is therefore that single optimization's contribution, which is exactly
what an ablation table needs.

Usage:  python3 scripts/make_variants.py
Output: benchmarks/ablation/<bench>_v<N>_<slug>.py
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "benchmarks" / "ablation"


def patch(src: str, old: str, new: str, label: str) -> str:
    """Replace `old` with `new` exactly once. Abort if not found or ambiguous."""
    n = src.count(old)
    if n != 1:
        sys.exit(f"PATCH FAILED [{label}]: anchor found {n} times, expected 1.\n"
                 f"--- anchor ---\n{old}\n")
    return src.replace(old, new, 1)


# ===========================================================================
# nbody
# ===========================================================================
NBODY = (ROOT / "baseline" / "bm_nbody" / "run_benchmark.py").read_text()

# --- v1: replace the ** (-1.5) with a hardware sqrt --------------------------
# MECHANISM: `x ** y` compiles to BINARY_OP(power), which routes through
# CPython's generic numeric protocol to float_pow -> libm pow(). pow() is a
# general routine for arbitrary real exponents, evaluated roughly as
# exp(y*log x); our profile shows __ieee754_pow_sse2 (5.71% self) and __exp1
# (3.12%) as proof. math.sqrt maps to a single hardware sqrtsd instruction.
# d2**-1.5 == 1/(d2*sqrt(d2)) exactly, so this is an identity, not an
# approximation. The dt numerator folds the existing multiply into the divide.
# Also binds sqrt as a module-level name so the call site is a LOAD_GLOBAL of a
# builtin function rather than LOAD_GLOBAL(math) + LOAD_ATTR(sqrt).
v1 = patch(
    NBODY,
    "import pyperf\n",
    "import pyperf\nfrom math import sqrt\n",
    "nbody v1 import",
)
v1 = patch(
    v1,
    "            mag = dt * ((dx * dx + dy * dy + dz * dz) ** (-1.5))\n",
    "            d2 = dx * dx + dy * dy + dz * dz\n"
    "            mag = dt / (d2 * sqrt(d2))\n",
    "nbody v1 sqrt",
)

# --- v2: v1 + bind sqrt to a function-local ---------------------------------
# MECHANISM: inside advance(), `sqrt` is a global. LOAD_GLOBAL hashes the name
# string and probes the module __dict__, then builtins if that misses. Adding a
# default argument `_sqrt=sqrt` binds it into the frame's fast-locals array, so
# the call site becomes LOAD_FAST: a single array index. Evaluated once at
# function definition time, not per call.
v2 = patch(
    v1,
    "def advance(dt, n, bodies=SYSTEM, pairs=PAIRS):",
    "def advance(dt, n, bodies=SYSTEM, pairs=PAIRS, _sqrt=sqrt):",
    "nbody v2 signature",
)
v2 = patch(
    v2,
    "            mag = dt / (d2 * sqrt(d2))",
    "            mag = dt / (d2 * _sqrt(d2))",
    "nbody v2 call site",
)

# --- v3: v2 + write velocities via slice assignment -------------------------
# MECHANISM: the six lines `v1[0] -= dx*b2m` ... each compile to
# LOAD_FAST v1, LOAD_CONST 0, BINARY_SUBSCR (read), arithmetic, STORE_SUBSCR
# (write) -- six index reads and six index writes per pair. Unpacking the list
# once (UNPACK_SEQUENCE, a single opcode) and writing back with one slice
# assignment per body replaces those with 2 unpacks and 2 slice stores.
# UNCERTAIN whether this wins: slice assignment builds a temporary tuple, which
# costs an allocation. Measured either way; a negative result stays in the table.
v3 = patch(
    v2,
    "            v1[0] -= dx * b2m\n"
    "            v1[1] -= dy * b2m\n"
    "            v1[2] -= dz * b2m\n"
    "            v2[0] += dx * b1m\n"
    "            v2[1] += dy * b1m\n"
    "            v2[2] += dz * b1m\n",
    "            a1, b1, c1 = v1\n"
    "            a2, b2, c2 = v2\n"
    "            v1[:] = (a1 - dx * b2m, b1 - dy * b2m, c1 - dz * b2m)\n"
    "            v2[:] = (a2 + dx * b1m, b2 + dy * b1m, c2 + dz * b1m)\n",
    "nbody v3 velocity writes",
)

# --- v4: STRUCTURAL, and deliberately libm-independent ----------------------
# WHY THIS VARIANT EXISTS
# v1 (pow -> sqrt) measured 1.13x on glibc 2.26 + Python 3.12 but "not
# significant" on glibc 2.35 + Python 3.10. Mechanism: `**` is an INLINE opcode
# (BINARY_OP), while sqrt(x) is a Python CALL. Newer glibc pow() is fast enough
# that trading a cheap inline op for a called function gains nothing -- and v1
# additionally introduced sqrt as a GLOBAL, paying LOAD_GLOBAL + CALL to save a
# now-cheap pow. So the headline optimization is PLATFORM-SPECIFIC.
#
# This variant therefore keeps `** (-1.5)` untouched, so the libm pow cost is
# IDENTICAL on both sides of the comparison and the measured delta is purely
# structural. It should transfer across libm versions, unlike v1.
#
# Two changes, neither touching the arithmetic:
#
# 1. Hoist dt into the masses ONCE, outside all loops. dt is constant, so
#    `mag = dt * (...)` performs a constant multiply 200,000 times. Folding dt
#    into m1 and m2 in a precomputed flat pair list removes it from the loop.
#    The pair tuples are also flattened so the loop target is a single
#    UNPACK_SEQUENCE of 6 instead of a nested unpack of nested lists.
#
# 2. Read each velocity list into locals once, write back with plain stores.
#    The original does `v1[0] -= dx*b2m` six times, and each is a
#    BINARY_SUBSCR (read) plus a STORE_SUBSCR (write) -- six index reads and six
#    index writes per pair. Unpacking once (`a,b,c = v1`, one UNPACK_SEQUENCE)
#    removes the six reads.
#
#    NOTE this is NOT v3's slice assignment. v3 wrote `v1[:] = (a,b,c)`, which
#    builds a temporary tuple (an allocation) and invokes general
#    PySequence_SetSlice; it measured 1.21x SLOWER on the host. Here the six
#    stores stay as plain STORE_SUBSCR, so nothing is allocated.
#
# Measured 1.14x on glibc 2.26 + Python 3.12 with ** (-1.5) held constant.
v4 = patch(
    NBODY,
    "import pyperf\n",
    "import pyperf\n",
    "nbody v4 noop",
)
v4 = patch(
    v4,
    """def advance(dt, n, bodies=SYSTEM, pairs=PAIRS):
    for i in range(n):
        for (([x1, y1, z1], v1, m1),
             ([x2, y2, z2], v2, m2)) in pairs:
            dx = x1 - x2
            dy = y1 - y2
            dz = z1 - z2
            mag = dt * ((dx * dx + dy * dy + dz * dz) ** (-1.5))
            b1m = m1 * mag
            b2m = m2 * mag
            v1[0] -= dx * b2m
            v1[1] -= dy * b2m
            v1[2] -= dz * b2m
            v2[0] += dx * b1m
            v2[1] += dy * b1m
            v2[2] += dz * b1m
        for (r, [vx, vy, vz], m) in bodies:
            r[0] += dt * vx
            r[1] += dt * vy
            r[2] += dt * vz
""",
    """def advance(dt, n, bodies=SYSTEM, pairs=PAIRS):
    # dt is constant, so fold it into the masses ONCE rather than multiplying
    # inside the inner loop 200,000 times. Flattening the pair tuples also turns
    # the loop target into a single UNPACK_SEQUENCE of 6 instead of a nested
    # unpack of nested lists.
    dtp = [(r1, v1, m1 * dt, r2, v2, m2 * dt)
           for ((r1, v1, m1), (r2, v2, m2)) in pairs]
    for i in range(n):
        for (r1, v1, m1d, r2, v2, m2d) in dtp:
            x1, y1, z1 = r1
            x2, y2, z2 = r2
            dx = x1 - x2
            dy = y1 - y2
            dz = z1 - z2
            # ** (-1.5) deliberately UNCHANGED: this variant measures structure,
            # not libm, so the pow cost is identical on both sides.
            mag = (dx * dx + dy * dy + dz * dz) ** (-1.5)
            b1m = m1d * mag
            b2m = m2d * mag
            # unpack once (one UNPACK_SEQUENCE) instead of six BINARY_SUBSCR
            a, b, c = v1
            d, e, f = v2
            v1[0] = a - dx * b2m
            v1[1] = b - dy * b2m
            v1[2] = c - dz * b2m
            v2[0] = d + dx * b1m
            v2[1] = e + dy * b1m
            v2[2] = f + dz * b1m
        for (r, v, m) in bodies:
            r[0] += dt * v[0]
            r[1] += dt * v[1]
            r[2] += dt * v[2]
""",
    "nbody v4 structural",
)

# ===========================================================================
# raytrace
# ===========================================================================
RT = (ROOT / "baseline" / "bm_raytrace" / "run_benchmark.py").read_text()

# --- v1: delete the do-nothing type guards ----------------------------------
# MECHANISM: Vector.dot() calls other.mustBeVector(), whose entire body is
# `return self`. That is a full Python call: build a frame, execute, tear the
# frame down, discard the result. Our py-spy profile measures line 52 (the
# guard) at 3.5% and line 114 (`if other.isPoint():` in Point.__sub__) at 2.0%.
# These are debug assertions in a benchmark, not logic: removing them cannot
# change any computed value on the paths this benchmark takes.
#
# Point.__sub__ keeps its behaviour: in this scene it is only ever called with
# Point operands (Point - Point -> Vector), which the correctness gate verifies
# by comparing the rendered pixel buffer byte-for-byte.
rt1 = patch(
    RT,
    "    def dot(self, other):\n"
    "        other.mustBeVector()\n"
    "        return (self.x * other.x) + (self.y * other.y) + (self.z * other.z)\n",
    "    def dot(self, other):\n"
    "        # guard removed: mustBeVector()'s body is `return self` (3.5% of samples)\n"
    "        return (self.x * other.x) + (self.y * other.y) + (self.z * other.z)\n",
    "rt v1 dot guard",
)
rt1 = patch(
    rt1,
    "    def __sub__(self, other):\n"
    "        other.mustBeVector()\n"
    "        return Vector(self.x - other.x, self.y - other.y, self.z - other.z)\n",
    "    def __sub__(self, other):\n"
    "        # guard removed: mustBeVector() computes nothing\n"
    "        return Vector(self.x - other.x, self.y - other.y, self.z - other.z)\n",
    "rt v1 vector sub guard",
)
rt1 = patch(
    rt1,
    "    def cross(self, other):\n"
    "        other.mustBeVector()\n",
    "    def cross(self, other):\n",
    "rt v1 cross guard",
)
rt1 = patch(
    rt1,
    "    def __add__(self, other):\n"
    "        other.mustBeVector()\n"
    "        return Point(self.x + other.x, self.y + other.y, self.z + other.z)\n",
    "    def __add__(self, other):\n"
    "        return Point(self.x + other.x, self.y + other.y, self.z + other.z)\n",
    "rt v1 point add guard",
)

# --- v2: v1 + __slots__ on the hot classes ----------------------------------
# MECHANISM: by default every instance carries a __dict__, and `self.x` is a
# LOAD_ATTR that walks the type's MRO then hashes "x" and probes that dict.
# __slots__ replaces the per-instance dict with fixed descriptor slots, so the
# access becomes a direct offset load, and the dict's memory disappears
# entirely. Our C profile shows subtype_dealloc 3.11%, _PyObject_Malloc 1.95%
# and slot_tp_init 1.65%, so both the time and the allocation should improve.
#
# Vector carries class attributes (Vector.ZERO/RIGHT/UP/OUT) assigned AFTER the
# class body. Those are class-level, not instance-level, so __slots__ does not
# forbid them.
rt2 = patch(
    rt1,
    "class Vector(object):\n\n    def __init__(self, initx, inity, initz):",
    "class Vector(object):\n\n    __slots__ = ('x', 'y', 'z')\n\n"
    "    def __init__(self, initx, inity, initz):",
    "rt v2 Vector slots",
)
rt2 = patch(
    rt2,
    "class Point(object):\n\n    def __init__(self, initx, inity, initz):",
    "class Point(object):\n\n    __slots__ = ('x', 'y', 'z')\n\n"
    "    def __init__(self, initx, inity, initz):",
    "rt v2 Point slots",
)
rt2 = patch(
    rt2,
    "class Ray(object):\n\n    def __init__(self, point, vector):",
    "class Ray(object):\n\n    __slots__ = ('point', 'vector')\n\n"
    "    def __init__(self, point, vector):",
    "rt v2 Ray slots",
)

# --- v3: v2 + cache radius squared ------------------------------------------
# MECHANISM: Sphere.intersectionTime recomputes self.radius * self.radius on
# every call -- two LOAD_ATTR plus a multiply, per ray per sphere. The radius
# never changes after construction, so compute it once in __init__. Measured at
# 4.1% for line 145. Classic loop-invariant hoisting, just across a call
# boundary instead of a loop.
rt3 = patch(
    rt2,
    "        self.centre = centre\n        self.radius = radius\n",
    "        self.centre = centre\n        self.radius = radius\n"
    "        self.radius2 = radius * radius   # hoisted: was recomputed per call\n",
    "rt v3 radius2 init",
)
rt3 = patch(
    rt3,
    "        discriminant = (self.radius * self.radius) - (cp.dot(cp) - v * v)",
    "        discriminant = self.radius2 - (cp.dot(cp) - v * v)",
    "rt v3 radius2 use",
)
# Sphere needs __slots__ too, now that it has a third attribute worth packing.
rt3 = patch(
    rt3,
    "class Sphere(object):\n\n    def __init__(self, centre, radius):",
    "class Sphere(object):\n\n    __slots__ = ('centre', 'radius', 'radius2')\n\n"
    "    def __init__(self, centre, radius):",
    "rt v3 Sphere slots",
)

# --- v4: v3 + inline the dot products in intersectionTime -------------------
# MECHANISM: intersectionTime allocates a Vector (`cp = self.centre -
# ray.point`, line 143, 3.5%) then calls cp.dot(ray.vector) (line 144) and
# cp.dot(cp) (inside line 145). Each dot() is a Python call with frame
# setup/teardown, and the Vector is garbage immediately. Computing the three
# component differences into locals and doing the arithmetic inline removes one
# object allocation and two method calls per ray-sphere test -- the hottest
# path in the whole benchmark, since it runs for every ray against every object
# and again for every light in _lightIsVisible.
rt4 = patch(
    rt3,
    "    def intersectionTime(self, ray):\n"
    "        cp = self.centre - ray.point\n"
    "        v = cp.dot(ray.vector)\n"
    "        discriminant = self.radius2 - (cp.dot(cp) - v * v)\n"
    "        if discriminant < 0:\n"
    "            return None\n"
    "        else:\n"
    "            return v - math.sqrt(discriminant)\n",
    "    def intersectionTime(self, ray, _sqrt=math.sqrt):\n"
    "        # inlined: avoids allocating the intermediate Vector `cp` and two\n"
    "        # dot() calls per ray-sphere test (the hottest path in the bench)\n"
    "        c = self.centre\n"
    "        p = ray.point\n"
    "        rv = ray.vector\n"
    "        cx = c.x - p.x\n"
    "        cy = c.y - p.y\n"
    "        cz = c.z - p.z\n"
    "        v = cx * rv.x + cy * rv.y + cz * rv.z\n"
    "        discriminant = self.radius2 - (cx * cx + cy * cy + cz * cz - v * v)\n"
    "        if discriminant < 0:\n"
    "            return None\n"
    "        return v - _sqrt(discriminant)\n",
    "rt v4 inline intersectionTime",
)

# --- v5: v4 + the sqrt rewrite, to test whether the two COMPOSE -------------
# WHY: v1 (sqrt alone) measured "not significant" under KVM, and v4 (structure
# alone) measured 1.12x. Those two facts do not tell us what v4+sqrt does. The
# reason v1 lost was that it traded an inline BINARY_OP for a Python CALL while
# paying LOAD_GLOBAL for the name. v4 removes the `dt *` from the inner loop, so
# here the sqrt form is a plain reciprocal and `sqrt` is bound into fast-locals
# as a default argument -- both of v1's costs are reduced. It may now win, or the
# call overhead may still dominate. One ablation row answers it.
#
# d2 ** -1.5 == 1/(d2*sqrt(d2)) exactly, so this remains an identity.
v5 = patch(
    v4,
    "import pyperf\n",
    "import pyperf\nfrom math import sqrt\n",
    "nbody v5 import",
)
v5 = patch(
    v5,
    "def advance(dt, n, bodies=SYSTEM, pairs=PAIRS):",
    "def advance(dt, n, bodies=SYSTEM, pairs=PAIRS, _sqrt=sqrt):",
    "nbody v5 signature",
)
v5 = patch(
    v5,
    "            # ** (-1.5) deliberately UNCHANGED: this variant measures structure,\n"
    "            # not libm, so the pow cost is identical on both sides.\n"
    "            mag = (dx * dx + dy * dy + dz * dz) ** (-1.5)\n",
    "            d2 = dx * dx + dy * dy + dz * dz\n"
    "            mag = 1.0 / (d2 * _sqrt(d2))\n",
    "nbody v5 sqrt",
)

# ===========================================================================
VARIANTS = {
    "nbody_v1_sqrt":        v1,
    "nbody_v2_localsqrt":   v2,
    "nbody_v3_slicewrite":  v3,
    "nbody_v4_struct":      v4,
    "nbody_v5_struct_sqrt": v5,
    "raytrace_v1_noguards": rt1,
    "raytrace_v2_slots":    rt2,
    "raytrace_v3_radius2":  rt3,
    "raytrace_v4_inline":   rt4,
}

# Each variant's PARENT: the file it adds exactly one change to. The ablation
# table's "vs previous" column is only meaningful against the real parent.
#
# This is not always the alphabetically preceding variant. nbody v1..v3 form one
# cumulative chain from the baseline, but v4 branches off the BASELINE again
# (deliberately, so `** (-1.5)` is held constant), and v5 extends v4. Without
# this map, run_ablation.sh would report v4 "vs v3", which compares two variants
# that share no ancestry and attributes the delta to a change neither made.
PARENTS = {
    "nbody_v1_sqrt":        "baseline",
    "nbody_v2_localsqrt":   "nbody_v1_sqrt",
    "nbody_v3_slicewrite":  "nbody_v2_localsqrt",
    "nbody_v4_struct":      "baseline",
    "nbody_v5_struct_sqrt": "nbody_v4_struct",
    "raytrace_v1_noguards": "baseline",
    "raytrace_v2_slots":    "raytrace_v1_noguards",
    "raytrace_v3_radius2":  "raytrace_v2_slots",
    "raytrace_v4_inline":   "raytrace_v3_radius2",
}

# The variant that SHIPS as benchmarks/bm_<bench>_opt/run_benchmark.py -- the file
# the final comparison and the graded speedup are measured on.
#
# Generated rather than hand-maintained, because the shipped file silently
# drifting from the variant we measured is a real failure that already happened
# once: bm_nbody_opt was still nbody_v2_localsqrt (1.01x under KVM) after the
# ablation had shown v4_struct at 1.12x, so run_final.sh was faithfully measuring
# an optimization we were not proposing. Deriving it makes that impossible.
SHIPPED = {
    "nbody":    "nbody_v4_struct",
    "raytrace": "raytrace_v4_inline",
}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, text in VARIANTS.items():
        p = OUT / f"{name}.py"
        p.write_text(text)
        print(f"  wrote {p.relative_to(ROOT)}  ({len(text.splitlines())} lines)")

    missing = set(VARIANTS) ^ set(PARENTS)
    if missing:
        sys.exit(f"PARENTS and VARIANTS disagree on: {sorted(missing)}")
    (OUT / "PARENTS").write_text(
        "# variant parent  -- consumed by scripts/run_ablation.sh\n"
        + "".join(f"{k} {v}\n" for k, v in PARENTS.items()))
    print(f"  wrote {(OUT / 'PARENTS').relative_to(ROOT)}")

    for bench, variant in SHIPPED.items():
        dst = ROOT / "benchmarks" / f"bm_{bench}_opt" / "run_benchmark.py"
        if not dst.parent.is_dir():
            sys.exit(f"missing package dir: {dst.parent}")
        dst.write_text(VARIANTS[variant])
        print(f"  wrote {dst.relative_to(ROOT)}  (= {variant})")

    print(f"\n{len(VARIANTS)} variants generated. All patch anchors matched exactly once.")
