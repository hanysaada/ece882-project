# 05 — The results, and how to defend them

Written for a fellow ECE student who has not done this project.

## The two numbers

```
nbody     107 ms -> 96.7 ms   1.11x   ( 9.9%)
raytrace  367 ms -> 229 ms    1.60x   (37.6%)
```

Both clear the assignment's 7% requirement. Medians:

```
nbody     106 +- 3 ms   ->   95.4 +- 2.7 ms   (MAD)
raytrace  364 +- 4 ms   ->   229  +- 3   ms   (MAD)
```

Correctness:

```
nbody     total system energy after 20,000 steps, 1.313e-15 relative (gate 1e-12)
raytrace  rendered image, 30,000 bytes, EXACT match
```

## Why these numbers are trustworthy

Take this in the order a sceptical examiner would.

**1. The noise floor passes, for this exact configuration and session.** Two runs of
byte-identical baseline code come back "not significant". The claimed effects are far
above the floor. Without this, nothing else matters.

**2. All three estimators agree.** Noise does not do this:

```
mean     107   -> 96.7 ms   1.11x
median   106   -> 95.4 ms   1.11x
minimum   98.1 -> 87.3 ms   1.12x
```

The **minimum** is the most valuable of the three. It is the cleanest run observed on
each side — the one least affected by interference — and it agrees. If mean and median
moved but minimum did not, you would suspect your "speedup" was just fewer
interruptions.

**3. Measurement was interleaved.** Three rounds of (baseline, optimized) alternating,
so session drift lands on both sides equally rather than on one.

**4. The gate passed before the final ran**, logged with a shared `boot_id`. So the
criterion was not applied retroactively to justify a number already in hand.

**5. Three independent sessions agree** on byte-identical code (md5 `b651647e...`):
1.12x, 1.11x, 1.10x for nbody. Reproduction across sessions is stronger than any single
measurement, however careful.

**6. The shipped code is the measured code.** `make_variants.py` *generates*
`bm_nbody_opt/run_benchmark.py` from a named variant, so it cannot drift from what was
tested. This exists because the alternative failed once: the shipped file was still the
old variant while the ablation had already moved on, so the final comparison faithfully
measured 1.01x for an optimization we were not proposing.

## A number we measured and refused to use

One nbody run returned **1.20x** — better than what we report.

We rejected it. That morning the whole machine was ~45% slower (baseline median 147 ms
against 101 ms the previous evening, standard deviation 21%, one value at 500 ms), and
the run carried no same-session noise floor.

It is kept in `results/` as `nbody_final_noisy_20260921_kvm.txt` with a note saying not
to cite it.

Adopting the largest number you measured is the easiest thing in the world and it is
precisely what makes a result worthless. Being able to point at a rejected favourable
result is worth more than the extra 0.09x would have been.

## The ablation tables — per-change attribution

### nbody (variants branch; see below)

```
v1_sqrt          NOT SIGNIFICANT
v2_localsqrt     1.02x
v3_slicewrite    NOT SIGNIFICANT
v4_struct        1.12x    <-- SHIPPED
v5_struct_sqrt   1.01x SLOWER than v4
```

### raytrace (cumulative)

```
                 alone          cumulative
v1_noguards      1.10x            1.10x
v2_slots         1.13x            1.25x
v3_radius2   not significant      1.24x
v4_inline        1.29x            1.61x    <-- SHIPPED
```

## The one subtlety in the nbody table

nbody's variants are **not one chain**:

```
baseline ──┬── v1_sqrt ── v2_localsqrt ── v3_slicewrite
           │
           └── v4_struct ── v5_struct_sqrt
               ▲
               SHIPPED
```

v4 branches off the **baseline again**, deliberately, so that `** (-1.5)` is held
identical on both sides of its comparison and the measured delta is purely structural.

This matters practically. Our ablation script originally assumed each variant extended
the alphabetically previous one, so it reported v4 "vs v3" — comparing two variants that
share no ancestry and attributing the difference to a change **neither of them made**.

Fixed by declaring each variant's real parent in `benchmarks/ablation/PARENTS`. The
script now reads it and refuses to guess: it dies if a parent is undeclared or
unmeasured.

The lesson: an ablation table's "this change alone" column is only meaningful against the
**actual parent**. Getting that wrong produces confident nonsense.

## What the two benchmarks tell you together

They have completely different bottlenecks, and that is the most interesting outcome.

