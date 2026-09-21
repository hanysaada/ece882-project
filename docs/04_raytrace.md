# 04 — Optimizing raytrace: 1.61x without touching a single calculation

Written for a fellow ECE student who has not done this project.

The interesting thing about raytrace is that **none of the four optimizations changes
any arithmetic.** Every one of them removes *overhead* — function calls, dictionary
lookups, object allocations. The maths is byte-for-byte identical throughout.

## What raytrace computes

A 100x100 image of spheres above a checkerboard plane, with reflections to recursion
depth 3.

The data structures are ordinary Python classes:

```python
class Vector:  x, y, z
class Point:   x, y, z
class Sphere:  centre, radius
class Ray:     point, vector
class Canvas:  array('B') of width*height*3 bytes
```

For every pixel it casts a primary ray, tests it against every object, then casts a
shadow ray per light and reflection rays. So the inner operations — `dot`, `magnitude`,
`normalized`, `intersectionTime` — run an enormous number of times.

## The correctness test, and it is a strong one

`Canvas.bytes` is 100 x 100 x 3 = **30,000 bytes**. Any change to geometry, shading or
intersection logic moves at least one pixel.

So the test is a **byte-for-byte exact match** of the rendered image. Not a tolerance —
an identity. All four variants pass exactly, which is a strong statement that nothing
broke.

Compare with nbody, where an algebraic rewrite forced a 1e-15 tolerance. Here we get
exactness, because none of the changes touch a floating-point operation.

## What the profile said

py-spy, 59,692 samples:

```
11.81%  __sub__:115           Point - Point, allocates a Vector
10.81%  dot:53                the dot product body
 6.97%  _lightIsVisible:285
 5.25%  dot:52                other.mustBeVector()
 5.23%  __init__:25           Vector.__init__
 5.12%  scale:49
 4.41%  intersectionTime:145
```

perf at C level, grouped:

```
~11%    call overhead        call_function, frame_dealloc,
                             _PyObject_VectorcallTstate, _PyEval_MakeFrameVector
~6.6%   attribute lookup     lookdict_split, _PyDict_GetItemHint, _PyObject_GetMethod
```

And the finding that redirected the hardware argument:

```
0.065%  math_sqrt
0.033%  __sqrt_finite
```

**raytrace is not sqrt-bound.** It is call- and allocation-bound. Its hottest line
allocates an object. We had assumed otherwise, and the profile corrected us.

## Variant 1 — delete code that does nothing (1.10x)

```python
def dot(self, other):
    other.mustBeVector()          # <-- deleted
    return self.x*other.x + self.y*other.y + self.z*other.z
```

Go and look at `mustBeVector`:

```python
def mustBeVector(self):
    return self
```

**That is the whole function.** It is a type assertion the author left in — it returns
`self` and the caller discards the result.

But in Python a function call is not free. It builds a frame object, pushes it, executes
the body, tears the frame down, and returns a value nobody uses. py-spy measured line 52
— the guard call itself — at **5.25% of all samples**.

We removed four of them: in `Vector.dot`, `Vector.__sub__`, `Vector.cross`, and
`Point.__add__`.

**This is the find we are proudest of, and it appears in no guide we were given.** We
found it by reading the source after the profile pointed at `dot`. That is the whole
lesson: the profile tells you *where*, but you still have to read the code to see
*what*.

Phase 2 predicted ~5.5%. Measured 1.10x, i.e. 9%.

**Is it safe?** `Point.__sub__` keeps its behaviour because in this scene it is only ever
called with `Point` operands. The 30,000-byte image match verifies that empirically
rather than by argument.

## Variant 2 — `__slots__` (1.13x)

```python
class Vector(object):
    __slots__ = ('x', 'y', 'z')
```

Three lines total, on `Vector`, `Point` and `Ray`.

**The mechanism.** By default every Python instance carries a `__dict__` — an actual
hash table. So `self.x` is a `LOAD_ATTR` that walks the type's MRO looking for a
descriptor, then hashes the string `"x"` and probes the instance dictionary.

`__slots__` tells CPython the complete set of attributes in advance. It then allocates
fixed descriptor slots instead of a dict, and `self.x` becomes **a direct load at a
known offset**. The dictionary's memory disappears entirely, which also reduces
allocation pressure.

The C profile named the cost precisely before we made the change: `lookdict_split`
2.22%, `_PyDict_GetItemHint` 2.25%, `_PyObject_GetMethod` 2.13%.

**A detail that catches people:** `Vector` has class attributes assigned *after* the
class body (`Vector.ZERO`, `Vector.RIGHT`, `Vector.UP`, `Vector.OUT`). Those are
class-level, not instance-level, so `__slots__` does not forbid them. If they had been
instance attributes this would have raised `AttributeError`.

