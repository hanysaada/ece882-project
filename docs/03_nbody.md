# 03 — Optimizing nbody: when the textbook answer is wrong

Written for a fellow ECE student who has not done this project.

This is the more interesting of the two benchmarks, because the obvious optimization
**failed** and we can prove exactly why.

## What nbody computes

Five bodies — the Sun, Jupiter, Saturn, Uranus, Neptune — pulling on each other under
gravity, simulated for 20,000 timesteps.

Each body is a plain Python list: `[[x,y,z], [vx,vy,vz], mass]`. No numpy, no C
extensions. Every single arithmetic operation goes through CPython's object protocol,
which is exactly why interpreter-level optimization can move the needle.

The hot function, `advance()`:

```python
def advance(dt, n, bodies=SYSTEM, pairs=PAIRS):
    for i in range(n):                       # 20,000 timesteps
        for ((r1, v1, m1), (r2, v2, m2)) in pairs:   # 10 pairs
            # compute the force between this pair, nudge both velocities
        for (r, v, m) in bodies:             # 5 bodies
            # move each body by its velocity
```

**The number that governs everything: 20,000 x 10 = 200,000 inner iterations.**
Anything you remove from that loop body, you remove 200,000 times. Anything you can
move *outside* the loops you pay for once.

## The correctness test

`report_energy()` runs before and after. Gravity **conserves total energy**, so if
your change alters the reported energy you have changed the physics — that is a bug,
not an optimization.

This is a much better test than comparing printed output, because it is a *physical
law*. It catches errors of reasoning, not just typos. Tolerance 1e-12 relative.

## Variant 1 — the textbook optimization

```python
# before
mag = dt * ((dx*dx + dy*dy + dz*dz) ** (-1.5))

# after
d2  = dx*dx + dy*dy + dz*dz
mag = dt / (d2 * sqrt(d2))
```

**The reasoning, which is sound.** `x ** y` compiles to the bytecode `BINARY_OP 8 (**)`.
That routes through CPython's generic numeric protocol to `libm`'s `pow()` — a routine
built to handle *arbitrary real* exponents, evaluated roughly as `exp(y * log x)`.
Meanwhile `math.sqrt` maps to a single hardware `sqrtsd` instruction.

And `d2 ** -1.5 == 1/(d2 * sqrt(d2))` **exactly** — this is an algebraic identity, not
an approximation.

On our development host this measured **1.13x faster.** Every guide recommends it.

**Result on the graded machine: NOT SIGNIFICANT.** Nothing at all.

## Why it failed — three independent lines of evidence

### 1. The ablation

```
v1_sqrt          NOT SIGNIFICANT
v2_localsqrt     1.02x
v3_slicewrite    NOT SIGNIFICANT
```

The entire v1+v2+v3 chain totals about 2%.

### 2. The profile

The whole `**` chain is **2.79% of cycles** in the baseline, and **0.00%** in the
optimized build.

Read that carefully: **the optimization works perfectly.** It removes the `pow()` call
completely. There is simply only ~2% there to remove. On the host the identical chain
was ~9%.

### 3. The symbol name — the decisive one

```
development host   glibc 2.26   __ieee754_pow_sse2   ~9% of samples
graded VM          glibc 2.35   __ieee754_pow_fma    2.13% of samples
```

glibc 2.35 dispatches `pow()` to an FMA-accelerated implementation on this Icelake
CPU. glibc 2.26 used the older SSE2 path. Roughly 4x difference in cost.

This is **not a hypothesis**. They are two different function names appearing in two
different profiles. That is as close to proof as profiling gets.

## The mechanism, stated precisely

It is tempting to summarise this as "pow is fast now", but the real mechanism is
sharper and more useful:

> **`**` is an INLINE opcode. `sqrt(x)` is a function CALL.**

