#!/usr/bin/env bash
#
# run_profile.sh — Phase 2: profile both benchmarks, two ways, and build flame graphs.
#
# We need TWO views because they answer different questions:
#
#   A) perf + python3-dbg  -> what the INTERPRETER is doing (allocator pressure,
#      page faults, eval-loop overhead, libm calls). Needs the debug build so
#      perf can resolve CPython's internal C symbols.
#
#   B) py-spy + python3    -> which of OUR PYTHON functions and lines are hot.
#      Needed because in CPython every Python-level call runs inside the same C
#      function (_PyEval_EvalFrameDefault), so a pure perf flame graph of Python
#      code is one giant useless frame. CPython 3.12 added a perf trampoline
#      (-X perf) that fixes this, but jammy ships 3.10, so py-spy fills the gap.
#
# NOTE ON TIMING: nothing here produces a timing for a report. python3-dbg is
# several times slower than release python3 and its profile SHAPE is distorted.
# These are profiles, not measurements. Timings come from run_baseline.sh.
#
# Usage:
#   bash scripts/run_profile.sh                  # both benchmarks
#   BENCHES=raytrace bash scripts/run_profile.sh
#   TAG=vm bash scripts/run_profile.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BENCHES="${BENCHES:-nbody raytrace}"
TAG="${TAG:-}"
FREQ="${FREQ:-999}"          # 999 Hz, not 1000: see docs/02_profiling.md
DBG_LOOPS="${DBG_LOOPS:-3}"  # loops for the perf run (debug build is slow)
SPY_LOOPS="${SPY_LOOPS:-20}" # loops for the py-spy run (release build)

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '    \033[1;33mWARN\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

suffix=""; [ -n "$TAG" ] && suffix="_$TAG"

mkdir -p results/perf results/flamegraphs

[ -d .venv ] || die "no .venv — run scripts/setup_env.sh first"
# shellcheck disable=SC1091
. .venv/bin/activate

# --------------------------------------------------------------------------
# Preconditions. Fail early and clearly rather than producing empty files —
# that is exactly how we ended up with a 0-byte .folded once already.
# --------------------------------------------------------------------------
say "Checking prerequisites"
command -v perf >/dev/null 2>&1 || die "perf not installed (scripts/setup_env.sh)"
[ -x tools/FlameGraph/stackcollapse-perf.pl ] \
  || die "tools/FlameGraph missing. Run scripts/setup_env.sh (it clones it)."
[ -x tools/FlameGraph/flamegraph.pl ] || die "tools/FlameGraph/flamegraph.pl missing"
command -v py-spy >/dev/null 2>&1 || die "py-spy not installed (scripts/setup_env.sh)"

# Which python has debug symbols? Prefer python3-dbg; fall back with a warning.
DBG_PY=""
for cand in python3-dbg python3.10-dbg python3-debug; do
  command -v "$cand" >/dev/null 2>&1 && { DBG_PY="$cand"; break; }
done
if [ -z "$DBG_PY" ]; then
  warn "python3-dbg not found. Falling back to release python3 for the perf run."
  warn "You will see fewer resolved CPython symbols. Install python3-dbg in the VM."
  DBG_PY="python3"
fi
echo "    perf run interpreter : $DBG_PY ($($DBG_PY -V 2>&1))"
echo "    py-spy interpreter   : python3 ($(python3 -V 2>&1))"

# Which perf event can we actually sample? Parse the OUTPUT, not the exit code:
# perf stat exits 0 even when an event is "<not supported>".
say "Selecting perf event"
probe="$(perf stat -e cycles true 2>&1 || true)"
if printf '%s' "$probe" | grep -qiE "not supported|not counted|<not"; then
  EVENT="cpu-clock"
  echo "    hardware PMU NOT available -> using software event 'cpu-clock'"
  echo "    (add -cpu host to the QEMU command line to expose real cycles)"
else
  EVENT="cycles"
  echo "    hardware PMU available -> using 'cycles'"
fi
echo "$EVENT" > results/perf/PERF_EVENT_USED${suffix}.txt

# Call-graph unwinding: dwarf works without frame pointers (Ubuntu 22.04 did not
# build with them by default), at the cost of much larger samples.
UNWIND="${UNWIND:-dwarf}"
echo "    unwinding method     : $UNWIND"