### A prediction we made in advance and confirmed

This measured **1.05x on Python 3.12** and **1.13x on Python 3.10**.

Python 3.11 introduced the **specializing adaptive interpreter**, which rewrites hot
bytecode in place and caches attribute lookups inline. So on 3.12 the interpreter was
already doing part of what `__slots__` does. On 3.10 there is no such machinery, so
removing a dict probe is worth more.

We stated the direction *before* measuring. Getting the direction right in advance is
the part that matters — it means the mechanism was understood rather than guessed.

### The thing worth knowing about `__slots__`

**It emits identical bytecode.** `python3 -m dis` cannot show this optimization at all,
because the change is in the *object layout*, not the instruction stream.

That is a useful corrective: disassembly is not a universal explanation. Some
optimizations live below the bytecode.

## Variant 3 — hoist `radius*radius` — NOT SIGNIFICANT

```python
# in __init__
self.radius2 = radius * radius

# in intersectionTime
discriminant = self.radius2 - (cp.dot(cp) - v*v)    # was self.radius * self.radius
```

`Sphere.intersectionTime` recomputed `self.radius * self.radius` on **every call** — two
`LOAD_ATTR` and a multiply, per ray per sphere. The radius never changes after
construction. Classic loop-invariant hoisting, just across a call boundary rather than a
loop.

It measured 4.1% on the host. Here: **not significant.**

**Why, almost certainly:** v2's `__slots__` had *already* made those two attribute reads
cheap. The optimizations overlap and v2 got there first.

This is a real insight about cumulative ablation: **the order you apply optimizations in
changes their apparent individual value.** We kept the null row rather than reordering to
make it look better. An ablation table where everything conveniently works is less
believable than one with a null row explained.

## Variant 4 — inline the dot products (1.29x, the biggest win)

```python
# before
def intersectionTime(self, ray):
    cp = self.centre - ray.point              # allocates a Vector
    v = cp.dot(ray.vector)                    # Python method call
    discriminant = self.radius2 - (cp.dot(cp) - v*v)   # another one
    ...
    return v - math.sqrt(discriminant)

# after
def intersectionTime(self, ray, _sqrt=math.sqrt):
    c = self.centre
    p = ray.point
    rv = ray.vector
    cx = c.x - p.x
    cy = c.y - p.y
    cz = c.z - p.z
    v = cx*rv.x + cy*rv.y + cz*rv.z
    discriminant = self.radius2 - (cx*cx + cy*cy + cz*cz - v*v)
    if discriminant < 0:
        return None
    return v - _sqrt(discriminant)
```

Per ray-sphere test the original does:

1. one `Vector` **allocation** (`cp`), immediately garbage
2. two Python **method calls** (`cp.dot(...)` twice)

The rewrite does the same arithmetic with three local variables. No allocation, no
calls.

**Why this is the biggest win:** `intersectionTime` is the hottest path in the whole
benchmark. It runs for every ray against every object — and then *again* for every light
inside `_lightIsVisible`, which the profile put at 6.97%.

`math.sqrt` is also bound as a default argument for the `LOAD_FAST` trick from
`03_nbody.md`. Note that *here* it pays, because we are not removing a `pow` — we are
just making an existing call cheaper.

## The ablation table

Variants are **cumulative**: each adds one change to the one above.

```
                 this change alone   cumulative
v1_noguards           1.10x            1.10x
v2_slots              1.13x            1.25x
v3_radius2       not significant       1.24x
v4_inline             1.29x            1.61x
```

Reading it: v1 alone gives 10%. Adding `__slots__` gives another 13%, for 25% total.
v3 adds nothing. v4 adds 29% more, reaching **1.61x**.

**Why an ablation table matters.** Without it you can only say "these four changes
together gave 61%", which attributes nothing. With it you can defend each change
individually — and you discover things like v3 being subsumed by v2, which you would
never see from a single before/after number.

## The final result

```
367 ms -> 229 ms = 1.60x  (37.6%)
median 364 +- 4 ms -> 229 +- 3 ms
noise floor: not significant
correctness: 30,000 bytes, EXACT match
```

(The 1.61x in the ablation and 1.60x in the final comparison differ because they are
separate measurements of the same code — well inside the spread.)

## The summary worth remembering

raytrace gave 1.60x and **not one arithmetic operation changed**. The four wins were:

1. a function call that computed nothing
2. a hash-table lookup that should have been an offset load
3. (nothing — subsumed)
4. an object allocation and two method calls per ray-sphere test

In a pure-Python program, **overhead is the workload.** That is the single most
transferable lesson in this project, and it is also the argument for the hardware half:
a datapath in silicon does this arithmetic in registers with no frames, no dictionaries
and no allocation at all.

## Next

`05_results.md` — putting the numbers together and defending them.
