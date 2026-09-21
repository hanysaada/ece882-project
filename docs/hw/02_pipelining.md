# HW 2 — Pipelining, and where "49 cycles" comes from

This is the concept most likely to be probed, because the headline claim sounds
self-contradictory: **49 cycles of latency, but one result every cycle.**

---

## The problem pipelining solves

Computing one result takes real work: multiply, add, add, look up a table, refine,
refine, multiply, multiply... call it 49 steps of logic.

If you built that as one giant lump of combinational logic, the electrical signal
would need 49 steps' worth of settling time before the answer was valid. You could
only clock it once that had happened — so the clock would have to be very slow, maybe
10 MHz instead of 500 MHz.

Slow clock, one result per clock. Terrible.

## The fix: chop it into stages

Put **registers** between the steps. A register (a bank of flip-flops) captures its
input on each clock edge and holds it steady.

```
        stage 1      stage 2      stage 3            stage 49
input →[logic]→[R]→[logic]→[R]→[logic]→[R]→ ... →[logic]→[R]→ output
```

Now each clock period only has to be long enough for **one stage** to settle instead
of all 49. So the clock can run roughly 49x faster.

## The part that actually matters

Once a value moves from stage 1 into stage 2, **stage 1 is empty**. So you feed a new
one in immediately.

```
cycle 1:   [A][ ][ ][ ][ ]...
cycle 2:   [B][A][ ][ ][ ]...
cycle 3:   [C][B][A][ ][ ]...
...
cycle 49:  [.][.][.][.][A]   <- A comes out
cycle 50:  [.][.][.][.][B]   <- B comes out
cycle 51:  [.][.][.][.][C]   <- C comes out
```

**A takes 49 cycles to appear. After that, one result emerges every single cycle.**

The analogy: a car factory. A car takes 12 hours to build, but a finished car rolls
off the line every 2 minutes, because 360 cars are in progress simultaneously.

---

## The two numbers, and why both get quoted

| | meaning | ours |
|---|---|---|
| **Latency** | how long *one* result takes | 49 cycles |
| **Initiation Interval (II)** | how often you can start a *new* one | **1 cycle** |

**II is what determines throughput.** II = 1 means *fully pipelined*: nothing blocks,
every stage is independent, you never stall.

At 500 MHz one cycle is 2 ns. So: **one result every 2 ns**, arriving 98 ns after it
was requested.

## Why II = 1 was achievable here

Because each body pair is **independent**. Pair (0,1) does not need pair (2,3)'s
answer. So 49 pairs can be in flight at once with no conflict.

If the computation were `x = f(x)` — each result feeding the next — II would be 49,
not 1, because you would have to wait for each answer before starting the next. That
is a **loop-carried dependency**, and it is the thing that destroys pipelining.

Remember this. nbody *does* contain such a dependency — the velocities are updated —
and it produced the worst bug in the project. See `05_processing_elements.md`.

---

## Where 49 comes from, exactly

Straight out of `pe_pair.sv`:

```
                                           cycles   running total
dot3      d2 = dx^2 + dy^2 + dz^2             9          9
rsqrt     r  = 1/sqrt(d2)                    25         34
multiply  r x r   = r^2                       3         37
multiply  r^2 x r = r^3                       3         40
multiply  r^3 x dt = mag                      3         43
multiply  mag x mass = b1m                    3         46
multiply  b1m x dx = velocity delta           3         49
```

**9 + 25 + (5 x 3) = 49.**

The sub-numbers:

- **every fp32 multiply is 3 cycles** — the multiplier is split into 3 pipeline stages
  so the clock can be fast. Same for the adder.
- **dot3 = 9** — three multiplies in parallel (3 cycles, all at once), then two adder
  levels: `3 + 3 + 3`.
- **rsqrt = 25** — one cycle to read the lookup table, then two Newton refinement
  steps at 12 cycles each: `1 + 2*12`.

### The design trick hiding in those five multiplies

```
we need:   mag = dt * d2^(-1.5)
we have:   r   = 1/sqrt(d2)      (from rsqrt)
and        r^3 = (1/sqrt(d2))^3 = d2^(-1.5)     exactly
```

**So there is no `pow` unit anywhere in this design.** Two extra multiplies turn the
reciprocal square root into the `-1.5` power. That identity is what lets a *single*
`rsqrt` unit serve nbody, and it is worth knowing because "where is your pow
hardware?" is a fair question.

---

## Those `localparam` lines are not documentation

```systemverilog
localparam int MUL_LAT   = 3;
localparam int DOT3_LAT  = 9;
localparam int RSQRT_LAT = 25;
localparam int L_D2   = DOT3_LAT;              //  9
localparam int L_R    = L_D2 + RSQRT_LAT;      // 34
localparam int L_R2   = L_R  + MUL_LAT;        // 37
localparam int L_R3   = L_R2 + MUL_LAT;        // 40
localparam int L_MAG  = L_R3 + MUL_LAT;        // 43
localparam int L_BM   = L_MAG + MUL_LAT;       // 46
localparam int LATENCY = L_BM + MUL_LAT;       // 49
```

They **size the delay lines**. `dx` has to arrive at that final multiply at cycle 46,
so it travels through a 46-cycle delay line to get there. Change `NR_ITERS` from 2 to
3 and every one of these numbers recomputes automatically, and every delay line
resizes with it.

## `delay_line.sv` — 51 lines, and essential

It does something that looks pointless: delays a signal by N cycles. Here is why it
is necessary. Look at `dot3`:

```
p0 ──→ [adder level 1] ──→ [adder level 2] ──→ out
p1 ──→                          ^
p2 ─────────── ? ───────────────┘
```

`p0 + p1` takes 3 cycles in level 1. But `p2` is ready **immediately**. Wire `p2`
straight to level 2 and it arrives 3 cycles early — and gets added to a *different
pair's* partial sum. Silent, systematic corruption.

So `p2` goes through a 3-cycle delay line to arrive in step.

> **In a pipeline, being early is exactly as broken as being late.** Everything that
> meets at a stage must have travelled the same number of cycles.

This is also why bug E mattered: a control signal was delayed 49 cycles when the data
it had to meet was 52 cycles deep. Someone forgot a 3-cycle stage. Everything looked
plausible until the outputs failed to line up.

---

## The honest caveat, from our own simulation

`tb_accel_top` reported **80 pairs in 1629 cycles** — about 20 cycles per pair, not 1.

Why: nbody has 5 bodies, so only 10 unique pairs. **You cannot fill a 49-stage
pipeline with 10 items.** Add DMA transfers and control-FSM overhead and you get
**27% pipeline utilisation**.

The pipeline is genuinely capable of one pair per cycle. The *problem* is too small to
feed it. A simulation with hundreds of bodies would look completely different.

Reporting the small-n case is the honest choice, and volunteering it is much better
than being caught by someone who divides 1629 by 80.

---

## Self-check

1. Why does splitting work into stages let the clock run faster?
2. What is the difference between latency and initiation interval, and which one sets
   throughput?
3. Why could we achieve II = 1 here, and what kind of computation would prevent it?
4. Why does `p2` need a delay line inside `dot3`?
5. Where is the `pow` hardware?
6. If someone divides 1629 cycles by 80 pairs and asks why it is not 1, what do you
   say?

Answer to 5, since it is a trap: there is none. `r^3` where `r = 1/sqrt(d2)` **is**
`d2^(-1.5)`, so two extra 3-cycle multiplies replace a whole pow unit.

---

Next: `03_floating_point.md` — how floats work in hardware, and the two rounding bugs
that passed 511 of 512 tests.
