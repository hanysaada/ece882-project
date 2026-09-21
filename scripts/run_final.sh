#!/usr/bin/env bash
#
# run_final.sh — Phase 4: the final before/after numbers, plus differential
# flame graphs.
#
# WHY INTERLEAVE. If you run all the baseline measurements and then all the
# optimized ones, any slow drift over the session -- CPU thermal throttling, a
# background process starting, the hypervisor scheduling the guest differently --
# lands entirely on one side and masquerades as a speedup (or hides one). So we
# alternate: base, opt, base, opt, ... using pyperf's --append so the rounds
# accumulate into one file per side. Both sides then span the same wall-clock
# window and see the same drift.
#
# Usage:
#   bash scripts/run_final.sh
#   TAG=vm ROUNDS=3 PROCESSES=40 VALUES=5 bash scripts/run_final.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ROUNDS="${ROUNDS:-3}"
PROCESSES="${PROCESSES:-20}"
VALUES="${VALUES:-3}"
TAG="${TAG:-}"
BENCHES="${BENCHES:-nbody raytrace}"
FREQ="${FREQ:-999}"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

suffix=""; [ -n "$TAG" ] && suffix="_$TAG"

[ -d .venv ] || die "no .venv"
# shellcheck disable=SC1091
. .venv/bin/activate
mkdir -p results/json results/compare results/perf results/flamegraphs

# --------------------------------------------------------------------------
# AUDIT: every timing below must come from RELEASE python3. A python3-dbg
# timing in a comparison table would invalidate the whole results section, so
# assert it rather than trusting it.
# --------------------------------------------------------------------------
say "AUDIT — interpreter used for all timings"
python3 - <<'PY'
import sys, sysconfig
f = sysconfig.get_config_var('CFLAGS') or ''
dbg = ('pydebug' in f) or ('Py_DEBUG' in f) or hasattr(sys, 'gettotalrefcount')
print(f"    executable : {sys.executable}")
print(f"    version    : {sys.version.split()[0]}")
print(f"    debug build: {'YES' if dbg else 'no (release)'}")
if dbg:
    raise SystemExit("REFUSING TO CONTINUE: this is a debug build. "
                     "Timings must come from release python3.")
PY

say "Regenerating variants and re-running the correctness gate"
python3 scripts/make_variants.py >/dev/null
python3 tests/check_equivalence.py | tail -3

