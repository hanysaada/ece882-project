# baseline/ — the original benchmarks, untouched

Verbatim copies of `run_benchmark.py` for **nbody** and **raytrace** as shipped by
**pyperformance 1.14.0**. Nothing in this directory is ever edited.

## Why keep copies at all

1. **We are about to modify these benchmarks.** Once the optimized versions exist,
   the originals live only inside the installed package -- and that package may be a
   different version on a different machine. A pristine in-repo copy makes the
   before/after comparison reproducible.

2. **So a reader can diff.** This shows exactly what changed and nothing else:
   ```bash
   diff baseline/bm_nbody/run_benchmark.py benchmarks/bm_nbody_opt/run_benchmark.py
   ```

## What CHECKSUMS.sha256 is for

A checksum is a short fingerprint computed from a file's contents. Identical files
give identical fingerprints; change a single character and the fingerprint changes
completely. So comparing two short strings answers "are these files exactly the
same?" without needing both files to hand.

It guards against one specific, **silent** failure:

- The optimizations were measured against these exact files, from pyperformance 1.14.0.
- Installing pyperformance on another machine gets whatever version is current there.
- If that version changed the benchmark -- a different iteration count, a tweaked
  inner loop -- then the baseline and the optimized run are **two different
  programs**, and every speedup number is meaningless.
- Nothing in the output would reveal it. The timings would look perfectly plausible.

So verify before trusting any measurement:

```bash
cd baseline && sha256sum -c CHECKSUMS.sha256
```

Expected:
```
bm_nbody/run_benchmark.py: OK
bm_raytrace/run_benchmark.py: OK
```

If it reports `FAILED`, the installed source differs. Do not ignore it: copy the
local version in, re-record the checksums with `sha256sum ... > CHECKSUMS.sha256`,
re-measure, and state the pyperformance version in the report. Never silently mix
source versions.

## What these two benchmarks actually compute

### nbody (156 lines)
Simulates the Sun plus Jupiter, Saturn, Uranus and Neptune under mutual gravity
for **20,000 timesteps** (`DEFAULT_ITERATIONS`). It comes from the Computer
Language Benchmarks Game.

- **Data structure:** each body is `[[x,y,z], [vx,vy,vz], mass]` -- plain Python
  lists and a float. `SYSTEM` is the list of 5 bodies; `PAIRS` is all 10 unique
  pairs of them.
- **Hot loop, `advance()`:** for each pair, compute the component distances
  `dx,dy,dz`, then the force magnitude
  `mag = dt * (dx*dx + dy*dy + dz*dz) ** (-1.5)` (line 85), then nudge both
  bodies' velocities. Afterwards a second loop moves each body by
  `position += dt * velocity`.
- **Why the `-1.5` power:** Newtonian gravity falls off with distance squared, and
  one more factor of distance normalises the direction vector -- so the force
  factor needs `1/distance^3`, i.e. the squared distance raised to `-1.5`.
- **Correctness invariant:** `report_energy()` runs before and after. Gravity
  conserves total energy, so a change that alters the reported energy has altered
  the physics and is a bug, not an optimization.

### raytrace (409 lines)
Renders a 100x100 image of spheres above a checkerboard plane, with reflections to
recursion depth 3. Adapted from a toy raytracer by Callum and Tony
Garnock-Jones.

- **Data structures:** `Vector` and `Point` classes holding `x, y, z`; `Sphere`
  (centre + radius); `Ray` (origin + normalised direction); `Canvas` (an
  `array('B')` of width*height*3 bytes).
- **Hot work:** `Vector.dot()`, `magnitude()` (a `sqrt` of a dot product),
  `normalized()` (a reciprocal square root) and `Sphere.intersectionTime()` (a
  quadratic discriminant plus a `sqrt`). For every pixel a primary ray is traced
  against every object, plus a shadow ray per light and reflection rays.
- **Correctness invariant:** the rendered image. `Canvas.bytes` is 100*100*3 =
  **30,000 bytes**; any change to geometry, shading or intersection logic moves
  pixels, so a byte-for-byte match is a strong statement that nothing broke.

### Why this pair was chosen
Both are pure-Python floating-point 3-D vector maths, so both have real headroom
above the assignment's 7% bar. They also share a primitive -- sum three squares,
then take an inverse power of the result -- so a single hardware accelerator can be
justified against two independent workloads.

Note the profiling later contradicted half of that reasoning: nbody is genuinely
math-bound, but raytrace turned out to be **allocation-bound** (no `sqrt` appears
above 0.5% of its samples). See `report_raytrace.txt`.

## Finding the installed originals on any machine

```bash
find / -path "*bm_nbody*/run_benchmark.py" 2>/dev/null
# typically .venv/lib/python3.X/site-packages/pyperformance/data-files/benchmarks/
```