`BINARY_OP` is one instruction the interpreter executes in its own loop. `sqrt(d2)` has
to push arguments, dispatch a call, and return. When `pow()` is expensive, that trade
pays. When `pow()` is cheap, **you are paying call overhead to avoid something that was
already cheap.**

And v1 made it worse than necessary: it introduced `sqrt` as a **global**, so every one
of those 200,000 calls also pays `LOAD_GLOBAL` — hash the string `"sqrt"`, probe the
module `__dict__`, fall through to builtins on a miss.

## Variant 2 — and why its number is misleading

```python
def advance(dt, n, bodies=SYSTEM, pairs=PAIRS, _sqrt=sqrt):
    ...
    mag = dt / (d2 * _sqrt(d2))
```

A default argument is evaluated **once, at function definition time**, and lands in the
frame's fast-locals array. So the call site becomes `LOAD_FAST` — a single array index
— instead of `LOAD_GLOBAL`.

Measured 1.02x. Real, but small.

**The honest caveat:** v1 and v2 are **confounded**. v2 is mostly *undoing a cost that
v1 introduced*, not adding value of its own. Reporting "v2 gave us 1.02x" as an
independent win would overstate it. Say so before someone asks.

## Variant 3 — a negative result worth keeping

```python
# six index writes become two slice writes
a1, b1, c1 = v1
v1[:] = (a1 - dx*b2m, b1 - dy*b2m, c1 - dz*b2m)
```

This *looks* like less work: one slice store replacing three `STORE_SUBSCR`.

It is not. `(a, b, c)` builds a **temporary tuple** — a heap allocation — and the slice
store goes through the general `PySequence_SetSlice` machinery. Measured **not
significant** here and **1.21x SLOWER** on the host.

> **Fewer bytecode instructions is not less work.**

We kept this variant deliberately. A negative result with a stated mechanism shows you
ran experiments rather than applied a recipe.

## Variant 4 — what actually worked (SHIPPED, 1.11x)

The profile said the six velocity updates were 47.6% and the arithmetic was 18%. So
stop optimizing the arithmetic.

```python
def advance(dt, n, bodies=SYSTEM, pairs=PAIRS):
    # (A) dt is constant -- fold it into the masses ONCE, outside all loops.
    #     Also flatten the tuples so the loop target is one unpack, not five.
    dtp = [(r1, v1, m1 * dt, r2, v2, m2 * dt)
           for ((r1, v1, m1), (r2, v2, m2)) in pairs]

    for i in range(n):
        for (r1, v1, m1d, r2, v2, m2d) in dtp:
            x1, y1, z1 = r1
            x2, y2, z2 = r2
            dx = x1 - x2; dy = y1 - y2; dz = z1 - z2

            # (B) ** (-1.5) DELIBERATELY UNCHANGED
            mag = (dx*dx + dy*dy + dz*dz) ** (-1.5)
            b1m = m1d * mag
            b2m = m2d * mag

            # (C) read each velocity ONCE instead of six subscript reads
            a, b, c = v1
            d, e, f = v2
            v1[0] = a - dx*b2m
            v1[1] = b - dy*b2m
            v1[2] = c - dz*b2m
            v2[0] = d + dx*b1m
            v2[1] = e + dy*b1m
            v2[2] = f + dz*b1m
```

### (A) Hoisting `dt`

`mag = dt * (...)` multiplies by a constant 200,000 times. Folding `dt` into the masses
in `dtp` does it 10 times, once, before the loops start.

Flattening the tuples also fixes the 5.46% loop header: the baseline's nested pattern
`(([x1,y1,z1], v1, m1), ([x2,y2,z2], v2, m2))` requires **five** unpack operations
(the pair, two triples, two position lists). The flat version needs three.

### (B) The key design decision — leaving `**` alone

This is the part to understand.

Because `** (-1.5)` is **identical in the baseline and in v4**, `pow()`'s cost appears
on *both sides* of the comparison and **cancels out**. Whatever speedup we measure is
therefore purely structural.

