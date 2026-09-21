#!/usr/bin/env python3
"""
amdahl.py — quantitative acceleration justification, built from measured data.

EVERY INPUT HERE IS EITHER MEASURED OR AN EXPLICITLY LABELLED ASSUMPTION.
The point of this script is that the speedup claim is a BOUND with stated
assumptions, never a promise. Amdahl's law is unforgiving and the honest answer is
usually smaller than the one people quote.

    S_total = 1 / ((1 - f) + f / S_kernel)

  f        fraction of ORIGINAL runtime spent in the part being accelerated
  S_kernel speedup of that part alone

The two consequences to be able to state instantly:
  * if f = 0.4 then even with S_kernel -> infinity, S_total caps at 1.67x
  * to reach 2x total you need f >= 0.5 no matter how good the hardware is

Run:  python3 hw/golden/amdahl.py
"""
from __future__ import annotations

# ===========================================================================
# MEASURED INPUTS — every number below traces to a file in results/
# ===========================================================================

# --- from results/perf/HOTSPOTS.md (py-spy, leaf-frame attribution) ---------
# nbody: the accelerable kernel is the pair-force computation. Line 85 is the
# distance-and-inverse-power calculation; lines 88-93 are the six velocity
# updates, which the accelerator also performs.
NBODY_LINE85 = 0.220          # advance() line 85  -- d2 and d2**-1.5
NBODY_VEL_UPDATES = 0.299     # lines 88,89,90,91,92,93 summed (4.8+4.9+5.6+4.9+5.4+4.2)

# raytrace: the accelerable kernel is the ray/sphere intersection test plus the
# vector arithmetic feeding it.
RT_INTERSECT = 0.093          # intersectionTime lines 143 (3.5) + 144 (1.7) + 145 (4.1)
RT_DOT       = 0.138          # dot lines 52 (3.5) + 53 (10.3)
RT_MAGNORM   = 0.044          # magnitude:36 (2.2) + normalized:62 (2.2)
RT_SUB115    = 0.156          # __sub__:115 -- the Vector allocation the batched
                              # call removes entirely
RT_LIGHTVIS  = 0.089          # _lightIsVisible:285 -- builds a Ray per light per
                              # object; these are intersection tests too

# --- from results/compare/SUMMARY.md (Phase 4, host, release python3) -------
NBODY_BASE_MS = 96.7
NBODY_OPT_MS  = 83.8
RT_BASE_MS    = 312.6
RT_OPT_MS     = 218.4

# --- from results/hw/call_overhead.txt (measured with ctypes) ---------------
CROSSING_NS = 595.0          # ctypes call with 3 double arguments

# --- from the RTL interface contracts (hw/rtl/*.sv headers) -----------------
F_MHZ            = 500.0     # ASSUMPTION: target frequency, not synthesised
CYCLE_NS         = 1000.0 / F_MHZ
PE_PAIR_LATENCY  = 49        # cycles, verified in simulation
PE_RAY_LATENCY   = 49        # cycles, verified in simulation
II               = 1         # cycles between successive inputs, verified

# --- benchmark configuration (from the benchmark sources) -------------------
NBODY_BODIES     = 5
NBODY_STEPS      = 20000
RT_W = RT_H      = 100
RT_OBJECTS       = 8         # 1 big sphere + 6 small + 1 halfspace
RT_LIGHTS        = 2

BYTES_PER_BODY   = 32        # accel_top.sv documented layout, 8 words


def amdahl(f: float, s_kernel: float) -> float:
    if s_kernel <= 0:
        return 1.0
    return 1.0 / ((1.0 - f) + f / s_kernel)


def ceiling(f: float) -> float:
    """Speedup with an infinitely fast kernel: the hard bound."""
    return 1.0 / (1.0 - f) if f < 1.0 else float("inf")


def rule(c="=", n=78):
    print(c * n)


# ===========================================================================
print()
rule()
print("QUANTITATIVE ACCELERATION JUSTIFICATION")
rule()
print("""
All fractions come from results/perf/HOTSPOTS.md (py-spy leaf-frame attribution,
host, Python 3.12). All timings come from results/compare/SUMMARY.md. The boundary
crossing comes from results/hw/call_overhead.txt. Frequency and area figures are
ASSUMPTIONS and are labelled as such -- nothing here was synthesised.
""")

# ---------------------------------------------------------------------------
rule("-")
print("STEP 1 — what fraction f can the accelerator actually replace?")
rule("-")

