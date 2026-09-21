# HW 5 — The processing elements, and the worst bug in the project

## The two PEs, and the shared units

`pe_pair` does nbody's kernel. `pe_ray` does raytrace's. Both are 49 cycles latency,
II = 1. And both **instantiate the same `dot3` and the same `rsqrt`**:

```
        +-------------------------+
        |  dot3  (9)   rsqrt (25) |   <- shared units
        +-------------------------+
             ^              ^
        +----+----+    +----+-----+
        | pe_pair |    | pe_ray   |
        | (nbody) |    |(raytrace)|
        +---------+    +----------+
```

This is the "one datapath, two entry points" claim made physical, and it is what
justifies a single accelerator against two independent benchmarks. It is also why the
block diagram was redrawn: the first version drew connection lines between boxes, the
second shows **containment**, which is the actual architectural point.

## The design decision inside pe_pair

From the module header:

> The unit returns **DELTAS** rather than updated velocities. That is deliberate: a body
> appears in several pairs, so the accumulation must happen where all of a body's pairs
> are visible. Doing it here would need a read-modify-write on shared state and would
> serialise the pipeline. `accel_top.sv` accumulates.

So `pe_pair` computes "here is how much to change body 1 and body 2 by" and hands that
upward. It never touches memory. That separation of *compute* from *accumulate* is what
keeps the initiation interval at 1.

A second small decision in the same header: the sign convention. `dv1` is what to
SUBTRACT from body 1 and `dv2` what to ADD to body 2, matching the Python source
exactly, so no negation logic is needed inside the PE.

---

## Bug E — the read-after-write hazard

The most interesting bug in the project, because **it exists only because the pipeline
is deep.** On a single-cycle unit it could not happen.

### What went wrong

The pipeline is 49 stages. Feed in pair (0,1) and its answer arrives **49 cycles
later**.

Body 0 — the Sun — appears in pairs (0,1), (0,2), (0,3), (0,4), and those are issued on
consecutive cycles:

```
cycle  1:   issue (0,1)
cycle  2:   issue (0,2)   <- reads body 0's velocity
...
cycle 50:   (0,1)'s update to body 0 finally lands
```

Pair (0,2) read body 0's velocity **48 cycles before pair (0,1) wrote it.** It used a
stale value. Every pair after the first one for a given body was wrong.

### How the symptom identified it

**The Sun was wrong by the largest margin.** It appears in the most pairs, so it
suffered the most stale reads. Jupiter less. Neptune least.

That is a generalisable debugging pattern: when the error magnitude correlates with how
often a value is *touched*, you are looking at a dependency problem, not an arithmetic
one. An arithmetic bug would be spread evenly.

### The fix, part 1 — stop writing to body j

The original exploited Newton's third law: compute pair (i,j) once, apply the force to
`i` and the negated force to `j`. Clever, and it halves the arithmetic.

But it means **every pair writes to two bodies**, which doubles the opportunities for a
hazard. So it was dropped in favour of i-outer / all-j:

```
before:  n(n-1)/2 pairs,  each writes 2 bodies
after:   n(n-1)   pairs,  each writes 1 body
```

**Twice the arithmetic, half the hazard.** That is a deliberate trade, and it is the
right one here: the pipeline has spare throughput (II = 1 means it is starved anyway at
n = 5), whereas *stalling* to resolve a hazard would cost far more. Cheap resource,
expensive resource — spend the cheap one.

### The fix, part 2 — four partial accumulators, round-robin

Even accumulating onto body `i` alone is sequential: `acc = acc + delta` has to read the
previous `acc`. And `fp32_add` takes 3 cycles.

```systemverilog
localparam int NPART = 4;            // > fp32_add latency of 3

reg [31:0] accx [0:NPART-1];
reg [31:0] accy [0:NPART-1];
reg [31:0] accz [0:NPART-1];
reg [1:0]  psel;                     // which partial the RESULT belongs to
```

