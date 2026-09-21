# HW 4 — rsqrt: the only genuinely hard unit

Everything else in the accelerator is multiplies and adds. `1/sqrt(x)` cannot be built
that way, so it gets its own method — and its own two bugs.

## The approach

There is no closed-form way to get `1/sqrt(x)` from `+`, `-` and `*`. So:

1. **Guess** — read a rough answer out of a small lookup table
2. **Refine** — improve it with Newton-Raphson

That pattern (cheap approximation, then iterate) is how most transcendental functions
are done in hardware.

---

## Step 1 — the exponent is free, and that is what makes the table small

Any positive binary32 can be written `x = mm * 2^(2k)` with `mm` in `[1,4)`. Then:

```
1/sqrt(x) = (1/sqrt(mm)) * 2^(-k)
```

The exponent contribution is **a subtract and a shift** — free in hardware. So you
only need a table for `1/sqrt(mm)` over one narrow range, instead of for every possible
float.

Splitting into even and odd exponent cases:

```
e odd   ->  mm = 2m,  k = (e-1)/2
e even  ->  mm = 4m,  k = (e-2)/2
```

**Bug C lived here.** The even/odd normalisation was wrong, producing a constant
**~5.6% error**. It was caught by the golden model's own self-test, before any Verilog
existed — which is the argument for writing the model first. Had it survived, every
testbench would have "passed" against a wrong reference.

## Step 2 — the seed table

64 entries of 16 bits, stored as Q2.14 fixed point. Index it with the top bits of `mm`
and get back a rough `1/sqrt(mm)` — about 5 correct bits.

**Bug D was here, and the fix is instructive.** The table was indexed with the exponent
parity handled backwards: **486 of 512 vectors failed.**

The fix was not a patch to the logic. It changed the *representation*: the index became
a bit concatenation, `{exponent parity, top mantissa bits}`. 486 failures became 1.

> When almost everything fails, you usually have the **encoding** wrong, not the logic.

## Step 3 — Newton-Raphson

We want `y = 1/sqrt(x)`. Define `f(y) = 1/y^2 - x` and find its root. Newton's method
gives the update:

```
y  <-  y * (1.5 - 0.5 * x * y^2)
```

**Each iteration roughly TRIPLES the number of correct bits** — quadratic convergence.
Starting from ~5 bits in the table: one iteration gives ~15, two gives ~24. And 24 bits
is exactly binary32's precision, which is why two is the right number.

Cost per iteration, and why two of the four operations are free:

| operation | cost |
|---|---|
| `y * y` | 1 multiply |
| `x * y^2` | 1 multiply |
| `y * t` | 1 multiply |
| `0.5 *` | **free** — decrement the exponent |
| `1.5 -` | **free** — subtract a constant |

**3 multiplies + 1 subtract = 12 cycles per iteration.**

Hence the latency: `1 (table) + 2 * 12 (Newton) = 25 cycles`.

---

## Why 64 entries and 2 iterations — the measured answer

The golden model swept the design space. Maximum error in ULP:

```
   entries |  0 iters   1 iter   2 iters   3 iters
-----------+------------------------------------------
   16 (4b) |   732650    47301       201         2
   64 (6b) |   190954     3249         2         2    <- design point
  256 (8b) |    48082      208         2         2
```

Read it across and down:

- **64 entries, 2 iterations -> 2 ULP.** Good enough for binary32.
- **256 entries, 2 iterations** -> still 2 ULP. Four times the ROM, no benefit.
- **64 entries, 3 iterations** -> still 2 ULP. Twelve more pipeline stages, no benefit.
- **16 entries** -> needs 3 iterations to reach 2 ULP. You would trade 1024 bits of ROM
  for 12 pipeline stages and 3 more multipliers.

**That is the knee.** Stated as a trade: *we spend 64 x 16 = 1024 bits of ROM in order
to save a pipeline stage's worth of multipliers.*

This is the clearest example in the project of a design decision that is **quantified
rather than guessed**, and "why 64 and why 2?" is a near-certain question.

It is also why both are `parameter`s rather than hard-coded. Change `NR_ITERS` to 3 and
the latency constant, every delay line and the accuracy all follow automatically.

---

## The testbench result, and a caveat you must volunteer

```
tb_rsqrt: 512 vectors, max error 0 ULP (budget 4), mean 0/1000 ULP   PASS
```

**This is better than the model predicted, and you have to explain why rather than
claim it.**

The 512 test vectors did not include the model's worst case (around
`x = 1.018e-06`). So "0 ULP" means *these 512 inputs came out exact* — not *the unit is
exact everywhere*. The honest bound is the **2 ULP** from the sweep, which is what the
module header documents.

Same lesson as the sticky-bit bug in `03_floating_point.md`: the inputs you choose
determine what you are entitled to conclude. A green test result is a statement about
your stimulus as much as about your hardware.

If asked "so is it exact?", the answer is: *"no — max 2 ULP by the model's sweep, and
the 512-vector testbench happened to hit only exact cases. We quote 2 ULP."*

---

## Special values

`x <= 0`, NaN and Inf produce a quiet NaN and raise the `err` flag. The software wrapper
must not feed those in, and it does not:

- nbody's `d2` is strictly positive for distinct bodies
- raytrace tests `discriminant < 0` **before** taking a root

Worth knowing, because "what happens if I give it a negative number?" is an easy
question to ask and an easy one to answer well.

---

## Self-check

1. Why does splitting off the exponent make the lookup table small?
2. What does one Newton iteration cost, and why are the `0.5 *` and `1.5 -` free?
3. Why 64 entries and 2 iterations, rather than 256 and 2, or 16 and 3?
4. The testbench reports 0 ULP and the model reports 2 ULP. Which do you quote, and
   why?
5. Bug D made 486 of 512 vectors fail. What does a failure rate that high usually
   indicate?

---

Next: `05_processing_elements.md` — assembling the units into the two kernels, and the
read-after-write hazard that only shows up because the pipeline is 49 stages deep.
