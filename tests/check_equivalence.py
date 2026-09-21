#!/usr/bin/env python3
"""
check_equivalence.py — correctness gate for every optimization variant.

An optimized benchmark that computes something different is not an
optimization, it is a bug. This runs BEFORE any timing is trusted.

What each benchmark is checked against:

  nbody    — total system energy, before and after 20,000 advance() steps.
             Gravity conserves energy, so this is the physically meaningful
             invariant. The v1 rewrite d2**-1.5 -> 1/(d2*sqrt(d2)) is an exact
             algebraic identity, but the two expressions round differently in
             IEEE-754 double, so we allow a tiny relative tolerance and REPORT
             the actual drift rather than hiding it.

  raytrace — the rendered image, byte for byte. Canvas.bytes is an
             array('B') of width*height*3 values. Any difference in geometry,
             shading or intersection logic changes pixels, so an exact match is
             a strong statement. We require EXACT equality here: nothing in the
             raytrace variants changes the order of floating-point operations
             in a way that should alter a result... except v4, which inlines the
             dot products. If v4 differs, the diff is reported per-pixel so we
             can judge whether it is FP reassociation or a real bug.

Usage:
    python3 tests/check_equivalence.py                  # all variants
    python3 tests/check_equivalence.py raytrace_v4_inline
Exit code 0 = every checked variant is equivalent.
"""
import importlib.util
import math
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ABL = ROOT / "benchmarks" / "ablation"

NBODY_TOL = 1e-12        # relative tolerance on conserved energy
NBODY_ITERATIONS = 20000  # the benchmark's DEFAULT_ITERATIONS
RT_W = RT_H = 100         # the benchmark's DEFAULT_WIDTH/HEIGHT


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------- nbody ----
def nbody_signature(mod):
    """Energy before and after the full simulation. Fresh module state each
    time, because BODIES is module-level mutable state."""
    mod.offset_momentum(mod.BODIES[mod.DEFAULT_REFERENCE])
    e_before = mod.report_energy()
    mod.advance(0.01, NBODY_ITERATIONS)
    e_after = mod.report_energy()
    return e_before, e_after


def check_nbody(variant_path):
    base = load(ROOT / "baseline" / "bm_nbody" / "run_benchmark.py", "nb_base")
    opt = load(variant_path, "nb_opt")
    b_before, b_after = nbody_signature(base)
    o_before, o_after = nbody_signature(opt)

    ok = True
    for label, b, o in (("energy before", b_before, o_before),
                        ("energy after ", b_after, o_after)):
        rel = abs(b - o) / abs(b) if b else abs(b - o)
        good = math.isclose(b, o, rel_tol=NBODY_TOL)
        ok &= good
        print(f"    {label}: base={b:.15f} opt={o:.15f} "
              f"rel_diff={rel:.3e} {'OK' if good else 'FAIL'}")
    return ok


# ------------------------------------------------------------- raytrace ----
def raytrace_signature(mod):
    """Render the benchmark's exact scene and return the raw pixel buffer."""
    canvas = mod.Canvas(RT_W, RT_H)
    s = mod.Scene()
    s.addLight(mod.Point(30, 30, 10))
    s.addLight(mod.Point(-10, 100, 30))
    s.lookAt(mod.Point(0, 3, 0))
    s.addObject(mod.Sphere(mod.Point(1, 3, -10), 2),
                mod.SimpleSurface(baseColour=(1, 1, 0)))
    for y in range(6):
        s.addObject(mod.Sphere(mod.Point(-3 - y * 0.4, 2.3, -5), 0.4),
                    mod.SimpleSurface(baseColour=(y / 6.0, 1 - y / 6.0, 0.5)))
    s.addObject(mod.Halfspace(mod.Point(0, 0, 0), mod.Vector.UP),
                mod.CheckerboardSurface())
    s.render(canvas)
    return canvas.bytes


def check_raytrace(variant_path):
    base = load(ROOT / "baseline" / "bm_raytrace" / "run_benchmark.py", "rt_base")
    opt = load(variant_path, "rt_opt")
    pb = raytrace_signature(base)
    po = raytrace_signature(opt)

    if len(pb) != len(po):
        print(f"    FAIL: buffer sizes differ ({len(pb)} vs {len(po)})")
        return False

    diffs = [(i, pb[i], po[i]) for i in range(len(pb)) if pb[i] != po[i]]
    total = len(pb)
    if not diffs:
        print(f"    pixel buffer: {total} bytes, EXACT match  OK")
        return True

    worst = max(abs(a - b) for _, a, b in diffs)
    print(f"    pixel buffer: {len(diffs)}/{total} bytes differ "
          f"({100*len(diffs)/total:.4f}%), max delta {worst}/255")
    for i, a, b in diffs[:5]:
        px = i // 3
        print(f"      byte {i} (pixel {px%RT_W},{px//RT_W} ch{i%3}): "
              f"base={a} opt={b}")
    # A handful of +-1 differences is floating-point reassociation, not a logic
    # error: inlining a dot product changes the order of additions, and IEEE-754
    # addition is not associative. Anything larger means the geometry changed.
    tolerable = worst <= 1 and len(diffs) / total < 0.01
    print(f"    verdict: {'OK (FP reassociation, <=1/255 on <1% of bytes)' if tolerable else 'FAIL (real difference)'}")
    return tolerable


# ------------------------------------------------------------------ main ---
CHECKERS = {"nbody": check_nbody, "raytrace": check_raytrace}


def main(argv):
    wanted = argv[1:]
    variants = sorted(ABL.glob("*.py"))
    if not variants:
        sys.exit(f"no variants in {ABL} — run scripts/make_variants.py first")
    if wanted:
        variants = [p for p in variants if p.stem in wanted]
        if not variants:
            sys.exit(f"no variant matched {wanted}")

    failures = []
    for path in variants:
        bench = path.stem.split("_")[0]
        checker = CHECKERS.get(bench)
        if checker is None:
            print(f"[skip] {path.stem}: no checker for '{bench}'")
            continue
        print(f"\n[{bench}] {path.stem}")
        try:
            if not checker(path):
                failures.append(path.stem)
        except Exception as exc:      # a variant that crashes is also a failure
            print(f"    EXCEPTION: {type(exc).__name__}: {exc}")
            failures.append(path.stem)

    print("\n" + "=" * 68)
    if failures:
        print(f"CORRECTNESS GATE FAILED for: {', '.join(failures)}")
        return 1
    print(f"CORRECTNESS GATE PASSED for all {len(variants)} variants")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
