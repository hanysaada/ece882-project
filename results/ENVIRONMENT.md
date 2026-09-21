# ENVIRONMENT.md

Every measurement in this repository comes from **one** machine in **one**
configuration. This file records it exactly, so any number in a report can be
traced to the environment that produced it.

Two rules that this file exists to make checkable:

1. Every timing number comes from the **measurement VM** below, using **release
   `python3`** — never `python3-dbg`.
2. Every number in a single comparison table comes from **one environment and one
   run configuration**. A baseline from one machine against an optimized run from
   another measures the machines, not the optimization.

---

## The measurement VM (all graded numbers)

| Item | Value | How obtained |
|---|---|---|
| OS | Ubuntu 22.04 "jammy" (course cloud image) | — |
| Kernel | `5.15.0-1106-kvm` | `uname -r` |
| CPU as the guest sees it | 11th Gen Intel Core i7-1165G7 @ 2.80GHz (Icelake) | `lscpu` |
| `arch_perfmon` CPU flag | **present** — the guest sees the hardware PMU | `lscpu \| grep Flags` |
| vCPUs | 2 | QEMU `-smp 2` |
| RAM | 4096 MB | QEMU `-m 4096` |
| glibc | **2.35** (Ubuntu GLIBC 2.35-0ubuntu3.14) | `ldd --version` |
| Python (release) | 3.10.12 | `python3 -V` |
| Python (debug, profiling only) | 3.10.12 | `python3-dbg -V` |
| perf | 5.15.209 | `perf --version` |
| **perf sampling event** | **`cycles`** — real hardware PMU counter | `results/perf/PERF_EVENT_USED_kvm.txt` |
| perf call-graph unwinding | `fp` (frame pointer) | see "Unwinder choice" below |
| py-spy sampling rate | 999 Hz | — |
| `pyperf system tune` | **succeeded** ("System ready for benchmarking") | run log |
| Python CFLAGS | [NOT MEASURED — not captured from the guest] | — |
| pyperformance / pyperf / py-spy versions in the guest | [NOT MEASURED — host versions are 1.14.0 / 2.10.0 / 0.4.2; the guest's were not recorded separately] | — |

`pyperf system tune` reported one failure: it could not pin Turbo Boost, because
`/dev/cpu/0/msr` is not exposed to the guest. This matters and is stated rather
than hidden — the host is a 15 W mobile part, so clock behaviour varies with
thermal state. It is one reason every comparison here is **interleaved** (baseline,
optimized, baseline, optimized) rather than run as two separate blocks: drift lands
on both sides equally instead of masquerading as a speedup.

### QEMU command line, exactly as used

```
qemu-system-x86_64 -name ece882-019-local -enable-kvm -cpu host \
  -m 4096 -smp 2 \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2299-:22 \
  -drive file=local.qcow2,format=qcow2,if=virtio \
  -display none -serial tcp:127.0.0.1:4599,server,nowait -monitor none
```

Host: WSL2 (`5.15.167.4-microsoft-standard-WSL2`) on Windows 11, 8 vCPU and 7.8 GB
visible to WSL. The guest gets 2 vCPU and 4 GB of that.

`-cpu host` is what exposes the hardware PMU. Without it `perf` falls back to the
software `cpu-clock` event and no cycle-level claim is possible.

### On `-smp 2`

The course connection guide's command omits `-smp`, and QEMU's default is one vCPU.
Nothing in the assignment specifies a CPU count, so there is no requirement here
either way; this section records what we used and what we know about it.

We ran a 1-vCPU check. **It is confounded and we make no claim from it.** The check
was taken on a morning when the machine was independently demonstrably degraded, so
it cannot be attributed to the vCPU count:

| nbody baseline | median | session |
|---|---|---|
| 1 vCPU | 140 +- 4 ms | 2026-09-21 08:58 |
| 2 vCPU | 147 +- 7 ms | 2026-09-21 09:16 |
| 2 vCPU | **99.8 +- 2.0 ms** | 2026-09-20 18:09 |

Compared **within the same session**, 1 vCPU and 2 vCPU are indistinguishable (140
vs 147 ms, and the 1-vCPU spread is the tighter of the two). The 40% gap is between
*sessions*, not between configurations: the same 2-vCPU VM measured 99.8 ms one
evening and 147 ms the next morning. The 1-vCPU noise floors did come back
"significant" that morning, but so did everything else measured then — a 2-vCPU run
in the same window had a standard deviation of 31 ms and a maximum of 500 ms.

This is worth recording rather than deleting, because it is the same mistake this
project has guarded against throughout: **comparing across sessions measures the
machine, not the change.** We caught it in our own analysis, which is the reason
every graded comparison in this repository is interleaved and taken in a single
session alongside its own noise floor.

Raw data: `results/compare/*_noise_floor_1cpu.txt` and `*_base_stats_1cpu.txt`.
No 1-vCPU number appears in any results table.

What can be said without measurement: the benchmarks are single-threaded and pyperf
runs one worker process at a time, so a second vCPU cannot make the benchmark itself
faster. Whether it makes the measurement quieter is exactly the question the check
above failed to answer.

---

## The rejected environment, recorded so the choice is defensible

The first attempt ran on the course server `tangerine` under `-accel tcg`, i.e.
pure software emulation with no KVM.

| | tangerine (TCG) | this VM (KVM) |
|---|---|---|
| Acceleration | `-accel tcg` | `-enable-kvm -cpu host` |
| perf event available | `cpu-clock` (software) | `cycles` (hardware PMU) |
| nbody noise floor | 4.3% | not significant |
| raytrace noise floor | **31%** | not significant |
| Verdict | unusable | used for all results |

A 31% floor cannot support the assignment's 7% claim: the measurement is less
precise than the effect being measured.

**Why KVM was unavailable on tangerine.** The course guide's own example logs in as
a *personal* Technion account (`ohad.eitan@tangerine`), and tangerine's `kvm` group
contains personal accounts. The shared course account we were issued is not in that
group, so `/dev/kvm` was inaccessible and QEMU silently fell back to TCG. Running
locally with KVM gives the environment the guide intended, not a departure from it.

No `_tcg`-tagged number appears in any report or table in this repository.

---

## Unwinder choice: `fp`, not `dwarf`

Measured in this guest at ~4K samples, weighted **by sample count** rather than by
number of distinct stacks:

| | distinct stacks | share of samples in stacks containing `[unknown]` |
|---|---|---|
| `fp` | 171 | **85.7%** |
| `dwarf,4096` | 334 | 99.5% |

`dwarf` recovers more distinct call chains but attributes almost nothing cleanly,
which is worse for our purpose. `fp` also resolves `__ieee754_pow_fma` directly as a
leaf, and that symbol is the evidence the nbody analysis rests on. Plain `-g`, which
is what the assignment specifies, is frame-pointer unwinding.

Caveat worth stating: Ubuntu 22.04 was not built with frame pointers (that changed
in 24.04), so some C-level chains are incomplete under `fp`. This is why py-spy is
used alongside perf — it reports Python source lines directly and does not depend
on C unwinding at all.

---

## perf kernel settings, and the trap in setting them

Final state in the guest:

```
kernel.perf_event_paranoid          -1
kernel.kptr_restrict                 0
kernel.perf_event_max_sample_rate 5000
kernel.perf_cpu_time_max_percent     0
```

`perf_event_paranoid` gates who may sample what; at the common default of 2,
kernel-level sampling is blocked and call graphs come back truncated.
`kptr_restrict=0` lets perf resolve kernel addresses to symbol names.

`perf_cpu_time_max_percent` is the one that cost real time. The kernel measures what
fraction of CPU the sampling interrupt consumes and, if it exceeds this percentage,
**ratchets `perf_event_max_sample_rate` down** — repeatedly, without recovering.
Under a VM the interrupt looks expensive, so the rate collapses toward 1 Hz, `-F 999`
is silently ignored, and a multi-second run yields single-digit sample counts. Two
complete profile sets were discarded to this before it was understood. Reading the
ceiling at setup time does not protect you: it read a healthy 100000 and was
ratcheted down later, during the profiling runs themselves.

**The order of these writes is load-bearing.** `perf_proc_update_handler()` in
`kernel/events/core.c` rejects any write to the sample rate while the percent is 0
or 100:

```c
if (write && (perf_cpu == 100 || perf_cpu == 0))
        return -EINVAL;
```

So the percent must be non-zero to raise the rate, and only then may it be set to 0:

```bash
sysctl -w kernel.perf_cpu_time_max_percent=25      # rate becomes writable
sysctl -w kernel.perf_event_max_sample_rate=5000
sysctl -w kernel.perf_cpu_time_max_percent=0       # throttle off; does not clobber the rate
```

Setting the percent to 0 first leaves the rate read-only at whatever value the
kernel had already ratcheted it to — the exact state one is trying to escape,
silently unfixed. `scripts/setup_env.sh` does this in the correct order and then
**asserts** it by recording a real one-second profile and failing if it collected
fewer than 200 samples where ~1000 was expected. Checking the setting is not
evidence that sampling works; only a sample count is.

---

## Development host (NOT gradeable, listed for contrast)

Used only to develop the scripts and to form expectations. No number from this
machine appears in any report.

| Item | Value |
|---|---|
| CPU | Intel Xeon Platinum 8275CL @ 3.00GHz, 16 cores |
| Python | 3.12.13 |
| glibc | **2.26** |
| perf event available | `cpu-clock` (no PMU exposed) |

The two glibc versions are not a footnote — they are the explanation for the main
negative result in `report_nbody.txt`. glibc 2.26 dispatches `pow()` to
`__ieee754_pow_sse2`; glibc 2.35 on this Icelake part dispatches to
`__ieee754_pow_fma`, roughly 4x cheaper. An optimization that removes a `pow()` call
is therefore worth ~9% on the host and ~2% in the VM. Same code, same correctness,
different payoff — and the symbol names are the proof.

Python 3.12 versus 3.10 matters in the same way, in the opposite direction: 3.11
introduced the specializing adaptive interpreter, which 3.10 lacks. Optimizations
that remove attribute or global lookups therefore pay **more** in the VM. Predicted
in advance and confirmed: `__slots__` measured 1.05x on 3.12 and 1.13x on 3.10.

---

## Reproducing this record

```bash
uname -r
lscpu | grep -E "Model name|^Flags"
ldd --version | head -1
python3 -V ; python3-dbg -V
python3 -c "import sysconfig; print(sysconfig.get_config_var('CFLAGS'))"
perf --version
python3 -c "import pyperf, pyperformance; print(pyperf.__version__, pyperformance.__version__)"
py-spy --version
cat /proc/sys/kernel/perf_event_paranoid /proc/sys/kernel/perf_cpu_time_max_percent
bash scripts/setup_env.sh          # sets the knobs, asserts sampling, reports the event
```
