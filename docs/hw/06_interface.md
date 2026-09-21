# HW 6 — The interface: why accel_top exists

The header of `accel_top.sv` states the whole argument:

> The datapath is the easy part. What decides whether any of its speedup survives is
> how much work crosses the Python boundary per invocation.

## The measurement that forced the design

```
ctypes call with 3 double arguments   595 ns
pe_pair latency                        68 ns
pe_pair throughput interval             2 ns
```

**Calling the hardware costs 595 ns to do 2 ns of work.** A per-operation interface
would be 8.75x slower than the latency it is trying to hide. So the interface cannot be
a register you poke per operation; it must hand over a whole batch.

```
   10 pairs/call   68.30 ns/pair   crossing = 87.1% of the call
 1000 pairs/call    2.66 ns/pair   crossing = 22.3%
10000 pairs/call    2.07 ns/pair   crossing =  2.9%
```

## The non-obvious part

nbody has 5 bodies = **10 pairs per timestep**. At 10 pairs the crossing is still 87%.
So batching *pairs* does not save you either.

**The descriptor therefore carries a STEP COUNT.** The CPU hands over the body array
once and the engine runs many timesteps internally, writing state back only at the end.
20,000 timesteps become one boundary crossing instead of 20,000.

That is the reason this module exists.

## Programming model

```
1. CPU writes the descriptor (base address, body count, dt, step count)
2. CPU writes START = 1
3. Engine DMAs the body array into on-chip SRAM
4. Per timestep: stream every pair through pe_pair, accumulate deltas, integrate
5. Engine DMAs the array back out, sets DONE, optionally raises an interrupt
6. CPU polls DONE or takes the interrupt
```

DMA matters: the hardware fetches its own data rather than being fed word by word,
otherwise the CPU becomes the bottleneck again.

## CSR map (AXI4-Lite slave)

```
0x00  CTRL     W1S  START, IRQ_EN, ABORT
0x04  STATUS   RO   DONE, BUSY, ERR, IRQ
0x08  BODY_PTR RW   base address of the body array in host memory
0x0C  N_BODIES RW
0x10  DT       RW   timestep, binary32
0x14  N_STEPS  RW   timesteps to run before writing back
0x18  PAIRS_LO RO   pairs processed   <- performance counter
0x1C  CYCLES   RO   busy cycles       <- performance counter
```

**The counters are not decoration.** They let the driver report achieved pairs/cycle,
so you find out whether the engine is compute-bound or memory-bound on real data
instead of guessing. They are how we know utilisation is 27% rather than assuming it.

**`W1S` = write-1-to-set.** Writing a 1 sets START; hardware clears it. This avoids a
read-modify-write race between CPU and hardware.

## Memory layout, and a deliberate waste

```
8 words (32 B) per body:
  +0 x   +4 y   +8 z   +12 vx   +16 vy   +20 vz   +24 mass   +28 pad
```

A body needs 7 words and uses 8. The padding costs 12.5% of bandwidth and buys:

- a body never straddles a 64 B cache line
- the DMA burst length is trivial to compute

Spend bandwidth to buy aligned, single-burst access. A real trade, stated in the source.

## Scope caveat, from the source itself

> The AXI interfaces here are **SIMPLIFIED**: a single-beat AXI4-Lite-style CSR slave
> and a simple sequential read/write master, not a burst-optimised, protocol-complete
> AXI4 implementation with outstanding transactions and reordering.

The assignment asks for a design that is complete and logically consistent, not
tape-out ready. A full AXI implementation would add a great deal of code without
changing the argument.

**Volunteer this.** "Our AXI is simplified, here is exactly how" is far stronger than
being asked "is that real AXI?"

## Testbench

```
tb_accel_top: loaded 40 input words
tb_accel_top: descriptor written (n=5, steps=4)
tb_accel_top: DONE after 544 status polls
tb_accel_top: pairs=80 cycles=1629  (expect pairs = 80)
```

It checks `pairs = 80`: 5 bodies, `n(n-1) = 20` pairs per step (no third law — see
`05_processing_elements.md`), times 4 steps. **The performance counter is verified, not
merely present.**

Honest reading of the cycle count: 1629 / 80 = **20 cycles per pair**, not 1. Too few
bodies to fill a 49-stage pipeline, plus DMA and FSM overhead. **27% utilisation.**

## Bug G — spurious writes and a false error flag

The engine wrote 67 words to the bus where it should have written 40, and raised `ERR`
from garbage present in the pipeline during fill. Both were **gating** problems: the
unit was producing output before the pipeline was legitimately full. Fixed by gating
both the write-enable and the error flag on the valid signal that tracks pipeline fill.

## Self-check

1. Why can the interface not be one function call per body pair?
2. Batching 10 pairs still leaves 87% overhead — what is the actual fix?
3. Why does the body layout waste a word?
4. What are the two performance counters for?
5. What is simplified about the AXI, and why is that acceptable?
