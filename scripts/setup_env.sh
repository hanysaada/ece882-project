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
# Privilege. Root needs no sudo. Otherwise use sudo only if it can actually be
# used here: without a password (sudo -n), or with one when there is a terminal
# to type it into. A grader without sudo must get a clear warning and a script
# that carries on, not a dead one -- apt and the perf knobs are the only steps
# that need privilege, the course image already ships every package below, and
# no TIMING in this project depends on either.
if [ "$(id -u)" = "0" ]; then
  SUDO=""; HAVE_PRIV=1
elif command -v sudo >/dev/null 2>&1 && { sudo -n true 2>/dev/null || [ -t 0 ]; }; then
  SUDO="sudo"; HAVE_PRIV=1
else
  SUDO=""; HAVE_PRIV=0
  printf '\n\033[1;33mWARNING\033[0m no root and no usable sudo.\n'
  echo "    Skipping apt installs and the perf kernel knobs. Required tools are still"
  echo "    checked below; on the course image they are all preinstalled. Timings are"
  echo "    unaffected; profiles may be degraded if perf is throttled (checked below)."
fi

if command -v apt-get >/dev/null 2>&1 && [ "$HAVE_PRIV" = "1" ]; then
  say "Installing system packages via apt"
  $SUDO apt-get update -y
  $SUDO apt-get install -y \
      build-essential git \
      python3 python3-dbg python3-pip python3-venv \
      linux-tools-common linux-tools-generic "linux-tools-$(uname -r)" \
      graphviz iverilog gtkwave
  # verilator is optional (heavier); try but don't fail the whole script
  $SUDO apt-get install -y verilator || echo "    (verilator not installed — iverilog is enough)"
