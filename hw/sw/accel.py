"""
accel.py — the Python-facing wrapper for the dot3 + rsqrt accelerator.

DESIGN RULE THIS FILE EXISTS TO OBEY (Lecture 4's first HW/SW interface rule):
"Do not expect end users to change their code", and "if hardware does not support
an operation, run it on the CPU -- reduced performance is better than broken user
code."

So this module:
  * exposes ONE batched call per benchmark kernel, never a per-operation call
    (results/hw/call_overhead.txt: a 595 ns crossing against a 2 ns throughput
    interval means per-operation is 297x too expensive),
  * falls back through three tiers without the caller noticing,
  * reports which tier it used, so no one can accidentally quote software-model
    timings as accelerator performance.

TIERS
  1. "mmio"           real hardware, if ACCEL_DEV names a device
  2. "software-model" the C extension's bit-accurate model of the hardware
  3. "python"         pure Python, if the extension is not built at all

Tier 3 is what makes the design honest: the benchmark still runs correctly on a
machine with no accelerator and no compiler. It is slow, and it is meant to be.
"""
from __future__ import annotations

import array
import math
import struct

# ---------------------------------------------------------------------------
try:
    import _accel                       # the C extension
    _HAVE_EXT = True
except ImportError:                     # not built: fall through to pure Python
    _accel = None
    _HAVE_EXT = False

WORDS_PER_BODY = 8                      # x y z vx vy vz mass pad


def backend() -> str:
    """Which tier is actually in use. Call this before quoting any timing."""
    if _HAVE_EXT:
        return _accel.backend()
    return "python"


def have_device() -> bool:
    return bool(_HAVE_EXT and _accel.have_device())


# ---------------------------------------------------------------------------
# pure-Python tier: a readable reference, and the thing that keeps the benchmark
# working with no extension present. Deliberately mirrors the hardware's
# structure so all three tiers agree.
# ---------------------------------------------------------------------------
_LUT_BITS = 6
_NR_ITERS = 2
_NPART = 4


def _f32(x: float) -> float:
    return struct.unpack("<f", struct.pack("<f", x))[0]


def _build_lut():
    half = 1 << (_LUT_BITS - 1)
    lut = []
    for parity in (0, 1):
        for j in range(half):
            lo_m, hi_m = j / half, (j + 1) / half
            if parity == 0:
                lo, hi = 1.0 + lo_m, 1.0 + hi_m
            else:
                lo, hi = 2.0 + 2.0 * lo_m, 2.0 + 2.0 * hi_m
            lut.append(int(round(1.0 / math.sqrt(0.5 * (lo + hi)) * 16384)))
    return lut


_LUT = _build_lut()


def py_rsqrt(x: float) -> float:
    """1/sqrt(x) exactly as the RTL computes it: LUT seed + 2 Newton steps."""
    bits = struct.unpack("<I", struct.pack("<f", _f32(x)))[0]
    E = ((bits >> 23) & 0xFF) - 127
    man = bits & 0x7FFFFF
    parity = E & 1
    k = (E - parity) >> 1
    idx = (parity << (_LUT_BITS - 1)) | (man >> (23 - (_LUT_BITS - 1)))
    y = _f32(math.ldexp(_LUT[idx] / 16384.0, -k))
    for _ in range(_NR_ITERS):
        y2 = _f32(y * y)
        xy2 = _f32(_f32(x) * y2)
        t = _f32(1.5 - _f32(0.5 * xy2))
        y = _f32(y * t)
    return y


def py_dot3(ax, ay, az, bx, by, bz) -> float:
    """Adder-tree shape ((p0+p1)+p2), matching dot3.sv. Not associative, so the
    shape is part of the specification rather than an implementation detail."""
    p0 = _f32(_f32(ax) * _f32(bx))
    p1 = _f32(_f32(ay) * _f32(by))
    p2 = _f32(_f32(az) * _f32(bz))
    return _f32(_f32(p0 + p1) + p2)