# --------------------------------------------------------------------------
for bench in $BENCHES; do
  base_src="baseline/bm_${bench}/run_benchmark.py"
  opt_src="benchmarks/bm_${bench}_opt/run_benchmark.py"
  [ -f "$opt_src" ] || die "missing $opt_src"

  bjson="results/json/${bench}_final_base${suffix}.json"
  ojson="results/json/${bench}_final_opt${suffix}.json"
  rm -f "$bjson" "$ojson"

  say "$bench — interleaved measurement, $ROUNDS rounds of (base, opt)"
  for r in $(seq 1 "$ROUNDS"); do
    echo "    round $r/$ROUNDS : baseline"
    python3 "$base_src" --append "$bjson" -p "$PROCESSES" -n "$VALUES" --quiet
    echo "    round $r/$ROUNDS : optimized"
    python3 "$opt_src"  --append "$ojson" -p "$PROCESSES" -n "$VALUES" --quiet
  done

  say "$bench — final comparison"
  cmp_out="results/compare/${bench}_final${suffix}.txt"
  {
    echo "# FINAL comparison for $bench"
    echo "# $ROUNDS interleaved rounds of (baseline, optimized); -p $PROCESSES -n $VALUES"
    echo "# interpreter: $(python3 -V 2>&1)  (release build, asserted above)"
    echo
    python3 -m pyperf compare_to --table "$bjson" "$ojson" 2>&1 || true
    echo
    echo "--- baseline stats ---"
    python3 -m pyperf stats "$bjson" 2>&1 | grep -iE "Number of run|Mean|Median|std dev|Minimum|Maximum" || true
    echo
    echo "--- optimized stats ---"
    python3 -m pyperf stats "$ojson" 2>&1 | grep -iE "Number of run|Mean|Median|std dev|Minimum|Maximum" || true
  } | tee "$cmp_out"

  # ------------------------------------------------------------------------
  # Differential flame graph. Requires a baseline .folded from Phase 2 and a
  # matching optimized one, both collapsed the same way.
  # ------------------------------------------------------------------------
  say "$bench — profiling the OPTIMIZED build for the differential flame graph"
  probe="$(perf stat -e cycles true 2>&1 || true)"
  if printf '%s' "$probe" | grep -qiE "not supported|not counted|<not"; then
    EVENT="cpu-clock"
  else
    EVENT="cycles"
  fi
  DBG_PY=python3
  for cand in python3-dbg python3.10-dbg; do
    command -v "$cand" >/dev/null 2>&1 && { DBG_PY="$cand"; break; }
  done

  odata="results/perf/${bench}_opt_dbg${suffix}.data"
  ofold="results/perf/${bench}_opt_dbg${suffix}.folded"
  bfold="results/perf/${bench}_dbg${suffix}.folded"

  perf record -F "$FREQ" -g --call-graph "${UNWIND:-fp}" -e "$EVENT" -o "$odata" -- \
      "$DBG_PY" "$opt_src" --worker -l "${DBG_LOOPS:-3}" -n 1 -w 0 >/dev/null 2>&1
  perf script -i "$odata" 2>/dev/null \
    | tools/FlameGraph/stackcollapse-perf.pl > "$ofold"
  [ -s "$ofold" ] || die "$ofold is empty"

  tools/FlameGraph/flamegraph.pl --title "$bench optimized (event=$EVENT)" \
      "$ofold" > "results/flamegraphs/${bench}_opt_dbg${suffix}.svg"

  if [ -s "$bfold" ]; then
    # difffolded.pl: red = frame grew (worse), blue = frame shrank (better).
    #
    # -n NORMALISES the two profiles to a common total before differencing. That
    # matters because the optimized build is faster, so profiling the same number
    # of loops yields FEWER samples -- without -n every frame would look uniformly
    # smaller and per-frame comparison becomes meaningless. With -n the diff
    # answers the question the slide actually makes: did this frame's SHARE of
    # runtime shrink?
    #
    # It does NOT rescue mismatched sample RATES. If the two sides were recorded at
    # different -F values, re-record both; normalising 27 samples up to 3000 does
    # not create information, it just scales noise.
    tools/FlameGraph/difffolded.pl -n "$bfold" "$ofold" 2>/dev/null \
      | tools/FlameGraph/flamegraph.pl \
          --title "$bench differential: baseline -> optimized (blue = improved)" \
          > "results/flamegraphs/${bench}_diff${suffix}.svg"
    echo "    -> results/flamegraphs/${bench}_diff${suffix}.svg"
    echo "    frames that DISAPPEARED in the optimized profile:"
    # `|| echo ...` is load-bearing: when no frame disappears, grep matches nothing
    # and exits 1, which under `set -euo pipefail` killed this script AFTER the
    # comparison was written -- and, run from a driver, stopped the next benchmark.
    comm -23 <(cut -d' ' -f1 "$bfold" | sort -u) <(cut -d' ' -f1 "$ofold" | sort -u) \
      | grep -oE '[^;]+$' | sort -u | head -8 | sed 's/^/      /' \
      || echo "      (none -- no frame is absent from the optimized profile)"
  else
    echo "    no baseline .folded for $bench — run scripts/run_profile.sh first"
  fi
done

say "Phase 4 complete"
echo "  results/compare/*_final*.txt        the graded before/after numbers"
echo "  results/flamegraphs/*_diff*.svg     differential flame graphs"
echo "  results/json/*_final_*.json         raw interleaved data"