elif command -v apt-get >/dev/null 2>&1; then
  echo "    apt available but no privilege -- package install SKIPPED (see warning above)."
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
    $SUDO sysctl -w kernel.perf_event_paranoid=-1 || echo "    could not set (need sudo)"
  fi
  $SUDO sysctl -w kernel.kptr_restrict=0 >/dev/null 2>&1 || echo "    kptr_restrict: could not set"

  # DISABLE THE DYNAMIC SAMPLE-RATE THROTTLE. This cost us two full days, twice.
  #
  # The kernel watches what fraction of CPU perf's sampling interrupt consumes and,
  # if it exceeds perf_cpu_time_max_percent (default 25), silently RATCHETS
  # perf_event_max_sample_rate down -- repeatedly, and it does not recover. Under a
  # VM the interrupt looks expensive, so the rate collapses toward 1 Hz. -F 999 is
  # then ignored and you get single-digit sample counts from a multi-second run.
  #
  # Reading the ceiling at setup time does NOT protect you: it read a healthy
  # 100000 here and was ratcheted down later, during the profiling runs themselves.
  # Setting the percent to 0 turns the mechanism off entirely, which is what we
  # want on a machine whose only job is profiling.
  #
  # THE ORDER BELOW IS LOAD-BEARING. perf_proc_update_handler() in
  # kernel/events/core.c rejects any write to the sample rate while the percent is
  # 0 or 100:
  #
  #     if (write && (perf_cpu == 100 || perf_cpu == 0))
  #             return -EINVAL;
  #
  # So percent must be NON-ZERO to raise the rate, and only then may it go to 0.
  # Setting percent=0 first leaves the rate read-only at whatever value the kernel
  # had already ratcheted it down to -- which is exactly the state we are trying to
  # escape, silently unfixed. Writing 0 afterwards only clears
  # perf_sample_allowed_ns and returns, so it does not clobber the rate.
  $SUDO sysctl -w kernel.perf_cpu_time_max_percent=25 >/dev/null 2>&1 \
    || echo "    perf_cpu_time_max_percent: could not set (need sudo)"
  $SUDO sysctl -w kernel.perf_event_max_sample_rate=5000 >/dev/null 2>&1 \
    || echo "    perf_event_max_sample_rate: could not set"
  $SUDO sysctl -w kernel.perf_cpu_time_max_percent=0 >/dev/null 2>&1 \
    || echo "    perf_cpu_time_max_percent: could not disable throttle"
  echo "    throttle: perf_cpu_time_max_percent=$(cat /proc/sys/kernel/perf_cpu_time_max_percent 2>/dev/null)" \
       "max_sample_rate=$(cat /proc/sys/kernel/perf_event_max_sample_rate 2>/dev/null)"

  # Which event can we sample? NOTE: perf stat exits 0 even when an event prints
  # "<not supported>", so the exit code is NOT a usable probe -- parse the output.
  # run_profile.sh and run_final.sh repeat this detection at measurement time;
  # this report is so you know the answer before you start.
  # `if probe=$(...)`, not a bare assignment: for a non-root user under Ubuntu's
  # default perf_event_paranoid=4, perf refuses to run at all and exits 255, and
  # under `set -e` a failing assignment killed this script right here.
  if ! probe=$(perf stat -e cycles true 2>&1); then
    printf '\n\033[1;33mWARNING\033[0m perf cannot run for this user (perf_event_paranoid=%s).\n' \
      "$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo '?')"
    echo "    perf says: $(printf '%s' "$probe" | head -1)"
    echo "    Flame graphs and perf reports need root or sudo. Timings do not."
  elif printf '%s' "$probe" | grep -qiE "not supported|not counted|<not"; then
    echo "    hardware 'cycles' NOT available -> profiles will use software 'cpu-clock'."
    echo "    Add -cpu host to the QEMU command line to expose the PMU."
    echo "    You must SAY cpu-clock when presenting: it is elapsed CPU time, not cycles."
  else
    echo "    hardware 'cycles' available -> the guest PMU is exposed."
  fi
  echo "    Record this in results/ENVIRONMENT.md."

  # HARD ASSERTION: actually record a profile and count the samples.
  #
  # Everything above only inspects settings. Three times now a tool has exited 0
  # while doing nothing useful -- perf stat printing "<not supported>", a pipe whose
  # first stage emitted nothing leaving a 0-byte .folded, and perf record
  # "succeeding" with 8 samples. So the only trustworthy check is to take a real
  # sample set and look at how big it is.
  #
  # 1 second at -F 999 should yield roughly 999 samples. Anything under 200 means
  # the rate is being clamped, and every profile taken afterwards is worthless.
  # Fail here, loudly, rather than discovering it in a flame graph.
  say "Asserting perf can actually sample (1 s at -F 999)"
  _pd=$(mktemp -u /tmp/perfprobe.XXXXXX.data)
  perf record -F 999 -g -o "$_pd" -- \
      python3 -c "x=0.0
for i in range(30000000): x+=i*0.5" >/dev/null 2>&1 || true
  # `|| true`, not `|| echo 0`: grep -c already prints 0 when nothing matches but
  # ALSO exits 1, so `|| echo 0` appended a second line ("0\n0"). The numeric test
  # below then errored, the `if` read the error as false, and the assertion
  # PASSED on exactly the zero-sample case it exists to catch.
  _n=$(perf script -i "$_pd" 2>/dev/null | grep -c '^[a-zA-Z]' || true)
  _n=${_n:-0}
  rm -f "$_pd"
  echo "    samples collected: $_n"
  if [ "$_n" -lt 200 ]; then
    _msg="perf collected only $_n samples where ~1000 was expected. The sample rate is
     being throttled, so every profile from this machine would be worthless.
     Check:  sysctl kernel.perf_cpu_time_max_percent kernel.perf_event_max_sample_rate
     Both must be settable; the first must be 0."
    if [ "$HAVE_PRIV" = "1" ]; then
      die "$_msg Re-run this script with sudo working."
    fi
    # Without privilege the throttle cannot be lifted, so dying fixes nothing.
    # Timings do not use perf, so carry on -- but say so unmissably.
    printf '\n\033[1;33mWARNING\033[0m %s\n' "$_msg"
    echo "    No privilege to fix it here. TIMING RESULTS ARE UNAFFECTED; treat the"
    echo "    flame graphs and perf reports from this run as unreliable."
  else
    ok "perf sampling verified at $_n samples"
  fi
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
