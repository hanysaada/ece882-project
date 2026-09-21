# HW 3 — Floating point in hardware, and the two rounding bugs

## First, the thing to get straight

The whole accelerator contains **exactly two arithmetic units**:

```
fp32_mul.sv    multiply two 32-bit floats
fp32_add.sv    add two 32-bit floats
```

That is all. Every other operation is either a sign flip or an algebraic identity:

| operation | how it is done |
|---|---|
| `*` | `fp32_mul` — a real unit |
| `+` | `fp32_add` — a real unit |
| `-` | **`fp32_add` with the sign bit flipped.** No subtract unit exists. |
| `^` (the `-1.5` power) | **No unit at all.** Replaced by `rsqrt` + 2 multiplies. |
| `/` | **No unit at all.** Avoided by algebra. |

This is the actual engineering. Hardware costs area and power, so you build the
minimum set and derive everything else.

### Subtraction is free

From `accel_top.sv`, computing `dx = x1 - x2`:

```systemverilog
fp32_add u_sub_x (..., .a(a_px), .b(nb_px), ..., .y(d_x));
                                    //  ^^ "nb" = negated b
```

It feeds `x1` and a **negated** `x2` into an adder. In IEEE-754, negating a number is
literally flipping bit 31. So subtraction costs one inverter.

Inside `fp32_add`, one line decides which path to take:

```systemverilog
s1_sub <= big_sgn ^ sml_sgn;    // opposite signs -> subtract
```

### The power was eliminated, not built

```
need:  d2 ^ (-1.5)
have:  r = 1/sqrt(d2)                       (from rsqrt)
and:   r^3 = (1/sqrt(d2))^3 = d2^(-1.5)     exactly
```

Two extra multiplies replace an entire power unit. A general `pow` in hardware would
be huge — it is `exp(y * log x)`, so you would need both a log unit and an exp unit.

Same for division: `mag = dt * r^3` is all multiplication.

This is why `rsqrt` is the *only* complicated unit in the design. It is the one thing
that genuinely cannot be built out of multiplies and adds. See `04_rsqrt.md`.

---

## What a 32-bit float is

```
 31   30        23   22                           0
+---+-------------+------------------------------+
| S |  exponent   |           fraction           |
+---+-------------+------------------------------+
  1       8 bits              23 bits
```

Value = `+/- 1.fraction x 2^(exponent - 127)`.

The key detail: **there is an invisible leading 1.** A normalised number always looks
like `1.something`, so storing that 1 would be wasteful — it is implied. You get 24
bits of precision out of 23 stored bits, free.

## Multiplying is easy; adding is not

**Multiply:** multiply the fractions, add the exponents, XOR the signs. Done.

**Add:** the exponents must match first, because the fractions mean different things
otherwise:

```
1.5   = 1.1000... x 2^0
0.125 = 1.0000... x 2^-3
```

So you shift the smaller number's fraction right by the exponent difference to line
them up, *then* add.

And **shifting right throws bits off the end.** That is where both of our bugs lived.

## Guard, round, sticky

You cannot simply discard the shifted-off bits — you would always round down and
errors would accumulate. IEEE-754 requires *round to nearest, ties to even*, so three
extra bits are kept:

| bit | what it means |
|---|---|
| **guard** | the first bit past the end — decides "more than halfway?" |
| **round** | the next one |
| **sticky** | **OR of everything else shifted off** — "was anything down there nonzero?" |

Sticky is the clever one. You cannot keep 200 shifted-off bits, but you do not need
to — you only need to know *whether any of them was a 1*. That single bit
distinguishes "exactly halfway" from "just past halfway", and those round differently.

The rule, as implemented:

```systemverilog
wire round_up = guard & (rnd | sticky | man_pre[0]);   // RNE
```

Read it as: round up if we are at least halfway (`guard`) **and** either strictly past
halfway (`rnd | sticky`) or exactly halfway with an odd last kept bit (`man_pre[0]` —
the "ties to even" rule).

---