That makes the result **portable**. v1's benefit depended on which glibc you ran on.
v4's does not depend on `libm` at all — which is exactly why it transferred to the
graded machine when v1 did not.

### (C) Reading velocities once

This is the biggest single win and the subtlest point:

```python
v1[0] -= dx * b2m      # READ v1[0], compute, WRITE v1[0]
v1[0] = a - dx * b2m   # WRITE only  (a was read once, earlier)
```

`-=` on a list element is a read *and* a write. Six such lines = six reads + six
writes. One `a, b, c = v1` (a single `UNPACK_SEQUENCE`) replaces all six reads. Each
removed read is a type dispatch, a bounds check and an index normalisation.

### Measured effect on the bytecode

Verified with `dis`, per iteration of the hot loop:

```
baseline   124 instructions,  6 BINARY_SUBSCR,  6 STORE_SUBSCR
v4         110 instructions,  0 BINARY_SUBSCR,  6 STORE_SUBSCR
```

**Note the trap:** the *whole function* has MORE static instructions in v4 (227 vs 186)
because of the one-time setup comprehension. Static instruction count is the wrong
metric. The right one is instructions x execution frequency: the setup runs once, the
loop body 200,000 times.

## Variant 5 — does sqrt help once the structure is fixed?

Fair question. v1 lost for two reasons and v4 weakens both: in v5 `sqrt` is a fast local
(`LOAD_FAST`, not `LOAD_GLOBAL`), and `dt` is already hoisted so the rewrite is a plain
reciprocal. If sqrt were ever going to win here, it would win now.

Measured as a same-session interleaved three-way comparison:

```
base        105 ms     median 103  +- 3   ms
v4_struct   95.9 ms    median 94.6 +- 2.7 ms    1.10x
v5          97.1 ms    median 96.3 +- 2.3 ms    1.08x

v5 vs v4:   1.01x SLOWER
```

So **no**. The sqrt rewrite does not merely fail to help — it is marginally *harmful*
even after the structural work is done. That closes the question completely.

## The final result

```
107 ms -> 96.7 ms = 1.11x  (9.9%)
median 106 +- 3 ms -> 95.4 +- 2.7 ms
correctness: energy 1.313e-15 relative, gate 1e-12
```

Reproduced in **three independent sessions** on byte-identical code (md5
`b651647e...`): 1.12x, 1.11x, 1.10x.

### Why the energy residual is not zero

Folding `dt` into the masses reassociates a floating-point multiply:

```
baseline:  m1 * (dt * mag)
v4:        (m1 * dt) * mag
```

**Floating-point multiplication is not associative** — the rounding happens at
different points. So 1.313e-15 is expected. It is five orders of magnitude inside the
tolerance. A residual of 1e-6 would be a bug, and this is how you would see it.

## A known imperfection we did not hide

v4's **second** loop (the position update, 100,000 iterations) is slightly *worse* than
the baseline's:

```
baseline   44 instructions/iteration,  3 BINARY_SUBSCR
v4         47 instructions/iteration,  6 BINARY_SUBSCR
```

The baseline unpacked the velocity into locals (`for (r, [vx,vy,vz], m) in bodies`) and
v4 re-reads `v[0]`, `v[1]`, `v[2]`. That is collateral from rewriting the loop target,
not a decision. Reverting just that loop should recover a little more.

We did not measure it — nbody already clears the bar at 1.11x — and inventing a number
for it would be worse than saying so plainly.

## What to say if asked "why is your nbody speedup so much smaller than raytrace's?"

Because nbody was *already efficient at the thing everyone optimizes*. The textbook
`pow` -> `sqrt` rewrite has nothing to win on glibc 2.35, and we can name the symbol
that proves it. What was left was structural overhead, and we removed ~10% of it.

That is a more informative result than a big number would have been: it says the
optimization you find in every guide is **platform-specific**, and we have the two
symbol names to show it.

## Next

`04_raytrace.md` — a benchmark with a completely different bottleneck.