# --------------------------------------------------------------------------
for bench in $BENCHES; do
  src="baseline/bm_${bench}/run_benchmark.py"
  [ -f "$src" ] || die "missing $src"

  data="results/perf/${bench}_dbg${suffix}.data"
  report="results/perf/report_${bench}_dbg${suffix}.txt"
  folded="results/perf/${bench}_dbg${suffix}.folded"
  svg="results/flamegraphs/${bench}_dbg${suffix}.svg"
  spysvg="results/flamegraphs/${bench}_pyspy${suffix}.svg"
  spyfold="results/perf/${bench}_pyspy${suffix}.folded"

  # ---------------- A) perf, C/interpreter view --------------------------
  say "$bench — perf record (event=$EVENT, -F $FREQ, --call-graph $UNWIND)"
  rm -f "$data"
  # --worker -l N -n 1 -w 0 runs the benchmark body directly, no subprocesses:
  # perf then samples the actual work rather than pyperf's process management.
  perf record -F "$FREQ" -g --call-graph "$UNWIND" -e "$EVENT" -o "$data" -- \
      "$DBG_PY" "$src" --worker -l "$DBG_LOOPS" -n 1 -w 0
  [ -s "$data" ] || die "$data is empty — perf recorded nothing"

  say "$bench — perf report"
  # Full report is huge (millions of lines with dwarf). Keep a trimmed version
  # for the repo; --percent-limit drops noise below 0.5%.
  perf report -i "$data" --stdio --percent-limit 0.5 > "$report" 2>/dev/null
  [ -s "$report" ] || die "$report is empty"
  echo "    $(wc -l < "$report") lines -> $report"

  say "$bench — collapse stacks and render flame graph"
  perf script -i "$data" 2>/dev/null \
    | tools/FlameGraph/stackcollapse-perf.pl > "$folded"
  # THE CHECK THAT WAS MISSING BEFORE: a 0-byte .folded means the pipeline
  # silently failed and every downstream flame graph would be empty.
  [ -s "$folded" ] || die "$folded is EMPTY. perf script produced no output. \
Check that $data exists and that perf can read its build-ids."
  echo "    $(wc -l < "$folded") collapsed stacks -> $folded"

  tools/FlameGraph/flamegraph.pl \
      --title "$bench baseline ($DBG_PY, event=$EVENT)" \
      "$folded" > "$svg"
  [ -s "$svg" ] || die "$svg is empty"
  echo "    -> $svg"

  # ---------------- B) py-spy, Python view ------------------------------
  say "$bench — py-spy (Python-level names and line numbers)"
  py-spy record --rate "$FREQ" --format flamegraph -o "$spysvg" -- \
      python3 "$src" --worker -l "$SPY_LOOPS" -n 1 -w 0 || true
  [ -s "$spysvg" ] || die "$spysvg is empty — py-spy failed"
  echo "    -> $spysvg"

  py-spy record --rate "$FREQ" --format raw -o "$spyfold" -- \
      python3 "$src" --worker -l "$SPY_LOOPS" -n 1 -w 0 || true
  [ -s "$spyfold" ] || die "$spyfold is empty — py-spy raw failed"
  echo "    -> $spyfold"

  # ---------------- Top hotspots, both views ----------------------------
  say "$bench — TOP HOTSPOTS"
  echo "  --- perf, by SELF time (where cycles actually burn) ---"
  grep -vE '^\s*$|^#' "$report" | grep -E '^\s+[0-9]+\.[0-9]+%' | head -12 || true
  echo
  echo "  --- py-spy, hottest Python lines (aggregated by LEAF frame) ---"
  # A py-spy raw line is:  frame1;frame2;...;leafframe <count>
  # We want the LEAF (the innermost frame = where execution actually was),
  # summed across every stack that ends there. Printing the start of the stack
  # only shows pyperf's boilerplate, which tells us nothing.
  awk '
    {
      n = $NF                      # trailing sample count
      $NF = ""                     # strip it
      stack = $0
      sub(/[ \t]+$/, "", stack)
      k = split(stack, f, ";")
      leaf = f[k]                  # innermost frame
      total[leaf] += n
      sum += n
    }
    END {
      for (l in total) printf "%8d  %5.1f%%  %s\n", total[l], 100*total[l]/sum, l
    }
  ' "$spyfold" | sort -rn | head -10 || true
done

say "Phase 2 profiling complete"
echo "  results/perf/report_*_dbg*.txt      trimmed perf reports (Self/Children)"
echo "  results/perf/*_dbg*.folded          collapsed stacks (flame graph input)"
echo "  results/perf/*_pyspy*.folded        Python-level stacks"
echo "  results/flamegraphs/*_dbg*.svg      C/interpreter flame graphs"
echo "  results/flamegraphs/*_pyspy*.svg    Python-level flame graphs"
echo "  results/perf/PERF_EVENT_USED*.txt   which event produced the samples"
echo
echo "  Reminder: these are PROFILES, not timings. No number here belongs in a"
echo "  performance comparison — python3-dbg is slow and differently shaped."
