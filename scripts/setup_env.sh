#!/usr/bin/env bash
#
# setup_env.sh — install and VERIFY every tool the project needs.
#
# Target: the course VM (Ubuntu 22.04 "jammy"). Run it INSIDE the VM.
# It is idempotent: safe to re-run. It fails loudly on the first missing tool
# instead of silently continuing, so you never discover a gap three phases later.
#
# Usage:   bash scripts/setup_env.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mOK\033[0m   %s\n' "$*"; }
die()  { printf '\n\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

need() {  # need <command> <friendly-name-for-error>
  command -v "$1" >/dev/null 2>&1 || die "missing '$1' ($2) — install step did not work"
  ok "$1 -> $(command -v "$1")"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 1. system packages (apt) — only on Debian/Ubuntu (the VM)
# ---------------------------------------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
  say "Installing system packages via apt (needs sudo)"
  sudo apt-get update -y
  sudo apt-get install -y \
      build-essential git \
      python3 python3-dbg python3-pip python3-venv \
      linux-tools-common linux-tools-generic "linux-tools-$(uname -r)" \
      graphviz iverilog gtkwave
  # verilator is optional (heavier); try but don't fail the whole script
  sudo apt-get install -y verilator || echo "    (verilator not installed — iverilog is enough)"
else
  echo "    apt-get not found — not the Ubuntu VM."
  echo "    System packages (python3-dbg, perf, iverilog, graphviz) must be"
  echo "    installed by hand on this OS. Continuing with the Python parts only."
fi

# ---------------------------------------------------------------------------
# 2. verify the system tools we depend on
# ---------------------------------------------------------------------------
say "Verifying system tools"
need python3 "CPython release build"
need git     "version control"
# python3-dbg and perf may be absent off-VM; warn instead of dying there.
if command -v apt-get >/dev/null 2>&1; then
  need python3-dbg "CPython debug build (profiling symbols)"
  need perf        "sampling profiler"
  need iverilog    "Verilog simulator"
  need dot         "graphviz (block diagrams)"
else
  command -v python3-dbg >/dev/null 2>&1 && ok "python3-dbg present" || echo "    (python3-dbg absent — expected off-VM)"
  command -v perf        >/dev/null 2>&1 && ok "perf present"        || echo "    (perf absent — expected off-VM)"
  command -v iverilog    >/dev/null 2>&1 && ok "iverilog present"    || echo "    (iverilog absent — install in VM)"
fi

# ---------------------------------------------------------------------------
# 3. python virtual environment + pip packages
# ---------------------------------------------------------------------------
say "Creating .venv and installing Python packages"
[ -d .venv ] || python3 -m venv .venv
# shellcheck disable=SC1091
. .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet pyperformance pyperf py-spy
need pyperformance "benchmark suite"
python3 -c "import pyperf;  print('    OK   pyperf', pyperf.__version__)"
python3 -c "import pyperformance; print('    OK   pyperformance', pyperformance.__version__)"
need py-spy "python-level sampling profiler"

# ---------------------------------------------------------------------------
# 4. perf kernel knobs. These are environment setup, not a measurement step.
#     perf_event_paranoid gates who may collect what: 2 (a common default) blocks
#     kernel-level sampling, so call graphs through the kernel come back
#     truncated. <=1 is needed for useful -g. kptr_restrict lets perf turn kernel
#     addresses into symbol names instead of hex.
# ---------------------------------------------------------------------------
if command -v perf >/dev/null 2>&1; then
  say "Setting perf kernel knobs (needs sudo)"
  cur=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "?")
  echo "    perf_event_paranoid is $cur"
  if [ "$cur" != "-1" ] && [ "$cur" != "0" ] && [ "$cur" != "1" ]; then
    sudo sysctl -w kernel.perf_event_paranoid=-1 || echo "    could not set (need sudo)"
  fi
  sudo sysctl -w kernel.kptr_restrict=0 >/dev/null 2>&1 || echo "    kptr_restrict: could not set"

  # Which event can we sample? NOTE: perf stat exits 0 even when an event prints
  # "<not supported>", so the exit code is NOT a usable probe -- parse the output.
  # run_profile.sh and run_final.sh repeat this detection at measurement time;
  # this report is so you know the answer before you start.
  probe=$(perf stat -e cycles true 2>&1)
  if printf '%s' "$probe" | grep -qiE "not supported|not counted|<not"; then
    echo "    hardware 'cycles' NOT available -> profiles will use software 'cpu-clock'."
    echo "    Add -cpu host to the QEMU command line to expose the PMU."
    echo "    You must SAY cpu-clock when presenting: it is elapsed CPU time, not cycles."
  else
    echo "    hardware 'cycles' available -> the guest PMU is exposed."
  fi
  echo "    Record this in results/ENVIRONMENT.md."
fi

# ---------------------------------------------------------------------------
# 5. FlameGraph scripts
# ---------------------------------------------------------------------------
say "Fetching FlameGraph scripts"
if [ ! -d tools/FlameGraph ]; then
  git clone --depth 1 https://github.com/brendangregg/FlameGraph tools/FlameGraph
fi
[ -f tools/FlameGraph/flamegraph.pl ] || die "FlameGraph clone incomplete"
ok "tools/FlameGraph"

say "Environment setup complete."
echo "Next: bash scripts/run_baseline.sh  (Phase 1)"