f_nbody = NBODY_LINE85 + NBODY_VEL_UPDATES
print(f"""
nbody
  line 85, d2 and d2**-1.5                       {NBODY_LINE85:.3f}
  lines 88-93, the six velocity updates          {NBODY_VEL_UPDATES:.3f}
  ------------------------------------------------------
  f_nbody                                        {f_nbody:.3f}

  The accelerator performs both: pe_pair computes d2 via dot3, the inverse power
  via rsqrt, and emits the six scaled deltas. So the whole pair-interaction body
  of advance() is replaced, not merely the sqrt.

  NOT included, deliberately: the interpreter overhead that surrounds these lines.
  py-spy attributes samples to the Python line, so interpreter dispatch is already
  inside these numbers -- counting it again would be double counting.""")

f_rt = RT_INTERSECT + RT_DOT + RT_MAGNORM + RT_SUB115 + RT_LIGHTVIS
f_rt_narrow = RT_INTERSECT + RT_MAGNORM
print(f"""
raytrace -- two framings, and the difference IS the argument

  (a) NARROW: "the accelerator makes sqrt and dot faster"
      intersectionTime 143+144+145                 {RT_INTERSECT:.3f}
      magnitude + normalized                       {RT_MAGNORM:.3f}
      ------------------------------------------------------
      f_narrow                                     {f_rt_narrow:.3f}
      ceiling with infinite hardware               {ceiling(f_rt_narrow):.2f}x

  (b) BATCHED: "one call replaces the whole Python vector-math layer"
      intersectionTime 143+144+145                 {RT_INTERSECT:.3f}
      dot 52+53 (incl. the do-nothing type guard)  {RT_DOT:.3f}
      magnitude + normalized                       {RT_MAGNORM:.3f}
      __sub__:115, the Vector allocation removed   {RT_SUB115:.3f}
      _lightIsVisible:285, shadow-ray tests        {RT_LIGHTVIS:.3f}
      ------------------------------------------------------
      f_batched                                    {f_rt:.3f}
      ceiling with infinite hardware               {ceiling(f_rt):.2f}x

  Phase 2 measured that raytrace is allocation-bound, not math-bound: NO sqrt
  appears above the 0.5% cutoff in its C-level profile, while subtype_dealloc is
  3.11%, _PyObject_Malloc 1.95% and slot_tp_init 1.65%. Framing (a) is therefore
  the honest reading of "a faster sqrt" -- and it caps at {ceiling(f_rt_narrow):.2f}x, which would
  not survive the question "what is your f for raytrace?".
  Framing (b) is defensible only because a BATCHED interface genuinely removes the
  allocations and method calls, not just the arithmetic. That is why accel_top is
  built around a descriptor.""")

# ---------------------------------------------------------------------------
rule("-")
print("STEP 2 — the ceilings, before any hardware is designed")
rule("-")
print(f"""
  benchmark          f       ceiling (S_kernel -> infinity)
  ---------------------------------------------------------
  nbody            {f_nbody:.3f}    {ceiling(f_nbody):.2f}x
  raytrace (b)     {f_rt:.3f}    {ceiling(f_rt):.2f}x
  raytrace (a)     {f_rt_narrow:.3f}    {ceiling(f_rt_narrow):.2f}x

These are HARD BOUNDS. No accelerator, however fast, beats them. Stating the
ceiling before quoting a speedup is the difference between an engineering estimate
and a sales pitch.""")

# ---------------------------------------------------------------------------
rule("-")
print("STEP 3 — what S_kernel can the hardware plausibly deliver?")
rule("-")

# nbody: pairs per timestep. accel_top computes n(n-1) because it does not use
# Newton's third law (see the read-after-write hazard discussion in accel_top.sv).
pairs_per_step = NBODY_BODIES * (NBODY_BODIES - 1)
total_pairs = pairs_per_step * NBODY_STEPS
# Hardware: one pair per cycle once streaming, plus pipeline fill per timestep,
# plus one boundary crossing for the whole run.
hw_cycles = NBODY_STEPS * (pairs_per_step + PE_PAIR_LATENCY + NBODY_BODIES)
hw_ns = hw_cycles * CYCLE_NS + CROSSING_NS
# Software: the measured time spent in the accelerated fraction.
sw_kernel_ns = NBODY_OPT_MS * 1e6 * f_nbody
s_kernel_nbody = sw_kernel_ns / hw_ns

