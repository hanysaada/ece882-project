# ENVIRONMENT.md

Records the exact environment so every measurement is reproducible and
defensible. **Two columns:** the HOST rehearsal box (where we develop) and the
COURSE VM (where the graded numbers must be taken). Fill the VM column by
running the same commands inside the VM.

> RULE: every timing number in a report must come from the VM column, using
> RELEASE `python3` (never `python3-dbg`).

| Item | Host (rehearsal — NOT gradeable) | Course VM (fill in) |
|---|---|---|
| Kernel (`uname -r`) | 5.10.265-272.1078.amzn2int.x86_64 | _(expect 5.x jammy generic)_ |
| CPU (`/proc/cpuinfo`) | Intel Xeon Platinum 8275CL @ 3.00GHz | _(as the guest sees it)_ |
| Cores (`nproc`) | 16 | _(VM -smp value)_ |
| OS | Amazon Linux 2 (host) | Ubuntu 22.04 "jammy" |
| Python release (`python3 -V`) | 3.12.13 | _(expect 3.10.x)_ |
| Python debug (`python3-dbg -V`) | not installed on host | _(expect 3.10.x)_ |
| Python CFLAGS | -O3 -DNDEBUG -g -fPIC ... | _(fill from VM)_ |
| perf (`perf --version`) | 5.10.265 (amzn2) | _(linux-tools-$(uname -r))_ |
| pyperformance | 1.14.0 | _(fill)_ |
| pyperf | 2.10.0 | _(fill)_ |
| py-spy | 0.4.2 | _(fill)_ |
| **perf sampling event** | **cpu-clock (software — no HW PMU here)** | _(cycles if `-cpu host`, else cpu-clock)_ |
| perf_event_paranoid | set to -1 by setup_env.sh | _(set to -1 or 1)_ |

## QEMU command line actually used (fill from the VM launch)
```
# example — replace with the real one you use:
qemu-system-x86_64 \
  -m 4G -smp 4 -enable-kvm -cpu host \
  -drive file=jammy-server-cloudimg-amd64-disk-kvm.img,format=qcow2,if=virtio \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
  -nographic
```
`-cpu host` is what may expose the hardware PMU (real `cycles`). Without it,
`perf` falls back to the software `cpu-clock` event — record which one you got.

## How each value was collected
```bash
uname -r
grep -m1 'model name' /proc/cpuinfo
nproc
python3 --version ; python3-dbg --version
python3 -c "import sysconfig; print(sysconfig.get_config_var('CFLAGS'))"
perf --version
python3 -c "import pyperf, pyperformance; print(pyperf.__version__, pyperformance.__version__)"
py-spy --version
bash scripts/setup_env.sh         # reports the sampling event
```