Four accumulators used in rotation. Touching any one of them only every 4th cycle
guarantees its previous result — 3 cycles old — has always landed. At the end of each
body the four partials are reduced to one.

**`NPART = 4` is not arbitrary: it must exceed the adder latency of 3.** If it were 2,
you would come back to a partial before its previous sum had emerged, and you would have
recreated the same bug one level down.

The cost, stated honestly in the source: `2x` the pair work and `NPART * 3` accumulator
registers. That is the price of keeping II = 1, and the whole performance claim rests on
streaming one pair per cycle.

---

## Bug F — introduced by the fix itself

```systemverilog
// psel must follow the pipeline. Total issue-to-result latency is
// SUB_LAT + pe_pair latency = 3 + 49 = 52, NOT 49: the delta-subtract stage
// sits in front of the PE. Delaying by 49 made the partial-accumulator
// selector run 3 cycles ahead of its own data, so results landed in the wrong
// partial.
```

`psel` says which of the four accumulators a result belongs to. It has to be delayed so
that it arrives together with the data it describes.

It was delayed **49** cycles. The real path is **52**, because the 3-cycle
delta-subtract stage (`dx = x1 - x2`) sits *in front* of the PE.

So every result landed in the wrong accumulator. Three cycles off, silently wrong
answers, no error flag.

**This is the lesson from `02_pipelining.md` biting for real:** anything that meets at a
stage must have travelled the same number of cycles. Being early is exactly as broken as
being late.

Note also the source comment's observation that `tag_i` / `tag_j` do **not** have this
problem "by construction, because they are fed from `i_al`/`j_al`, which are already
delayed by `SUB_LAT`". That is the better engineering pattern: derive a signal from
something already correctly aligned, rather than re-deriving its delay by hand and
getting the arithmetic wrong.

---

## The free negation, again

```systemverilog
wire [31:0] n_dv1x = {~dv1x[31], dv1x[30:0]};
```

The force on body `i` from body `j` is the negative of `pe_pair`'s `dv1` output.
Negating an IEEE-754 number is flipping bit 31. One inverter, zero cycles, no adder.

Same trick as subtraction in `03_floating_point.md`. Worth noticing how often "free in
hardware" comes down to rewiring rather than computing.

---

## What to say if asked about this bug

> "The pipeline is 49 stages deep, so a result lands 49 cycles after you ask for it. The
> Sun appears in four consecutive pairs, so the second pair read the Sun's velocity
> before the first pair's update had landed. The symptom pointed straight at it — the Sun
> was wrong by the most, because it is in the most pairs. We fixed it by dropping
> Newton's third law, which doubles the pair count but halves the writes, and by using
> four partial accumulators in rotation so a value is never read before its previous
> update lands. Four, because the adder takes three cycles."

Four sentences that demonstrate pipelining, hazards, symptom-directed debugging, and a
resource trade-off.

---

## Testbench results

```
tb_pe_pair: 512 vectors, 0 errors                              PASS
tb_pe_ray:  512 vectors (262 hits, 250 misses), 0 errors       PASS
```

Note `tb_pe_ray`'s split: 262 hits and 250 misses. That is deliberate — the ray-sphere
test has two outcomes (the discriminant is negative or it is not), and a stimulus that
only produced hits would leave the miss path completely untested. Roughly half and half
means both branches are exercised.

Compare with the sticky-bit bug in `03_floating_point.md`: the same principle, applied
in advance rather than learned the hard way.

---

## Self-check

1. Why does `pe_pair` return deltas rather than updated velocities?
2. Why did this hazard exist at all — what would happen if the pipeline were one cycle
   deep?
3. Why does *doubling* the pair count help?
4. Why is `NPART` 4 rather than 2?
5. Why was `psel` delayed 52 cycles and not 49?
6. Why does `tb_pe_ray` deliberately produce both hits and misses?

---

Next: `06_interface.md` — `accel_top`, CSR/DMA, and the measurement that proves batching
is mandatory.
