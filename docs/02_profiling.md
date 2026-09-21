# 02 — Profiling: finding where the time actually goes

Written for a fellow ECE student who has not done this project.

## Timing and profiling answer different questions

- **Timing** (`pyperf`) says *how long* the program takes. That is your result.
- **Profiling** (`perf`, `py-spy`) says *where inside it* the time goes. That is what
  tells you what to optimize.

You need both, and they are separate evidence. A speedup with no profile is a lucky
guess; a profile with no timing is a hypothesis.

## Sampling, in one paragraph

A sampling profiler does not watch every instruction — that would be far too slow.
Instead it interrupts the program hundreds of times a second and records *where it
was*. Do that enough times and the distribution of those snapshots approximates the
distribution of time. `-F 999` means 999 interrupts per second.

Why 999 and not 1000? To avoid phase-locking. If your program has a loop that happens
to run at exactly 1000 Hz, sampling at 1000 Hz could catch it at the same point every
time and produce a systematically wrong picture. A prime-ish, slightly-off number
avoids that.

## Two profilers, because neither is enough

| tool | interpreter | tells you |
|---|---|---|
| **py-spy** | release `python3` | which **Python source line** is hot |
| **perf** | `python3-dbg` | which **C function** in CPython/libm is hot |

**Why you cannot just use perf.** Every Python-level operation executes inside
CPython's bytecode interpreter loop, `_PyEval_EvalFrameDefault`. So a pure perf profile
of a Python program says "46% of your time is in `_PyEval_EvalFrameDefault`" — which is
true and completely useless. It cannot tell you *which line of your code* that was.

**Why you cannot just use py-spy.** py-spy walks Python frames, so it names your lines
beautifully, but it cannot see inside `libm` or CPython's object machinery. It will not
tell you that `pow()` resolved to `__ieee754_pow_fma`, and that turned out to be the
single most important fact in this project.

py-spy is our primary attribution evidence. It also has a practical advantage: it does
not use perf, so none of the perf problems in `00_setup.md` touched it.

## A profile that was nearly wrong: interpreter startup

We had two py-spy profiles per benchmark and they disagreed badly:

| profile | samples | in import machinery | `advance:85` |
|---|---|---|---|
| short run | 9,299 | **69.2%** | 5.22% |
| long run | 28,094 | 0.3% | **18.11%** |

In the short run, two-thirds of the samples are `_compile_bytecode`, `_load_unlocked`
and `locale.py` — **CPython starting up**, not the benchmark at all.

Startup is a *fixed* cost. The shorter your profiled run, the more it dominates. Read
hotspots off the short profile and you would understate the real hot line by 3.5x.

> Sample count is not only precision. It changes **what you are measuring**.

Always check how much of a profile is startup before you trust a percentage.

## Self vs Children — the most common way to misread a profile

`perf report` gives two numbers per function:

- **Self** — time in *this* function's own instructions
- **Children** — time in this function *and everything it called*

A real example from our host profile:

```
__pow    Children 9.09%    Self 0.26%
```

`__pow` is a **router**. It barely does any work itself; it dispatches to an
implementation. The actual 9% was one level down in `__ieee754_pow_sse2`. If you read
Children as if it were Self you would "optimize" the wrong function.

Rule of thumb: high Children + low Self means *look at what it calls*.

## Reading a flame graph

- **Width** = share of samples. Wider means more time.
- **Vertical** = stack depth. A box sits on top of its caller.
- **Horizontal position means nothing.** It is alphabetical, not chronological.
  Nothing flows left to right.

Look for **wide plateaus**, not tall towers. A deep narrow stack is a call chain that
barely runs. A wide flat box is where the time is.

Our four kinds of graph:

```
*_pyspy_f_kvm.svg    Python lines.  START HERE -- it names your own code.
*_dbg_kvm.svg        C level, baseline
*_opt_dbg_kvm.svg    C level, optimized
*_diff_kvm.svg       differential: blue = frame shrank, red = frame grew
```

### The differential graph, and why `-n` matters

`difffolded.pl` compares two profiles. We pass `-n` to normalise them to a common
total first.

Without `-n`: the optimized build is genuinely faster, so profiling the same number of
loops produces *fewer samples*. Every frame then looks uniformly smaller and the
comparison is meaningless.

With `-n`: the diff answers the question you actually care about — did this frame's
**share** of runtime shrink?

`-n` does **not** rescue mismatched sample *rates*. If the two sides were recorded at
different `-F` values, re-record both. Normalising 27 samples up to 3000 does not
create information, it just scales noise.

## What we found — nbody

