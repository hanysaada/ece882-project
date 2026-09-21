# 01 — Measuring, and knowing when a number means nothing

Written for a fellow ECE student who has not done this project.

## The question that comes before any optimization

The assignment wants a >= 7% improvement. So the first question is not "how do I
make this faster" — it is:

> **Can this machine reliably detect a 7% change at all?**

If your measurement error is 10%, then a genuine 7% speedup is invisible and a
measured 7% "speedup" is probably noise. You would have no result either way, no
matter how good your optimization was.

## The noise floor — the single most useful idea in this project

Run the unmodified benchmark. Then run the **unmodified benchmark again**. Compare
the two runs.

The code is byte-identical, so the true difference is **exactly zero by
construction**. Whatever number you observe is therefore pure measurement error. That
number is your floor: the smallest effect you could ever honestly claim.

```
# Noise floor for nbody
# Two runs of IDENTICAL baseline code. Any difference is measurement
# noise, not a real effect. An optimization must beat this to count.
# processes=60 values=5  interpreter=Python 3.10.12

Benchmark hidden because not significant (1): nbody
```

**`not significant` is the goal, not a failure.** It means pyperf could not tell the
two runs apart — which is correct, because they are the same program. If your floor
comes back "1.10x faster", your measurement setup is broken, because a program cannot
be 10% faster than itself.

Our final floors:

```
nbody     -p 60 -n 5   not significant   median 99.8 +- 2.0 ms
raytrace  -p 20 -n 3   not significant   median 364  +- 4   ms
```

## This did not work first time

Three separate times the floor told us something was wrong. Each time it was right.

**Attempt 1, on TCG:** raytrace's floor came back **31%**, with a standard deviation
26% of the mean and individual values ranging 14.4 s to 39.1 s. Unusable. That is what
sent us to KVM.

**Attempt 2, on KVM:** nbody's floor came back **1.10x** at `-p 20 -n 3`. A 10%
difference between a program and itself.

The fix was more samples: `-p 60 -n 5` is 60 processes x 5 values = **360
measurements per side**, up from 60. Result: not significant.

That outcome is itself informative. If the environment were fundamentally unstable,
more samples would not have helped — you cannot average away a systematic problem. The
fact that they *did* help proves the 10% was a small-sample artefact. Cost: 156
seconds per floor, which is nothing compared to what it licenses.

**Attempt 3, a trap we nearly fell into:** we compared a 1-vCPU configuration against
a 2-vCPU one and it appeared to show 1 vCPU was 40% slower with failing floors. It was
measured on a morning when the whole machine was degraded. Within the *same* session,
1 vCPU (140 +- 4 ms) and 2 vCPU (147 +- 7 ms) were indistinguishable; the 40% gap was
against the *previous evening's* 99.8 ms. The comparison separated sessions, not
configurations. Recorded as confounded, no claim drawn.

## The rule that falls out of attempt 3

> **A noise floor only licenses claims measured the same way, in the same session.**

Not just the same machine — the same `-p`/`-n` settings, and ideally the same boot.
We very nearly published an nbody speedup whose floor was measured at a different
configuration.

This is why nbody has *two* complete baseline sessions in `results/`:

```
_kvm      2026-09-20 18:09   the baseline the ABLATION table compares against
_kvm0921  2026-09-21 09:22   the baseline the GRADED final compares against
```

Each carries its own floor. No table crosses between them.

## Interleaving

Do not measure all your baselines and then all your optimized runs. Alternate:
baseline, optimized, baseline, optimized, accumulating with `pyperf --append`.

The reason is **drift**. If the two sides are measured as blocks, any slow change over
the session — thermal throttling, a background process starting, the hypervisor
rescheduling your guest — lands entirely on one side and masquerades as a speedup (or
hides one). Interleaved, both sides span the same wall-clock window and see the same
drift.

This is not hypothetical for us. `pyperf system tune` could not pin Turbo Boost,
because `/dev/cpu/0/msr` is not exposed to the guest, and the host is a 15 W mobile
part whose clock varies with thermal state. Interleaving is the mitigation for a
variable we could not eliminate.

## Median, not mean

```
Minimum:         98.1 ms
Median +- MAD:   106 ms +- 3 ms
Mean +- std dev: 107 ms +- 7 ms
Maximum:         ~188 ms
```

Look at the shape: a tight centre (MAD 3 ms) and a long tail (max 188 ms). That is
what measuring inside a VM looks like — most runs are clean, a few get interrupted by
the host.

The **median** describes the typical run. The **mean** is dragged upward by the
interrupted ones. Reporting only mean +- stdev would overstate your spread and make
your own result look weaker than it is.

Report both, lead with the median, and say why.

## pyperf vocabulary, since the output is dense

```
Loop iterations per value: 32     how many times the benchmark body runs per timing
Number of value per run:    5     timings taken per process
Number of runs:            60     processes spawned
Number of warmup per run:   1     discarded, so caches and branch predictors are warm
```

Why so many processes? Because a single process has one particular memory layout, one
hash seed, one set of addresses. Spawning 60 averages over that. Why loops? Because
one iteration of a 100 ms benchmark is fine, but if the body took 1 microsecond the
clock resolution would dominate — so pyperf calibrates a loop count automatically.

`not significant` comes from a statistical test on the two distributions, not a
threshold on the means.

## Proving provenance instead of asserting it

A grader can reasonably ask "how do I know the floor and the final came from the same
setup?" So we logged it:

```
09:22:13  boot_id=1803e111...  | sampling assertion: 3000 cycles samples in 3 s
09:22:13  boot_id=1803e111...  | NOISE FLOOR start (-p 60 -n 5)
09:25:05  boot_id=1803e111...  | GATE PASSED: not significant -> running run_final.sh
09:25:05  boot_id=1803e111...  | FINAL start (3 interleaved rounds)
09:31:48  boot_id=1803e111...  | FINAL end (exit 0)
```

Three claims this makes checkable:

1. The same `boot_id` on every line — floor and final provably share one boot, so no
   reboot or reconfiguration sits between them.
2. Sampling was verified working **before** anything was measured.
3. The gate passed **before** the final started, so it was not applied retroactively
   to justify a number we already liked.

It also records the md5 of the optimized file that actually ran, which matches the
one committed. The number provably belongs to the code in the repository.

## A number we measured and refused to use

One run of nbody came back **1.20x** — better than the 1.11x we report.

We did not use it. That morning the whole machine was ~45% slower (baseline median
147 ms against 101 ms the evening before, standard deviation 21%, one value at 500 ms)
and the run had no same-session noise floor. It is kept in `results/` as
`nbody_final_noisy_20260921_kvm.txt` with a note saying not to cite it.

Adopting the largest number you measured is the easiest thing in the world to do and
it is exactly the thing that makes a result worthless.

## Next

`02_profiling.md` — finding out where the time actually goes.