def _py_nbody_step(buf, n_bodies: int, dt: float, n_steps: int) -> None:
    f = buf                              # array('f'), mutated in place
    dt = _f32(dt)
    for _ in range(n_steps):
        for i in range(n_bodies):
            bi = i * WORDS_PER_BODY
            px = [0.0] * _NPART
            py = [0.0] * _NPART
            pz = [0.0] * _NPART
            k = 0
            for j in range(n_bodies):
                if j == i:
                    continue
                bj = j * WORDS_PER_BODY
                dx = _f32(f[bi + 0] - f[bj + 0])
                dy = _f32(f[bi + 1] - f[bj + 1])
                dz = _f32(f[bi + 2] - f[bj + 2])
                d2 = py_dot3(dx, dy, dz, dx, dy, dz)
                r = py_rsqrt(d2)
                r3 = _f32(_f32(r * r) * r)
                mag = _f32(dt * r3)
                b2m = _f32(f[bj + 6] * mag)
                px[k] = _f32(px[k] + _f32(-_f32(dx * b2m)))
                py[k] = _f32(py[k] + _f32(-_f32(dy * b2m)))
                pz[k] = _f32(pz[k] + _f32(-_f32(dz * b2m)))
                k = (k + 1) % _NPART
            f[bi + 3] = _f32(f[bi + 3] + _f32(_f32(px[0] + px[1]) + _f32(px[2] + px[3])))
            f[bi + 4] = _f32(f[bi + 4] + _f32(_f32(py[0] + py[1]) + _f32(py[2] + py[3])))
            f[bi + 5] = _f32(f[bi + 5] + _f32(_f32(pz[0] + pz[1]) + _f32(pz[2] + pz[3])))
        for i in range(n_bodies):
            bi = i * WORDS_PER_BODY
            f[bi + 0] = _f32(f[bi + 0] + _f32(dt * f[bi + 3]))
            f[bi + 1] = _f32(f[bi + 1] + _f32(dt * f[bi + 4]))
            f[bi + 2] = _f32(f[bi + 2] + _f32(dt * f[bi + 5]))


# ---------------------------------------------------------------------------
# public API — one batched call per kernel
# ---------------------------------------------------------------------------
def nbody_step(buf, n_bodies: int, dt: float, n_steps: int = 1) -> None:
    """Advance n_bodies for n_steps timesteps, in place.

    buf must be a writable float32 buffer of n_bodies * 8 words laid out
    x y z vx vy vz mass pad -- accel_top.sv's documented memory layout.

    ONE call per BATCH, and n_steps exists precisely so the batch can be large.
    Calling this once per timestep with nbody's 5 bodies would leave the measured
    595 ns crossing at 87% of the call; the crossing only becomes negligible when
    thousands of pair computations happen per call.
    """
    if len(buf) < n_bodies * WORDS_PER_BODY:
        raise ValueError("buffer too small: need n_bodies * 8 float32 words")
    if _HAVE_EXT:
        _accel.nbody_step(buf, n_bodies, dt, n_steps)
    else:
        _py_nbody_step(buf, n_bodies, dt, n_steps)


def ray_intersect(cp, rv, r2, count: int):
    """Batched ray/sphere intersection.

    cp: 3*count float32 (sphere centre - ray origin)
    rv: 3*count float32 (ray direction, NORMALISED, as Ray.__init__ guarantees)
    r2: count float32   (radius squared, matching the software optimization)
    returns (t, hit) as array('f') and array('B'). t is MEANINGLESS where hit is
    0 -- the hardware declares it invalid rather than returning a plausible
    number for a ray that missed.
    """
    out_t = array.array("f", [0.0]) * count if False else array.array("f", [0.0] * count)
    out_h = array.array("B", [0] * count)
    if _HAVE_EXT:
        _accel.ray_intersect(bytes(cp), bytes(rv), bytes(r2), out_t, out_h, count)
    else:
        for i in range(count):
            cx, cy, cz = cp[3*i], cp[3*i+1], cp[3*i+2]
            vx, vy, vz = rv[3*i], rv[3*i+1], rv[3*i+2]
            v = py_dot3(cx, cy, cz, vx, vy, vz)
            cc = py_dot3(cx, cy, cz, cx, cy, cz)
            disc = _f32(_f32(r2[i]) - _f32(cc - _f32(v * v)))
            if disc < 0.0:
                out_t[i], out_h[i] = 0.0, 0
            else:
                out_t[i] = _f32(v - _f32(disc * py_rsqrt(disc)))
                out_h[i] = 1
    return out_t, out_h


def perf_counters():
    """(pairs, cycles) from the hardware CSRs. Only meaningful on real hardware:
    they are registers, not a simulation artefact."""
    if not have_device():
        raise RuntimeError("no device: performance counters are hardware registers")
    return _accel.perf_counters()


def make_buffer(bodies):
    """Pack [(pos, vel, mass), ...] into the accelerator's memory layout."""
    buf = array.array("f", [0.0] * (len(bodies) * WORDS_PER_BODY))
    for i, (pos, vel, mass) in enumerate(bodies):
        o = i * WORDS_PER_BODY
        buf[o+0], buf[o+1], buf[o+2] = pos
        buf[o+3], buf[o+4], buf[o+5] = vel
        buf[o+6] = mass
    return buf


def read_buffer(buf, n_bodies):
    """Unpack the accelerator's layout back into [(pos, vel, mass), ...]."""
    out = []
    for i in range(n_bodies):
        o = i * WORDS_PER_BODY
        out.append(([buf[o+0], buf[o+1], buf[o+2]],
                    [buf[o+3], buf[o+4], buf[o+5]],
                    buf[o+6]))
    return out
