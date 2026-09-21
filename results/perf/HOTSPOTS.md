# HOTSPOTS — where the time actually goes

All data from the KVM guest, Python 3.10.12, `cycles` (hardware PMU). Two
independent tools, because neither is sufficient alone:

| tool | interpreter | answers |
|---|---|---|
| **py-spy** | release `python3` | which **Python source line** is hot |
| **perf** | `python3-dbg` | which **C function** in CPython / libm is hot |

py-spy is the primary attribution evidence. It does not use perf, so none of the
perf problems recorded in `ENVIRONMENT.md` touch it, and it reports your own source
lines rather than `_PyEval_EvalFrameDefault`. The perf view explains *why* those
lines cost what they do.

---

## A profile that was nearly wrong: interpreter startup

Two py-spy profiles exist per benchmark and they disagree sharply:

| profile | samples | in import machinery | `advance:85` |
|---|---|---|---|
| short run | 9,299 | **69.2%** | 5.22% |
| long run (`_f_`) | 28,094 | 0.3% | **18.11%** |

In the short run, two-thirds of the samples are `_compile_bytecode`,
`_load_unlocked` and `locale.py` — CPython starting up, not the benchmark. Startup
is a fixed cost, so the shorter the profiled run the more it dominates. Reading
hotspots off that profile would have understated the real hot line by 3.5x.

**All attribution below uses the long `_f_` profiles**, where import machinery is
0.3% (nbody) and 0.1% (raytrace). The same files back the Amdahl fractions in
`results/hw/fractions_kvm.txt`, so the two analyses are consistent by construction.

The lesson generalises: a profile's sample count is not just precision, it changes
*what* you are measuring. Always check how much of a profile is startup.

---

## nbody

### Python lines (py-spy, 28,094 samples)

| share | line |
|---|---|
| **18.11%** | `advance:85` — `mag = dt * ((dx*dx + dy*dy + dz*dz) ** (-1.5))` |
| 8.23% | `advance:90` — `v1[2] -= dz * b2m` |
| 8.09% | `advance:91` — `v2[0] += dx * b1m` |
| 8.04% | `advance:88` — `v1[0] -= dx * b2m` |
| 7.90% | `advance:89` — `v1[1] -= dy * b2m` |
| 7.89% | `advance:92` — `v2[1] += dy * b1m` |
| 7.46% | `advance:93` — `v2[2] += dz * b1m` |
| 5.46% | `advance:80` — the nested `for ... in pairs` loop header |

Two findings, and the second is the one that mattered:

1. **Line 85 is the single hottest line at 18.11%** — the `** (-1.5)`.
2. **The six velocity updates (88–93) total 47.6%** — nearly three times line 85.

The obvious optimization target is line 85, and that is the textbook one. But the
profile says the *bulk* of the time is in six lines that each look trivial. That is
what directed the optimization effort to structure rather than to arithmetic, and it
is why the variant that ships (`v4_struct`) rewrites the loop instead of the formula.

Note also line 80, the loop *header*, at 5.46%. A `for` statement costing 5% is a
signal that the nested unpacking pattern
`for (([x1,y1,z1], v1, m1), ([x2,y2,z2], v2, m2)) in pairs:` is not free.

### C functions (perf + `python3-dbg`, self time)

Baseline:

| self | symbol | what it is |
|---|---|---|
| 46.83% | `_PyEval_EvalFrameDefault` | the bytecode interpreter loop itself |
| 5.35% | `binary_op1` | generic binary-operator dispatch |
| 4.47% | `PyFloat_FromDouble` | **allocating a new float object per arithmetic result** |
| 3.21% | `float_dealloc` | freeing them again |
| 2.39% | `list_ass_item` | `v1[0] = ...` |
| 2.33% | `_Py_CheckSlotResult` | |
| **2.13%** | **`__ieee754_pow_fma`** | **libm `pow()` — this is line 85's real cost** |
| 2.11% | `PyObject_SetItem` | the subscript-store path |

`PyFloat_FromDouble` + `float_dealloc` = 7.7% spent purely creating and destroying
float objects. In CPython every intermediate result of `dx*dx + dy*dy + dz*dz` is a
heap-allocated `PyFloat`. That is the cost of pure-Python floating point, and it is
also the strongest argument for the hardware accelerator: a hardware datapath does
this arithmetic in registers with no allocation at all.

### The decisive number: `pow()` is only ~2%

`__ieee754_pow_fma` at **2.13% self**, and the whole `**` chain (libm + CPython's
`float_pow` wrapper + PLT) at **2.79%** of cycles.

That single number explains the main negative result of this project. Replacing
`** (-1.5)` with `math.sqrt` removes that chain **completely** — measured at 0.00% in
the optimized profile — and still gains nothing, because there is only ~2% there to
win.

On the development host the identical chain was ~9%, because glibc 2.26 dispatches
`pow()` to `__ieee754_pow_sse2` while glibc 2.35 on this Icelake part dispatches to
`__ieee754_pow_fma`, roughly 4x cheaper. The two different symbol names in the two
profiles are the evidence; this is not inferred.