print(f"""
nbody, from the descriptor interface accel_top actually implements
  bodies                                    {NBODY_BODIES}
  pairs per timestep, n(n-1)                {pairs_per_step}
      accel_top does NOT use Newton's third law: accumulating onto both bodies of
      a pair is a read-after-write hazard on in-flight state, so it computes each
      direction separately. 2x the pair work, but II stays 1.
  timesteps                                 {NBODY_STEPS}
  total pairs                               {total_pairs:,}

  hardware cycles = steps x (pairs + fill + integrate)
                  = {NBODY_STEPS} x ({pairs_per_step} + {PE_PAIR_LATENCY} + {NBODY_BODIES}) = {hw_cycles:,}
  hardware time   = {hw_cycles:,} x {CYCLE_NS:.1f} ns + {CROSSING_NS:.0f} ns crossing
                  = {hw_ns/1e6:.3f} ms
  software time in that fraction
                  = {NBODY_OPT_MS} ms x {f_nbody:.3f} = {sw_kernel_ns/1e6:.3f} ms

  S_kernel        = {s_kernel_nbody:.1f}x

  NOTE the pipeline fill dominates here: {PE_PAIR_LATENCY} cycles of fill against only
  {pairs_per_step} pairs of work per timestep, so the engine is only
  {100.0*pairs_per_step/(pairs_per_step+PE_PAIR_LATENCY+NBODY_BODIES):.0f}% utilised.
  With 5 bodies this workload is far too small to fill a 49-stage pipeline. That is
  a REAL limitation of accelerating this benchmark and must be said out loud.""")

# raytrace: intersection tests per frame
prim_rays = RT_W * RT_H
# each primary ray tests all objects; plus shadow rays per light per hit; plus
# reflection rays to depth 3. A conservative estimate:
tests_per_frame = prim_rays * RT_OBJECTS * (1 + RT_LIGHTS)
rt_hw_cycles = tests_per_frame + PE_RAY_LATENCY
rt_hw_ns = rt_hw_cycles * CYCLE_NS + CROSSING_NS
rt_sw_kernel_ns = RT_OPT_MS * 1e6 * f_rt
s_kernel_rt = rt_sw_kernel_ns / rt_hw_ns

print(f"""
raytrace
  primary rays, {RT_W}x{RT_H}                        {prim_rays:,}
  objects in the scene                      {RT_OBJECTS}
  lights (each needs a shadow ray per hit)  {RT_LIGHTS}
  ASSUMPTION: intersection tests per frame  {tests_per_frame:,}
      = rays x objects x (1 + lights). Conservative: it ignores reflection rays
      (recursion depth 3), so the real count is higher and S_kernel would improve.

  hardware cycles = {tests_per_frame:,} + {PE_RAY_LATENCY} fill = {rt_hw_cycles:,}
  hardware time   = {rt_hw_ns/1e6:.3f} ms  (crossing amortised over {tests_per_frame:,} tests)
  software time in that fraction
                  = {RT_OPT_MS} ms x {f_rt:.3f} = {rt_sw_kernel_ns/1e6:.3f} ms

  S_kernel        = {s_kernel_rt:.1f}x

  Here the pipeline IS well fed: {tests_per_frame:,} tests against 49 cycles of fill means
  {100.0*tests_per_frame/rt_hw_cycles:.1f}% utilisation. raytrace is the better fit for this
  accelerator, which is the opposite of what the naive "nbody is the FP benchmark"
  intuition suggests.""")

# ---------------------------------------------------------------------------
rule("-")
print("STEP 4 — total speedup, and the sensitivity that matters")
rule("-")

for name, f, sk in (("nbody", f_nbody, s_kernel_nbody),
                    ("raytrace", f_rt, s_kernel_rt)):
    st = amdahl(f, sk)
    print(f"""
{name}:  f = {f:.3f}, S_kernel = {sk:.1f}x
  S_total = 1 / ((1 - {f:.3f}) + {f:.3f}/{sk:.1f}) = {st:.3f}x
  ceiling                                        = {ceiling(f):.3f}x
  fraction of the ceiling captured               = {100*(st-1)/(ceiling(f)-1):.1f}%""")

print("""
SENSITIVITY. The question "what if your kernel estimate is 2x off?" has to have an
immediate answer, so here is the whole surface. Rows are f, columns are S_kernel.
""")
print(f"  {'f':>6} | " + " ".join(f"{s:>7}x" for s in (2, 5, 10, 20, 50, 100, 1000)))
print("  " + "-" * 72)
for f in (0.10, 0.20, 0.30, 0.40, 0.50, 0.52, 0.68, 0.80):
    row = " ".join(f"{amdahl(f, s):>7.2f}" for s in (2, 5, 10, 20, 50, 100, 1000))
    mark = ""
    if abs(f - round(f_nbody, 2)) < 0.011:
        mark = "  <- nbody"
    if abs(f - round(f_rt, 2)) < 0.011:
        mark = "  <- raytrace"
    print(f"  {f:>6.2f} | {row}{mark}")

