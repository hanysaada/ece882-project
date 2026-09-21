#!/usr/bin/env python3
"""
call_overhead.py — measure what it costs to cross the Python boundary.

WHY THIS IS THE MOST IMPORTANT MEASUREMENT IN THE HARDWARE PROPOSAL
-------------------------------------------------------------------
The accelerator's dot3+rsqrt pipeline has a latency of ~34 cycles and an
initiation interval of 1. At 500 MHz that is ~68 ns of latency and one result
every 2 ns once the pipe is full.

If the accelerator is exposed to Python as a per-operation function --
`accel.rsqrt(d2)` called once per body pair -- then every result costs one
Python->C round trip. If that round trip costs more than the operation, the
hardware wins nothing: you build a fast unit and hand the entire gain back at the
interface.

So the design question is not "how fast is the datapath" but "how much work can
we hand over per crossing". This script MEASURES the crossing cost instead of
quoting a number from memory, which is what the phase plan requires.

Run:  python3 hw/golden/call_overhead.py
"""
from __future__ import annotations

import ctypes
import ctypes.util
import math
import statistics
import sys
import time

N = 200_000          # calls per timed batch
REPEATS = 7          # take the median of this many batches


def bench(label, fn, n=N, repeats=REPEATS):
    """Median per-call time, in nanoseconds. Median, not mean, because an OS
    hiccup during one batch should not move the answer."""
    times = []
    for _ in range(repeats):
        t0 = time.perf_counter_ns()
        fn(n)
        t1 = time.perf_counter_ns()
        times.append((t1 - t0) / n)
    med = statistics.median(times)
    spread = max(times) - min(times)
    print(f"  {label:<46} {med:8.1f} ns/call   (spread {spread:.1f})")
    return med


print("=" * 78)
print("PYTHON BOUNDARY-CROSSING COST")
print(f"python {sys.version.split()[0]}  |  {N} calls per batch, "
      f"median of {REPEATS}")
print("=" * 78)
print()

# ---------------------------------------------------------------------------
# Baseline: an empty Python loop. Everything else must have this subtracted
# mentally, because the loop itself costs something.
# ---------------------------------------------------------------------------
print("Reference points (not boundary crossings):")


def empty_loop(n):
    for _ in range(n):
        pass


t_loop = bench("empty Python loop iteration", empty_loop)


def py_noop_call(n):
    def f(x):
        return x
    for i in range(n):
        f(i)


t_pycall = bench("call a trivial PYTHON function", py_noop_call)


def builtin_sqrt(n):
    sqrt = math.sqrt
    for i in range(n):
        sqrt(2.0)
    return None


t_sqrt = bench("call math.sqrt (a C builtin, fast path)", builtin_sqrt)

# ---------------------------------------------------------------------------
# The real measurement: a ctypes call into libm. ctypes is the most likely way a
# student-built accelerator driver would first be exposed to Python, and it is a
# genuine foreign-function boundary crossing: argument conversion, the call, and
# result conversion.
#
# A hand-written CPython C extension is faster than ctypes (no per-call argument
# marshalling through libffi), so ctypes is an UPPER bound and math.sqrt above is
# close to a LOWER bound for a C-level call. Quoting both brackets the answer
# honestly rather than picking the flattering one.
# ---------------------------------------------------------------------------
print()
print("Foreign-function boundary crossings:")

libm_name = ctypes.util.find_library("m")
libm = ctypes.CDLL(libm_name if libm_name else "libm.so.6")

c_sqrt = libm.sqrt
c_sqrt.argtypes = [ctypes.c_double]
c_sqrt.restype = ctypes.c_double


def ctypes_sqrt(n):
    f = c_sqrt
    for i in range(n):
        f(2.0)


t_ctypes = bench("ctypes call into libm sqrt()", ctypes_sqrt)


