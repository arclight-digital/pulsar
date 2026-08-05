#!/usr/bin/bash
# Can the kernel we are shipping actually load a sched_ext scheduler?
#
# Fedora's 7.1.5 and 7.1.6 kernels publish scx kfuncs with the implicit
# 'struct bpf_prog_aux *' argument still present in their public BTF
# prototypes:
#
#     scx_bpf_cpu_curr(cpu, aux)          should be (cpu)
#     scx_bpf_get_idle_smtmask(aux)       should take nothing
#
# Every BPF program that calls one fails to load with 'func_proto
# incompatible with vmlinux', so NO scheduler can attach -- not bpfland, not
# lavd. It is a kernel packaging defect, nothing a scheduler flag can work
# around, and it is invisible until a machine boots and the unit dies.
#
# So the build asks the question instead of the user's laptop. A clean kernel
# gets /usr/lib/pulsar/scx-supported and scx.service starts; a broken one does
# not, and systemd skips the unit rather than failing it three times. The day
# Fedora ships a fixed kernel the marker appears on its own and the scheduler
# comes back with no change here.
#
# Usage:
#   check-scx-btf.sh                 inspect the RUNNING kernel
#   check-scx-btf.sh --image         inspect the kernel in this image/rootfs
#   check-scx-btf.sh --dump FILE     parse an existing `bpftool btf dump` file
#
# Exit: 0 clean, 1 malformed, 2 could not determine.
#
# "Could not determine" is deliberately NOT treated as clean. A gate that
# silently degrades to a guess is how you ship an image whose scheduler state
# nobody can explain.
set -euo pipefail

MODE=running
DUMP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --image)  MODE=image ;;
        --dump)   MODE=dump; DUMP="${2:-}"; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

die() { echo "check-scx-btf: $*" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

case "$MODE" in
    dump)
        [ -r "$DUMP" ] || die "cannot read dump file: ${DUMP}"
        cp "$DUMP" "${work}/dump.txt"
        ;;
    running)
        [ -r /sys/kernel/btf/vmlinux ] || die "/sys/kernel/btf/vmlinux is not readable"
        command -v bpftool >/dev/null || die "bpftool is not installed"
        bpftool btf dump file /sys/kernel/btf/vmlinux format raw > "${work}/dump.txt" \
            || die "bpftool could not dump the running kernel's BTF"
        ;;
    image)
        command -v bpftool >/dev/null || die "bpftool is not installed"
        vmlinuz=$(find /usr/lib/modules -name vmlinuz -type f 2>/dev/null | sort | head -1)
        [ -n "$vmlinuz" ] || die "no /usr/lib/modules/*/vmlinuz found"
        echo "kernel image: ${vmlinuz}"
        # vmlinuz is a compressed bzImage; BTF lives in the ELF inside it.
        python3 - "$vmlinuz" "${work}/vmlinux" <<'PY' || die "could not extract vmlinux from ${vmlinuz}"
import subprocess, sys
src, dst = sys.argv[1], sys.argv[2]
blob = open(src, "rb").read()
for magic, tool in ((b"\x28\xb5\x2f\xfd", ["zstd", "-d", "-c"]),
                    (b"\x1f\x8b\x08",     ["gzip", "-dc"]),
                    (b"\x02\x21\x4c\x18", ["lz4", "-d"]),
                    (b"\x5d\x00\x00",     ["xz", "-dc"])):
    i = blob.find(magic)
    while i != -1:
        try:
            out = subprocess.run(tool, input=blob[i:], capture_output=True).stdout
        except FileNotFoundError:
            break
        if len(out) > 10_000_000 and out[:4] == b"\x7fELF":
            open(dst, "wb").write(out)
            sys.exit(0)
        i = blob.find(magic, i + 1)
sys.exit(1)
PY
        bpftool btf dump file "${work}/vmlinux" format raw > "${work}/dump.txt" \
            || die "no BTF section in the extracted vmlinux"
        ;;
esac

[ -s "${work}/dump.txt" ] || die "BTF dump is empty"

# A malformed kfunc is one whose final parameter is the implicit prog aux
# pointer. Matching on the parameter NAME is what upstream's own diagnostic
# does, and the name is stable across every affected kernel.
python3 - "${work}/dump.txt" <<'PY'
import re, sys

lines = open(sys.argv[1]).read().splitlines()

protos, cur = {}, None
for ln in lines:
    m = re.match(r"\[(\d+)\] FUNC_PROTO", ln)
    if m:
        cur = m.group(1)
        protos[cur] = []
    elif cur is not None and ln.startswith("\t'"):
        protos[cur].append(re.match(r"\t'([^']*)'", ln).group(1))
    elif not ln.startswith("\t"):
        cur = None

clean, malformed = [], []
for ln in lines:
    m = re.match(r"\[\d+\] FUNC '(scx_bpf_\w+)' type_id=(\d+)", ln)
    if not m:
        continue
    name, tid = m.groups()
    params = protos.get(tid, [])
    (malformed if params and params[-1] == "aux" else clean).append((name, params))

if not clean and not malformed:
    print("no scx_bpf_* kfuncs in this kernel's BTF: sched_ext is not available")
    sys.exit(1)

for name, params in malformed[:5]:
    print(f"  MALFORMED  {name}({', '.join(params)})")
if len(malformed) > 5:
    print(f"  ... and {len(malformed) - 5} more")

print(f"scx kfuncs: {len(clean)} clean, {len(malformed)} carrying the implicit 'aux' argument")
sys.exit(1 if malformed else 0)
PY
