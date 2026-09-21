# HW 1 — Why hardware at all?

A learning document, written to be defended out loud. Plain words, with the measured
numbers that back each claim.

Before anything about Verilog, you have to be able to answer one question: **what is
Python doing that hardware would do better?** If you cannot answer that, none of the
rest matters.

---

## Start with one line of nbody

```python
d2 = dx*dx + dy*dy + dz*dz
```

Five arithmetic operations. Here is what CPython actually does for **each one**:

1. Look at `dx` — it is a *pointer* to a `PyFloat` object sitting on the heap
2. Find its type, look up `float.__mul__`
3. Call it
4. **Allocate a brand-new `PyFloat` object** on the heap to hold the result
5. Return a pointer to that new object
6. Later, free it again

So that single line creates and destroys **five heap objects**. The part that actually
does arithmetic — the multiply itself — is one machine instruction. Everything else is
bookkeeping about objects that describe numbers.

## And we measured it

From `results/perf/HOTSPOTS.md`, perf against `python3-dbg`, self time:

```
46.83%  _PyEval_EvalFrameDefault   the bytecode interpreter loop itself
 5.35%  binary_op1                 generic binary-operator dispatch
 4.47%  PyFloat_FromDouble         allocating a new float per result
 3.21%  float_dealloc              freeing them again
```

**7.7% of total runtime spent purely creating and destroying float objects** — and
that is on top of 46.83% in the interpreter loop and 5.35% in operator dispatch.

None of that is arithmetic. All of it disappears in hardware.

---

## The same computation in hardware

```
dx ──┬──→ [multiplier] ──┐
     └──→                │
dy ──┬──→ [multiplier] ──┼──→ [adder] ──→ [adder] ──→ d2
     └──→                │
dz ──┬──→ [multiplier] ──┘
     └──→
```

Three multipliers, physically present on the chip, operating **at the same time**.
Their results travel to the adders as voltages on wires.

What is absent:

- **No objects.** A number is 32 wires carrying 32 bits. There is nothing to allocate.
- **No heap.** Nothing to malloc, nothing to free, no reference counts.
- **No type lookup.** Those wires are *only* ever floats. There is no `__mul__` to
  find because there is no alternative.
- **No sequencing of the three multiplies.** They are three separate pieces of
  silicon. They run in parallel because they are different hardware.

Between stages the values are held in **registers** (flip-flops) — a bank of bits that
captures its input on each clock edge. That is the hardware equivalent of a local
variable, and it costs nothing to "allocate" because it is already there, permanently.

---

## The sentence to say in the presentation

> The accelerator is not faster because silicon is magic. It is faster because **it
> does not do the bookkeeping.** Python spends most of its time managing objects that
> describe numbers. The hardware just has the numbers.

And you can immediately back it with a measured figure: 7.7% on allocation alone,
46.83% in the interpreter loop, 5.35% on operator dispatch — none of which exists in a
datapath.

---

## Why *this* kernel and not something else

The assignment asks for an accelerator that is **not too workload-specific**. So the
kernel had to be something more than one benchmark's private trick.

We chose: **sum three squares, then take an inverse square root of the result.**

Both benchmarks do exactly that:

- **nbody** — `(dx² + dy² + dz²) ** -1.5` for the gravitational force magnitude.
  Newtonian gravity falls off with distance squared, and one more factor of distance
  normalises the direction vector, so the force factor needs `1/distance³` — which is
  the squared distance raised to `-1.5`.
- **raytrace** — distances (`magnitude`) and normalising direction vectors
  (`normalized`), both of which are a dot product followed by a square root or its
  reciprocal.

One piece of hardware justified against two independent workloads. That is the whole
argument, and it is why the design has *one* shared datapath with *two* entry points
rather than two separate accelerators.

### An honest correction to that argument

Our original plan claimed both benchmarks shared a `sqrt`-shaped **bottleneck**. The
profile refuted it:

```
raytrace:  0.065%  math_sqrt
           0.033%  __sqrt_finite
```

Under 0.1%. raytrace is **allocation- and call-bound**, not math-bound — its hottest
line allocates an object.

So the correct version of the argument is: both benchmarks *compute the same
primitive*, which makes one datapath serve both. It is **not** true that both are
bottlenecked on square roots. Saying the stronger thing would be false and would not
survive being asked about.

This is worth volunteering rather than waiting to be caught on, because "we assumed X,
the profile said not-X, here is what we changed" is a better answer than a claim that
happens to be wrong.

---

## What NOT to claim

Be clear about the boundary of the work:

- The RTL is **simulated and verified**, not synthesised. 500 MHz is a *target*, and
  there is no timing report proving it closes.
- There is **no FPGA and no end-to-end speedup measurement.** The benchmark was never
  run with the accelerator attached.
- The predicted speedups (2.66x nbody, 2.04x raytrace) are **calculated** from
  Amdahl's law using a profile-measured accelerable fraction and an assumed clock.
  They are bounded predictions, not results.

The measured speedups in this project are the **software** ones: 1.11x and 1.60x. The
hardware is the design-and-analysis half, which is exactly what the assignment's
deliverable asks for — a *Hardware Acceleration Proposal* with I/O, trade-offs and a
block diagram.

---

## Self-check

Answer these out loud, notes closed:

1. Why is `dx*dx` in Python much more than a single multiply?
2. What is the one-sentence reason hardware wins on this workload?
3. Why did we accelerate this kernel rather than trying to speed up the interpreter
   loop, which is 46.83% and much larger?
4. What is the honest correction to the "both benchmarks need a fast square root"
   claim?

Answer to 3, since it is the one most likely to be asked: the interpreter loop is not
a *kernel*, it is general control flow with data-dependent branches — exactly what
hardware is bad at and a CPU is already optimised for. The arithmetic kernel is
regular, has no branches, and is the same every iteration, which is precisely what a
pipelined datapath is good at. You accelerate the part with a fixed shape, not the
part that is merely large.

---

Next: `02_pipelining.md` — where "49 cycles latency, one result every cycle" comes
from.