# A call taking several doubles, which is what a per-operation accelerator API
# would actually look like: accel_dot3(ax,ay,az,bx,by,bz).
c_fma = libm.fma
c_fma.argtypes = [ctypes.c_double, ctypes.c_double, ctypes.c_double]
c_fma.restype = ctypes.c_double


def ctypes_fma3(n):
    f = c_fma
    for i in range(n):
        f(1.5, 2.5, 3.5)


t_ctypes3 = bench("ctypes call with 3 double arguments", ctypes_fma3)

# ---------------------------------------------------------------------------
print()
print("=" * 78)
print("WHAT THIS MEANS FOR THE ACCELERATOR INTERFACE")
print("=" * 78)

# Hardware figures from the RTL's stated contracts.
F_MHZ = 500.0
CYCLE_NS = 1000.0 / F_MHZ                      # 2.0 ns at 500 MHz
DOT3_LAT = 9
RSQRT_LAT = 25
PAIR_LAT = DOT3_LAT + RSQRT_LAT                # 34 cycles end to end
PAIR_LAT_NS = PAIR_LAT * CYCLE_NS
II_NS = 1 * CYCLE_NS                           # one result per cycle

print(f"""
Hardware, from the RTL interface contracts at {F_MHZ:.0f} MHz
  dot3 latency          {DOT3_LAT} cycles
  rsqrt latency         {RSQRT_LAT} cycles
  pair kernel latency   {PAIR_LAT} cycles = {PAIR_LAT_NS:.0f} ns
  initiation interval   1 cycle = {II_NS:.0f} ns  -> one result every {II_NS:.0f} ns

Measured boundary crossing
  cheapest C-level call (math.sqrt)   {t_sqrt:.1f} ns
  ctypes call, 1 argument             {t_ctypes:.1f} ns
  ctypes call, 3 arguments            {t_ctypes3:.1f} ns
""")

print(f"""PER-OPERATION INTERFACE (one call per body pair)
  cost per pair = crossing + kernel
                = {t_ctypes3:.1f} ns + {PAIR_LAT_NS:.0f} ns = {t_ctypes3 + PAIR_LAT_NS:.0f} ns
  The crossing alone is {t_ctypes3 / PAIR_LAT_NS:.2f}x the entire hardware latency, and
  {t_ctypes3 / II_NS:.0f}x the pipeline's throughput interval. The unit would spend
  almost all its time waiting for Python. This design is dead on arrival.
""")

# Batched: one call per timestep. nbody has 5 bodies -> 10 unique pairs.
PAIRS_PER_STEP = 10
for pairs in (PAIRS_PER_STEP, 100, 1000, 10000):
    total = t_ctypes3 + pairs * II_NS + PAIR_LAT_NS   # one crossing, then stream
    per_pair = total / pairs
    frac = t_ctypes3 / total
    print(f"  BATCHED, {pairs:>6} pairs per call: "
          f"{per_pair:7.2f} ns/pair, crossing is {100*frac:5.1f}% of the call")

print(f"""
The conclusion the presentation should land: hardware acceleration here is an
INTERFACE problem at least as much as a datapath problem. The datapath is easy --
three multipliers, an adder tree, a small table and two Newton steps. What decides
whether any of that speedup survives is how much work crosses the boundary per
call.

nbody's own configuration is only {PAIRS_PER_STEP} pairs per timestep (5 bodies), so batching
per timestep is not enough on its own: at {PAIRS_PER_STEP} pairs the crossing is still a large
fraction of the call. The right granularity is one descriptor per MANY timesteps --
the CPU hands over the body array and a step count, and the engine runs the whole
inner loop, writing state back only at the end. That is why accel_top.sv is built
around a DMA engine and a descriptor, not around a memory-mapped register you poke
once per operation.

For raytrace the batching is natural and much larger: one call per ray against all
scene objects, and the benchmark traces 100x100 = 10,000 primary rays plus
reflection and shadow rays, so thousands of intersection tests per call are
available.
""")