## Bug A — the lost sticky bit

The fixed code, with the comment left in the source:

```systemverilog
if (s2_sum[27]) begin                    // carried out
    // Shifting right by one DISCARDS s2_sum[0]. That bit still carries
    // rounding information, so it must be OR'd into the sticky position
    // rather than dropped -- otherwise a value that should round up sees
    // sticky = 0 and rounds down instead.
    norm = {s2_sum[27:2], s2_sum[1] | s2_sum[0]};
    nexp = s2_exp + 1;
end
```

**What went wrong.** When two significands add and *carry out* — the sum needs one
more bit than it had — you shift right by one and increment the exponent. But shifting
right by one **discards the bottom bit**, `s2_sum[0]`.

That bit still carried rounding information. Dropping it meant sticky read 0 when it
should have read 1, so values that should round **up** rounded **down**. The result
was exactly 1 ULP too low.

The fix is `s2_sum[1] | s2_sum[0]` — OR the discarded bit into the sticky position
instead of losing it.

### How it was found, which is the real lesson

`tb_dot3` tested 512 random vectors with **independent** `a` and `b`. It passed. Zero
errors. It could have run forever and never found this.

`pe_pair` computes `dot3(d, d)` — a vector against **itself**. That means summing
three *squares*. Squares are always positive, so there is never any cancellation and
the significands always add in the same direction — which is exactly the condition
that produces a carry-out. It failed on **4 of 512**.

> **Coverage is about the DISTRIBUTION of your inputs, not the count.**

Both testbenches used 512 vectors. One of them was structurally incapable of finding
the bug, because its inputs were the wrong *shape*.

This is the single most quotable result in the hardware half.

## Bug B — the rounding carry

```systemverilog
// A carry out of the 23-bit fraction means the significand became exactly
// 2.0 (the fraction was all ones). Represent that as 1.0 x 2^(e+1): the new
// fraction is ZERO, not the old fraction shifted right.
wire        rcarry  = man_rnd[23];
wire [22:0] man_fin = rcarry ? 23'd0 : man_rnd[22:0];
wire signed [9:0] exp_fin = nexp + (rcarry ? 10'sd1 : 10'sd0);
```

**What went wrong.** Rounding can push the fraction past its range. If the fraction
was all ones (`1.111...1`) and you round up, you get exactly `10.000...0` — that is,
**exactly 2.0**.

The correct representation is `1.0 x 2^(e+1)`, so the new fraction must be **zero**.

The buggy version shifted the bits right instead, which produces a significand of
**1.5**, not 1.0. Wrong by 50% — but only in that one exact case.

It passed **511 of 512** random vectors. A single failure. With 100 test vectors
instead of 512 we would have shipped it.

---

## Why both bugs belong in the presentation

Look at the detection rates:

| bug | how many vectors caught it |
|---|---|
| rounding carry | **1 of 512** |
| lost sticky bit | **4 of 512**, and only in one of two testbenches |

These are not bugs you find by reading code, and not bugs a handful of directed tests
would reveal. You find them by comparing against an **exact reference** over many
inputs — which is exactly why the golden model was written first.

It is also the honest answer to *"how do you know your Verilog is correct?"* The
answer is not "the tests pass". It is: **"simulation found these specific bugs, here
is what each one was, and here is why one testbench could never have found one of
them."**

A test suite that has never failed is a test suite you should not trust.

---

## Self-check

1. How many arithmetic units does the design contain, and what are they?
2. How is subtraction implemented? How is the `-1.5` power implemented?
3. Why does adding two floats need a shift, when multiplying does not?
4. What does the sticky bit record, and why is one bit enough?
5. When rounding carries out of the fraction, why must the new fraction be *zero*
   rather than the old one shifted right?
6. Why did `tb_dot3` miss the sticky-bit bug when `tb_pe_pair` caught it?

Question 6 is the one to have ready.

---

Next: `04_rsqrt.md` — the one genuinely complicated unit, and why 64 table entries and
2 Newton iterations.
