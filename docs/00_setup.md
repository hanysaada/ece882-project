# 00 — Setting up an environment you can actually trust

Written for a fellow ECE student who has not done this project.

## The thing nobody tells you first

You would think a benchmarking project starts by benchmarking. It does not. It
starts by proving your machine can measure anything at all, and by getting the
profiler to actually profile.

We lost roughly two days to tools that reported success while doing nothing useful.
Everything in this document is a consequence of that.

## Why a VM at all

The course gives you an Ubuntu 22.04 cloud image and tells you to run it under QEMU.
The reason is fairness: everyone measures on the same software stack, so results are
comparable and nobody wins by having a nicer laptop.

There are two ways to run QEMU and the difference is enormous:

- `-accel tcg` — **software emulation.** QEMU interprets every guest instruction. No
  hardware performance counters are visible. Roughly 40-70x slower than native.
- `-enable-kvm -cpu host` — **hardware virtualisation.** The guest runs on the real
  CPU. The hardware PMU is visible, so `perf` can count real cycles.

We started on the course server (`tangerine`) and got TCG. The absolute times were
terrible, but that was not the problem — the problem was the *noise*. raytrace's
noise floor was **31%** (see `01_measurement.md` for what that means). An
environment that noisy cannot support a 7% claim.

**Why KVM was unavailable, and this is worth knowing.** It was not a server
limitation. The course guide's own example logs in as a *personal* Technion account,
and tangerine's `kvm` group contains personal accounts. The shared course account we
were issued is not in that group, so `/dev/kvm` was inaccessible and QEMU silently
fell back to emulation. Running KVM locally gave us what the guide intended.

Lesson: when a tool is mysteriously slow, check whether it silently fell back to a
slower path.

## Two Python builds, and they are not interchangeable

```
python3       release build, -O2 -DNDEBUG          USE FOR ALL TIMINGS
python3-dbg   built with --with-pydebug            USE FOR PROFILING ONLY
```

`python3-dbg` has full debug symbols, so `perf` can resolve CPython's internals by
name — `_PyEval_EvalFrameDefault`, `PyFloat_FromDouble`, `lookdict_split`. Without
it your profile is a wall of hex addresses.

But it is substantially slower **and differently shaped**: extra reference-count
bookkeeping changes where the time goes. So a timing from `python3-dbg` in a
comparison table would be meaningless.

We treat mixing them as a bug, not a style issue. `run_final.sh` asserts it:

```python
dbg = ('pydebug' in CFLAGS) or hasattr(sys, 'gettotalrefcount')
if dbg:
    raise SystemExit("REFUSING TO CONTINUE: this is a debug build.")
```

`sys.gettotalrefcount` only exists in debug builds, which makes it a reliable probe.

## The perf kernel knobs

`perf` needs permission to sample, and by default it does not have enough.

```bash
kernel.perf_event_paranoid = -1    # who may sample what. Default 2 blocks
                                   # kernel-level sampling, so call graphs through
                                   # the kernel come back truncated.
kernel.kptr_restrict = 0           # lets perf turn kernel addresses into symbol
                                   # names instead of hex.
```

## The bug that cost two days, twice

This is the important part of this document.

`perf record -F 999` asks for 999 samples per second. We got **8**.

Not an error. Not a warning. `perf record` exited 0, wrote a `.data` file, and the
whole pipeline downstream produced a perfectly valid-looking flame graph — built on
eight samples. We generated two complete profile sets this way and threw both away.

**The mechanism.** The kernel watches what fraction of CPU time perf's sampling
interrupt consumes. If it exceeds `kernel.perf_cpu_time_max_percent` (default 25),
it *lowers* `kernel.perf_event_max_sample_rate`. It does this repeatedly and never
raises it back. Inside a VM the interrupt looks expensive, so the rate collapses
toward 1 Hz.

**What exposed it was arithmetic, not a message:**

```
27,000,000,000 ns / 27 samples = exactly 1,000,000,000 ns per sample
```

Exactly 1 Hz when you asked for 999 Hz is not noise. It is a clamp.

**Checking the setting does not protect you.** We read the ceiling at setup time and
it was a healthy 100000. It was ratcheted down *later*, during the profiling runs
themselves.

### The fix, and the order matters

```bash
sysctl -w kernel.perf_cpu_time_max_percent=25      # 1. must be NON-ZERO first
sysctl -w kernel.perf_event_max_sample_rate=5000   # 2. now writable
sysctl -w kernel.perf_cpu_time_max_percent=0       # 3. throttle off
```

Step 1 looks pointless. It is not. From `kernel/events/core.c`:

```c
/* perf_proc_update_handler() */
if (write && (perf_cpu == 100 || perf_cpu == 0))
        return -EINVAL;
```

The sample rate is **read-only while the percent is 0**. So you must raise the
percent, then set the rate, then drop the percent. Writing 0 last only clears
`perf_sample_allowed_ns` and returns, so it does not undo step 2.

Our first version of this fix had steps 1 and 3 swapped. It failed *silently* —
`sysctl` returned an error that a `||` fallback swallowed, the percent ended up 0 as
intended, and the rate stayed pinned wherever the kernel had already dragged it. The
fix appeared to work and changed nothing.

## The rule this all produces

> **An exit code proves a program ran. It does not prove it did its job.**

Three separate instances in this one project:

1. `perf stat -e cycles true` exits **0** while printing `<not supported>`. So the
   event-availability probe must parse perf's *output*, never `$?`.
2. A shell pipe whose first stage emits nothing still exits **0** — leaving a 0-byte
   `.folded` file and no flame graph.
3. `perf record` "succeeds" with 8 samples.

So every check in this project asserts on a **measured quantity** — a sample count,
a file size, an energy value — and never on a return code.

`setup_env.sh` now ends by recording a real one-second profile and dying if it
collected fewer than 200 samples where ~1000 was expected:

```
Asserting perf can actually sample (1 s at -F 999)
    samples collected: 2840
OK  perf sampling verified at 2840 samples
```

That single check would have saved both lost days.

## What to record before you measure anything

`results/ENVIRONMENT.md` captures kernel, CPU as the guest sees it, the exact QEMU
command line, both Python versions and their CFLAGS, tool versions, and **which perf
event you actually got**.

Two entries there turned out to decide results rather than document them:

- **glibc version.** 2.35 dispatches `pow()` to `__ieee754_pow_fma` on an Icelake
  CPU; 2.26 uses `__ieee754_pow_sse2`, about 4x more expensive. This single fact
  determines whether one of our optimizations works. See `03_nbody.md`.
- **Python version.** 3.11 introduced the specializing adaptive interpreter, which
  caches attribute lookups inline. 3.10 has none. So optimizations that remove
  attribute lookups pay *more* on 3.10. See `04_raytrace.md`.

If you only write down "Ubuntu 22.04, Python 3.10", you will not be able to explain
your own results later.

## Next

`01_measurement.md` — how to establish that your measurements mean anything.