print(f"""
Read across any row: past S_kernel ~20x the numbers barely move. That is the whole
lesson of Amdahl's law -- once the kernel is fast enough that f/S_kernel is small
compared with (1-f), further kernel speedup buys almost nothing. Spending silicon
to push S_kernel from 100x to 1000x on the f = {f_nbody:.2f} row changes the total from
{amdahl(f_nbody,100):.2f}x to {amdahl(f_nbody,1000):.2f}x.

So the engineering priority is NOT a faster datapath. It is raising f, which means
moving MORE of the program into the accelerator -- exactly what the batched
descriptor interface does, and exactly why the interface argument matters more than
the pipeline depth.""")

# ---------------------------------------------------------------------------
rule("-")
print("STEP 5 — when does the accelerator become memory-bandwidth-bound?")
rule("-")

bytes_per_pair = 2 * BYTES_PER_BODY        # two bodies read per pair (worst case)
pairs_per_s = (F_MHZ * 1e6) / II
bw_needed = bytes_per_pair * pairs_per_s / 1e9
print(f"""
ASSUMPTIONS: {BYTES_PER_BODY} B per body (accel_top's documented layout), one pair per cycle
at {F_MHZ:.0f} MHz, and the pessimistic case where nothing is reused on chip.

  bytes per pair, uncached          {bytes_per_pair} B
  pairs per second at II={II}          {pairs_per_s:.2e}
  bandwidth required                {bw_needed:.1f} GB/s

For scale, a DDR5 channel delivers roughly 50 GB/s and PCIe gen5 x16 about
64 GB/s (both from the course's own lecture 3 figures). So a SINGLE pe_pair at
{F_MHZ:.0f} MHz already needs {bw_needed:.0f} GB/s if it streams uncached -- it would be
memory-bound immediately.

What saves it is that accel_top keeps the body array ON CHIP for the whole run:
  bytes moved per run  = 2 x {NBODY_BODIES} bodies x {BYTES_PER_BODY} B = {2*NBODY_BODIES*BYTES_PER_BODY} B  (in and out, once)
  pairs computed       = {total_pairs:,}
  arithmetic intensity = {total_pairs/(2*NBODY_BODIES*BYTES_PER_BODY):.0f} pairs per byte moved

That is the real reason the descriptor carries N_STEPS. It converts a
bandwidth-bound streaming problem into a compute-bound one.

CROSSOVER for parallel PEs: with P copies of pe_pair each needing {bytes_per_pair} B/cycle
uncached, P x {bw_needed:.0f} GB/s must stay under the available bandwidth. Against 50 GB/s
that is P < {50/bw_needed:.2f}, i.e. even ONE PE exceeds it -- so replication is pointless
without on-chip reuse. With the array resident on chip, P is limited instead by
SRAM read ports: {NBODY_BODIES} bodies is tiny, but at larger n the body store would need
{2}P read ports per cycle, and beyond about 4-8 PEs that becomes the binding
constraint rather than DRAM.""")

rule()
print("SUMMARY, stated as bounds with assumptions")
rule()
print(f"""
  nbody     f = {f_nbody:.3f}  ceiling {ceiling(f_nbody):.2f}x  S_kernel {s_kernel_nbody:.0f}x  ->  S_total {amdahl(f_nbody, s_kernel_nbody):.2f}x
  raytrace  f = {f_rt:.3f}  ceiling {ceiling(f_rt):.2f}x  S_kernel {s_kernel_rt:.0f}x  ->  S_total {amdahl(f_rt, s_kernel_rt):.2f}x

Honest caveats, all of which should be volunteered rather than extracted:
  1. {F_MHZ:.0f} MHz is a TARGET, not a synthesis result. Nothing here was synthesised.
  2. nbody's 5 bodies cannot fill a 49-stage pipeline: utilisation is only
     {100.0*pairs_per_step/(pairs_per_step+PE_PAIR_LATENCY+NBODY_BODIES):.0f}%. The benchmark is too small for this hardware, and a larger n
     would look much better. Reporting the small-n case is the honest choice.
  3. S_kernel assumes the accelerated fraction disappears entirely into hardware.
     Any residual Python glue reduces it.
  4. The f values come from a Python 3.12 host profile. Jammy runs 3.10, which has
     no specialising interpreter, so interpreter-heavy lines cost MORE there and f
     would rise -- these estimates are conservative.
""")
