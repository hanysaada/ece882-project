#!/usr/bin/env bash
#
# run_baseline.sh — Phase 1: establish trustworthy baselines AND the noise floor.
#
# Runs each benchmark TWICE with identical code. The difference between those two
# runs is pure measurement noise: it is the smallest effect we could ever claim
# to have detected. Any "improvement" smaller than this number is not a result.
#
# Uses RELEASE python3 only. Never python3-dbg (that build is for profiling).
#
# Usage:
#   bash scripts/run_baseline.sh              # default: -p 20 -n 3
#   PROCESSES=40 VALUES=5 bash scripts/run_baseline.sh
#   TAG=vm bash scripts/run_baseline.sh       # label the output files
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROCESSES="${PROCESSES:-20}"
VALUES="${VALUES:-3}"
TAG="${TAG:-}"                      # e.g. TAG=vm  -> nbody_base_vm.json
BENCHES="${BENCHES:-nbody raytrace}"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[ -d .venv ] || { echo "no .venv — run scripts/setup_env.sh first"; exit 1; }
# shellcheck disable=SC1091
. .venv/bin/activate

mkdir -p results/json results/compare

# Record which interpreter produced these numbers. This matters: a python3-dbg
# timing must never end up in a comparison table.
say "Interpreter used for ALL timings below"
python3 -c "import sys; print('   ', sys.executable); print('    version:', sys.version.split()[0])"
python3 -c "import sysconfig; f=sysconfig.get_config_var('CFLAGS') or ''; \
print('    debug build:', 'YES (WRONG for timing!)' if '--with-pydebug' in f or 'Py_DEBUG' in f else 'no (release, correct)')"

# pyperf can try to reduce system jitter. In a guest it often cannot set the CPU
# governor; we record whether it worked rather than pretending it did.
say "Attempting 'pyperf system tune' (records success/failure, does not abort)"
if python3 -m pyperf system tune 2>&1 | tail -5; then
  echo "    tune: reported success (see output above)"
else
  echo "    tune: FAILED or partial — expected inside a VM. Noted, continuing."
fi

suffix=""
[ -n "$TAG" ] && suffix="_$TAG"

for bench in $BENCHES; do
  src="baseline/bm_${bench}/run_benchmark.py"
  [ -f "$src" ] || { echo "missing $src"; exit 1; }

  b1="results/json/${bench}_base${suffix}.json"
  b2="results/json/${bench}_base2${suffix}.json"

  say "$bench — run 1 of 2 (baseline)"
  rm -f "$b1"
  python3 "$src" -o "$b1" -p "$PROCESSES" -n "$VALUES"

  say "$bench — run 2 of 2 (IDENTICAL code — this measures noise)"
  rm -f "$b2"
  python3 "$src" -o "$b2" -p "$PROCESSES" -n "$VALUES"

  say "$bench — NOISE FLOOR (base vs base2: same code, so any delta is noise)"
  noise="results/compare/${bench}_noise_floor${suffix}.txt"
  {
    echo "# Noise floor for $bench"
    echo "# Two runs of IDENTICAL baseline code. Any difference is measurement"
    echo "# noise, not a real effect. An optimization must beat this to count."
    echo "# processes=$PROCESSES values=$VALUES  interpreter=$(python3 -V 2>&1)"
    echo
    python3 -m pyperf compare_to --table "$b1" "$b2"
  } | tee "$noise"

  say "$bench — baseline statistics"
  stats="results/compare/${bench}_base_stats${suffix}.txt"
  python3 -m pyperf stats "$b1" | tee "$stats" | grep -iE \
    "Total duration|Number of run|Mean|Median|std dev|Minimum|Maximum|percentile: 5|percentile: 95" || true
done

say "Phase 1 measurement complete"
echo "  results/json/*_base*.json           raw pyperf data"
echo "  results/compare/*_noise_floor*.txt  the number that gates every claim"
echo "  results/compare/*_base_stats*.txt   mean/median/stdev/min/max"