### A confirmation worth noticing

In the **optimized** profile `__ieee754_pow_fma` *rises* to 2.52% self.

That is the expected result, not an anomaly. `v4_struct` deliberately leaves
`** (-1.5)` untouched, so `pow()`'s absolute cost is unchanged while total runtime
falls ~10%. A constant cost over a smaller total is a larger *share*. If pow's share
had fallen, something other than what we intended would have changed.

---

## raytrace

### Python lines (py-spy, 59,692 samples)

| share | line |
|---|---|
| **11.81%** | `__sub__:115` — `Point - Point`, allocates a `Vector` |
| **10.81%** | `dot:53` — the dot product body |
| 6.97% | `_lightIsVisible:285` | |
| 5.25% | `dot:52` — **`other.mustBeVector()`, whose entire body is `return self`** |
| 5.23% | `__init__:25` — `Vector.__init__` |
| 5.12% | `scale:49` | |
| 4.41% | `intersectionTime:145` — the discriminant, recomputes `radius*radius` |
| 3.69% | `magnitude:36` | |
| 3.51% | `<listcomp>:271` | |
| 3.05% | `normalized:62` | |

`dot:52` at 5.25% is the finding this project is proudest of: a full Python call —
build a frame, execute, tear the frame down, discard the result — to compute
**nothing**. It appears in no guide we were given; it was found by reading the source
after the profile pointed at `dot`.

### C functions (perf + `python3-dbg`, self time)

| self | symbol | category |
|---|---|---|
| 26.20% | `_PyEval_EvalFrameDefault` | interpreter |
| 3.60% | `call_function` | **call overhead** |
| 2.81% | `frame_dealloc` | **call overhead** |
| 2.44% | `_PyObject_VectorcallTstate` | **call overhead** |
| 2.31% | `_PyEval_MakeFrameVector` | **call overhead** |
| 2.25% | `_PyDict_GetItemHint` | **attribute lookup** |
| 2.22% | `lookdict_split` | **attribute lookup** |
| 2.13% | `_PyObject_GetMethod` | **attribute lookup** |
| 2.08% | `binary_op1` | arithmetic dispatch |

This is a different shape from nbody entirely. raytrace's overhead is **function
calls and attribute lookups**, not arithmetic:

- ~11% in frame construction and teardown → justifies deleting the do-nothing guard
  calls, and inlining the dot products inside `intersectionTime`.
- ~6.6% in dictionary probing (`lookdict_split`, `_PyDict_GetItemHint`) → every
  `self.x` hashes the string `"x"` and probes the instance `__dict__`. This is
  exactly what `__slots__` replaces with a fixed-offset load.

Both optimizations were chosen from this table, and both worked: 1.10x and 1.13x
respectively (see `results/compare/raytrace_ablation_kvm.txt`).

### raytrace is NOT sqrt-bound — a corrected assumption

The project's initial plan assumed both benchmarks shared a `sqrt`-shaped
bottleneck. The profile refutes it:

```
0.065%  math_sqrt
0.033%  __sqrt_finite@GLIBC_2.15
```

Under 0.1% combined. raytrace is **allocation- and call-bound**, not math-bound.
`Point.__sub__` at 11.81% is the hottest line and its job is to allocate a `Vector`.

This is recorded because it changed the hardware design argument. The accelerator is
justified as **one shared `dot3` + `rsqrt` datapath with two batched entry points**,
not as "both benchmarks need a fast square root" — which would have been false for
raytrace and would not have survived a question about it.

---

## How to read the flame graphs

In `results/flamegraphs/`:

| file | what |
|---|---|
| `*_pyspy_f_kvm.svg` | Python lines. **Start here** — it names your own code. |
| `*_dbg_kvm.svg` | C level, baseline |
| `*_opt_dbg_kvm.svg` | C level, optimized |
| `*_diff_kvm.svg` | differential: blue = frame shrank, red = frame grew |

Width is share of samples; the y axis is stack depth, **not** time. Nothing moves
left to right in chronological order.

**Self vs Children matters.** In `perf report`, a function's *Children* figure
includes everything it called. On the host profile `__pow` showed 9.09% Children but
only 0.26% Self — it is a router, and the work was one level down in
`__ieee754_pow_*`. Reading Children as if it were Self is the most common way to
misattribute a flame graph.

**Every Python-level frame sits inside `_PyEval_EvalFrameDefault`**, which is why it
dominates the C profiles at 46.83% and 26.20%. That is the interpreter loop
executing your bytecode; it is not a function you can optimize. It is also precisely
why py-spy is needed alongside perf.

The differential graphs are normalised with `difffolded.pl -n`. Without `-n` every
frame in the faster optimized profile would look uniformly smaller, since the same
loop count yields fewer samples. With `-n` the diff answers the question actually
being asked: did this frame's *share* of runtime shrink?