| | nbody | raytrace |
|---|---|---|
| bound by | arithmetic + list indexing | function calls + allocation |
| `sqrt`/`pow` share | 2.79% | **0.065%** |
| what worked | restructuring the loop | removing calls and dict lookups |
| arithmetic changed? | yes (reassociation) | **none at all** |
| result | 1.11x | 1.60x |

raytrace gave 1.60x without changing a single calculation. In a pure-Python program,
**overhead is the workload.**

## The negative results, which are the strongest part

Three things failed, each with a mechanism we can name. Do not hide these — lead with
them.

**1. The textbook nbody optimization gains nothing here.** Replacing `** (-1.5)` with
`sqrt` removes the `pow()` chain *completely* — 2.79% of cycles to 0.00% — and buys ~2%,
because that is all there was. On our host the same chain was ~9%.

The cause is a named glibc dispatch difference:

```
glibc 2.26   __ieee754_pow_sse2   ~9%
glibc 2.35   __ieee754_pow_fma    2.13%
```

Two different symbols in two profiles. **The optimization is platform-specific**, and we
can prove it rather than speculate.

The mechanism, stated precisely: `**` is an *inline opcode*, `sqrt(x)` is a *call*. When
`pow()` is cheap, trading an inline op for a call is a losing trade.

**2. It fails even after the structure is fixed.** v5 tested the composition — `sqrt` as
a fast local, on top of v4's hoisting. It came out **1.01x slower than v4**. That closes
the question rather than leaving it open.

**3. Fewer instructions is not less work.** nbody v3 replaced six index writes with two
slice writes. The slice builds a temporary tuple (an allocation) and dispatches through
general `PySequence_SetSlice`. Not significant here; 1.21x *slower* on the host.

## An imperfection we disclosed rather than buried

v4's second loop (the position update, 100,000 iterations) is slightly worse than the
baseline's — 44 to 47 bytecode instructions per iteration, because it re-reads `v[0]`,
`v[1]`, `v[2]` instead of unpacking. Collateral from rewriting the loop target.

Not measured, because nbody already clears the bar and inventing a number would be worse
than saying so. Reverting that loop should recover a little.

## Questions you should expect, and the short answers

**"Why is nbody's speedup so much smaller?"**
Because nbody was already efficient at the thing everyone optimizes. `pow()` is 2.79%
here, not 9%, and we can name the glibc symbol that explains it. What was left was
structural overhead, and we removed ~10% of it.

**"How do I know this isn't noise?"**
The noise floor for this exact configuration and session says "not significant", mean,
median and minimum all agree, and three separate sessions reproduce it on byte-identical
code.

**"Did you verify correctness?"**
nbody: conserved energy to 1.3e-15 against a 1e-12 gate — a physical law, not a golden
file. raytrace: 30,000 bytes exact. The gate runs *before* any timing and the runner
refuses to measure a variant that fails it.

**"Why is the energy not exactly equal?"**
Folding the constant `dt` into the masses reassociates a floating-point multiply, and FP
multiplication is not associative. 1.3e-15 is five orders inside tolerance. A 1e-6
residual would be a bug.

**"Why `median` and not `mean`?"**
The distribution has a tight centre and a long tail — a VM with occasional host
interference. The median describes the typical run; the mean is dragged by the
interrupted ones. We report both.

**"Would these results hold on another machine?"**
raytrace's almost certainly — its wins are interpreter-level and independent of `libm`.
nbody's v4 too, for the same reason: it deliberately holds `pow` constant. But nbody's
*v1* demonstrably would not, and that is the point of including it.

**"Why 2 vCPUs when the course command gives 1?"**
The course specifies no CPU count; 1 is just QEMU's default when `-smp` is omitted. We
attempted to measure whether it mattered and the check was confounded by machine state,
so we record it as inconclusive and make no claim either way.

## Where everything lives

```
results/compare/*_noise_floor_*.txt   the floors -- read these first
results/compare/*_ablation_*.txt      per-change attribution
results/compare/*_final_*.txt         the graded before/after
results/compare/nbody_session_*.txt   boot_id provenance log
results/json/*.json                   raw pyperf data -- every table is recomputable
results/perf/HOTSPOTS.md              the hotspot analysis
results/flamegraphs/*.svg             baseline, optimized, differential
results/ENVIRONMENT.md                the machine, exactly
```

Every number in any report traces to one of these. That was a hard rule throughout: if
a value cannot be pointed at in a file a real command produced, it does not get stated.