py-spy, 28,094 samples:

```
18.11%  advance:85     mag = dt * ((dx*dx + dy*dy + dz*dz) ** (-1.5))
 8.23%  advance:90     v1[2] -= dz * b2m
 8.09%  advance:91     v2[0] += dx * b1m
 8.04%  advance:88     v1[0] -= dx * b2m
 7.90%  advance:89     v1[1] -= dy * b2m
 7.89%  advance:92     v2[1] += dy * b1m
 7.46%  advance:93     v2[2] += dz * b1m
 5.46%  advance:80     the nested `for ... in pairs` loop HEADER
```

Two findings, and the second one decided the project:

1. Line 85, the `** (-1.5)`, is the hottest single line at 18.11%.
2. **The six velocity updates total 47.6%** — nearly three times as much.

The obvious target is line 85 and that is the textbook optimization. But the *bulk* of
the time is in six lines that each look trivial. That is what sent us to restructuring
the loop instead of rewriting the formula.

Also note line 80 — a `for` statement costing 5.46% by itself. That says the nested
unpacking `for (([x1,y1,z1], v1, m1), ([x2,y2,z2], v2, m2)) in pairs:` is not free.

perf + `python3-dbg`, self time:

```
46.83%  _PyEval_EvalFrameDefault   the interpreter loop itself
 5.35%  binary_op1                 generic binary-operator dispatch
 4.47%  PyFloat_FromDouble         allocating a new float per arithmetic result
 3.21%  float_dealloc              freeing them again
 2.39%  list_ass_item              v1[0] = ...
 2.13%  __ieee754_pow_fma          libm pow() -- line 85's real cost
```

`PyFloat_FromDouble` + `float_dealloc` = **7.7% purely creating and destroying float
objects.** In CPython every intermediate result of `dx*dx + dy*dy + dz*dz` is a
heap-allocated `PyFloat`. That is the tax on pure-Python floating point, and it is also
the best argument for the hardware accelerator, which does the same arithmetic in
registers with no allocation at all.

### The number that decided everything

`__ieee754_pow_fma` at **2.13% self**; the whole `**` chain at **2.79% of cycles**.

Replacing `**` with `math.sqrt` removes that chain *completely* — measured at 0.00% in
the optimized profile — and gains nothing, because only ~2% was ever there.

On our development host the identical chain was ~9%, because glibc 2.26 resolves
`pow()` to `__ieee754_pow_sse2` while 2.35 on this Icelake part resolves to
`__ieee754_pow_fma`, roughly 4x cheaper. **Two different symbol names in two
profiles** — measured, not inferred. Full story in `03_nbody.md`.

## What we found — raytrace

A completely different shape.

py-spy, 59,692 samples:

```
11.81%  __sub__:115           Point - Point, allocates a Vector
10.81%  dot:53                the dot product body
 6.97%  _lightIsVisible:285
 5.25%  dot:52                other.mustBeVector() -- body is `return self`
 5.23%  __init__:25           Vector.__init__
 4.41%  intersectionTime:145  recomputes radius*radius
```

perf, grouped by category:

```
call overhead:      call_function 3.60% + frame_dealloc 2.81%
                  + _PyObject_VectorcallTstate 2.44%
                  + _PyEval_MakeFrameVector 2.31%        = ~11%
attribute lookup:   _PyDict_GetItemHint 2.25% + lookdict_split 2.22%
                  + _PyObject_GetMethod 2.13%            = ~6.6%
```

So raytrace is **call- and allocation-bound**, not arithmetic-bound. Every `self.x`
hashes the string `"x"` and probes the instance `__dict__`; every method call builds
and tears down a frame. Both raytrace optimizations were picked straight off this
table.

`dot:52` at 5.25% is the find we are proudest of: a full Python call to a function
whose entire body is `return self`. It computes nothing. See `04_raytrace.md`.

## A prediction the profile refuted

Our initial plan assumed both benchmarks shared a `sqrt`-shaped bottleneck. The
profile says otherwise:

```
0.065%  math_sqrt
0.033%  __sqrt_finite@GLIBC_2.15
```

Under 0.1% combined. **raytrace is not sqrt-bound.** Its hottest line allocates an
object.

This mattered beyond bookkeeping: it changed the hardware argument. The accelerator is
justified as *one shared datapath with two batched entry points*, not as "both
benchmarks need a fast square root" — which was false for raytrace and would not have
survived being asked about.

Being able to say "we assumed X, the profile said not-X, here is what we changed" is
worth more than having guessed right.

## Next

`03_nbody.md` and `04_raytrace.md` — what we did with all this.
