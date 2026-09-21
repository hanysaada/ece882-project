#!/usr/bin/env bash
#
# script_nbody.sh -- reproduce the nbody result end to end, from a fresh clone.
#
#   1. environment setup and dependency install   scripts/setup_env.sh
#   2. baseline execution + noise floor           scripts/run_baseline.sh
#   3. flame graphs and perf data                 scripts/run_profile.sh
#   4. optimized execution + comparison output    scripts/run_final.sh
#
# A thin driver: every measurement is made by the scripts in scripts/; this file
# only fixes the settings so the run matches the one report_nbody.txt cites.
#
# Target: report_nbody.txt claims 1.11x (107 ms -> 96.7 ms), from
#   results/compare/nbody_final_kvm0921.txt
#
# Run inside the course VM (Ubuntu 22.04, KVM, 2 vCPU as measured):
#   bash script_nbody.sh
#
# Takes ~15 minutes. Idempotent: every step overwrites its own outputs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

BENCH=nbody

# Tag for every output file. Defaults to "repro" so a reproduction run never
# overwrites the committed evidence the report cites (the *_kvm / *_kvm0921
# files); the fresh results land beside it. Set TAG=kvm to regenerate in place.
TAG="${TAG:-repro}"

# nbody MUST run at 60 processes x 5 values. That is the setting whose noise floor
# comes back "not significant"; at pyperf's default 20 x 3 the nbody floor was
# 1.10x, larger than the effect being measured, and every nbody claim would be void.
PROCESSES=60
VALUES=5
ROUNDS=3

# Profiling: frame-pointer unwinding, as Project1.pdf page 1 specifies (plain -g).
# The scripts now default to fp as well; it is set explicitly here so the run is
# self-documenting. dwarf leaves 99.5% of samples in [unknown] stacks against fp's
# 85.7%, weighted by sample count. 20 debug-build loops gives the nbody
# profile enough samples (~7K) to read the flame graph.
export UNWIND=fp FREQ=999
DBG_LOOPS=20

say() { printf '\n\033[1;35m######## %s ########\033[0m\n' "$*"; }

say "1/4 environment setup"
bash scripts/setup_env.sh

# Can perf record here at all? Without root or sudo, Ubuntu's default
# perf_event_paranoid=4 blocks perf entirely, and the profiling steps would die.
# Timings never use perf, so in that case skip the flame graphs, say so plainly,
# and still produce the comparison.
PERF_OK=1
_pd="/tmp/perf_ok.$$.data"
if ! command -v perf >/dev/null 2>&1 || ! perf record -q -o "$_pd" -- true >/dev/null 2>&1; then
  PERF_OK=0
fi
rm -f "$_pd"
warn() { printf '\n\033[1;33mWARNING\033[0m %s\n' "$*"; }

say "2/4 baseline + noise floor  (TAG=$TAG, -p $PROCESSES -n $VALUES)"
TAG="$TAG" BENCHES="$BENCH" PROCESSES="$PROCESSES" VALUES="$VALUES" \
  bash scripts/run_baseline.sh

say "3/4 flame graphs + perf data"
if [ "$PERF_OK" = "1" ]; then
  TAG="$TAG" BENCHES="$BENCH" DBG_LOOPS="$DBG_LOOPS" \
    bash scripts/run_profile.sh
else
  warn "perf cannot record for this user (no root/sudo) -- flame graphs SKIPPED."
  echo "    Timings below are unaffected. Re-run as root for the profiles."
fi

say "4/4 optimized run + comparison  ($ROUNDS interleaved rounds)"
if [ "$PERF_OK" = "1" ]; then
  TAG="$TAG" BENCHES="$BENCH" PROCESSES="$PROCESSES" VALUES="$VALUES" \
    ROUNDS="$ROUNDS" DBG_LOOPS="$DBG_LOOPS" \
    bash scripts/run_final.sh
else
  TAG="$TAG" BENCHES="$BENCH" PROCESSES="$PROCESSES" VALUES="$VALUES" \
    ROUNDS="$ROUNDS" DBG_LOOPS="$DBG_LOOPS" \
    bash scripts/run_final.sh \
    || { [ -s "results/compare/${BENCH}_final_${TAG}.txt" ] \
         && warn "optimized-build profile skipped (perf unavailable); the comparison is complete." \
         || exit 1; }
fi

say "RESULT"
floor="results/compare/${BENCH}_noise_floor_${TAG}.txt"
echo "noise floor ($floor):"
sed -n '/^[+|]\|hidden\|significant/p' "$floor" | sed 's/^/  /'
if ! grep -q "not significant" "$floor"; then
  printf '\n\033[1;33mWARNING\033[0m the noise floor of THIS run is significant: two runs of\n'
  echo "  identical code differed measurably, so this session was too noisy to trust."
  echo "  Quiet the machine (close other programs, stay on AC power) and re-run."
fi
echo
echo "this run   (results/compare/${BENCH}_final_${TAG}.txt):"
grep -E "^\| ${BENCH}" "results/compare/${BENCH}_final_${TAG}.txt" | sed 's/^/  /'
echo "report cites (results/compare/nbody_final_kvm0921.txt):"
grep -E "^\| ${BENCH}" results/compare/nbody_final_kvm0921.txt 2>/dev/null | sed 's/^/  /' \
  || echo "  (file not present in this checkout)"
echo
if [ "$PERF_OK" = "1" ]; then
  echo "flame graphs: results/flamegraphs/${BENCH}_*_${TAG}.svg"
else
  echo "flame graphs: SKIPPED (perf unavailable to this user) -- re-run as root"
fi
