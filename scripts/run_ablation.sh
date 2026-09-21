#!/usr/bin/env bash
#
# run_ablation.sh — Phase 3: measure every optimization variant separately.
#
# Each variant adds exactly ONE change to a declared PARENT, so the delta between
# a variant and its parent is that single optimization's contribution. That is
# what makes an ablation table honest: without it you can only say "these six
# changes together gave X%", which attributes nothing.
#
# The parent is usually the previous variant, but not always -- nbody v4 branches
# off the baseline again on purpose. benchmarks/ablation/PARENTS declares the real
# parent of each variant; this script refuses to guess.
#
# The correctness gate runs FIRST. A variant that computes something different
# is never timed.
#
# Usage:
#   bash scripts/run_ablation.sh
#   TAG=vm PROCESSES=40 VALUES=5 bash scripts/run_ablation.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROCESSES="${PROCESSES:-20}"
VALUES="${VALUES:-3}"
TAG="${TAG:-}"
BENCHES="${BENCHES:-nbody raytrace}"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

suffix=""; [ -n "$TAG" ] && suffix="_$TAG"

[ -d .venv ] || die "no .venv — run scripts/setup_env.sh"
# shellcheck disable=SC1091
. .venv/bin/activate

mkdir -p results/json results/compare benchmarks/ablation

say "Regenerating variants from the pristine baselines"
python3 scripts/make_variants.py

say "CORRECTNESS GATE (runs before any timing)"
python3 tests/check_equivalence.py || die "correctness gate failed — refusing to time"

say "Interpreter"
python3 -c "import sys, sysconfig; f=sysconfig.get_config_var('CFLAGS') or ''; \
print('   ', sys.version.split()[0], sys.executable); \
print('    debug build:', 'YES (WRONG for timing)' if 'pydebug' in f or 'Py_DEBUG' in f else 'no (release)')"

for bench in $BENCHES; do
  base_src="baseline/bm_${bench}/run_benchmark.py"
  base_json="results/json/${bench}_base${suffix}.json"

  # Baseline: reuse the Phase 1 run if it exists for this tag, else measure it.
  if [ -f "$base_json" ]; then
    say "$bench — reusing existing baseline $base_json"
  else
    say "$bench — measuring baseline"
    python3 "$base_src" -o "$base_json" -p "$PROCESSES" -n "$VALUES"
  fi

  # Each variant, in order.
  variants=$(ls benchmarks/ablation/${bench}_v*.py 2>/dev/null | sort)
  [ -n "$variants" ] || die "no variants for $bench"

  # A variant's PARENT is the file it adds exactly one change to, which is NOT
  # always the alphabetically preceding variant: nbody v4 branches off the
  # baseline again so `** (-1.5)` is held constant. Comparing v4 against v3 would
  # attribute the delta to a change neither of them made. make_variants.py
  # declares the real parent of every variant in benchmarks/ablation/PARENTS.
  parents="benchmarks/ablation/PARENTS"
  [ -f "$parents" ] || die "missing $parents — re-run scripts/make_variants.py"

  table="results/compare/${bench}_ablation${suffix}.txt"
  {
    echo "# Ablation table for $bench"
    echo "# 'vs baseline' is the total effect of this variant."
    echo "# 'vs parent'   is the contribution of THIS ONE change, measured against"
    echo "#               the variant it was derived from (declared in PARENTS --"
    echo "#               not every variant extends the one above it)."
    echo "# processes=$PROCESSES values=$VALUES interpreter=$(python3 -V 2>&1)"
    echo
  } > "$table"

  for vpath in $variants; do
    vname=$(basename "$vpath" .py)
    vjson="results/json/${vname}${suffix}.json"

    pname=$(awk -v v="$vname" '$1==v {print $2}' "$parents")
    [ -n "$pname" ] || die "$vname has no parent declared in $parents"
    if [ "$pname" = "baseline" ]; then
      pjson="$base_json"
    else
      pjson="results/json/${pname}${suffix}.json"
      [ -f "$pjson" ] || die "$vname's parent $pname has no data at $pjson"
    fi

    say "$bench — $vname (parent: $pname)"
    rm -f "$vjson"
    python3 "$vpath" -o "$vjson" -p "$PROCESSES" -n "$VALUES"

    {
      echo "================================================================"
      echo "VARIANT: $vname        (derived from: $pname)"
      echo "----------------------------------------------------------------"
      echo "vs BASELINE — total effect of this variant:"
      python3 -m pyperf compare_to "$base_json" "$vjson" 2>&1 || true
      echo
      if [ "$pname" = "baseline" ]; then
        echo "vs PARENT — same as above: this variant is derived from the baseline"
        echo "directly, so its total effect IS its own contribution."
      else
        echo "vs PARENT ($pname) — the contribution of THIS change alone:"
        python3 -m pyperf compare_to "$pjson" "$vjson" 2>&1 || true
      fi
      echo
    } >> "$table"
  done

  say "$bench — ablation table"
  cat "$table"
done

say "Phase 3 ablation complete"
echo "  results/compare/*_ablation*.txt   per-change attribution"
echo "  results/json/*_v*.json            raw pyperf data per variant"
