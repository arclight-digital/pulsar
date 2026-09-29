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
# From 7.2 the implicit-argument kfuncs come in pairs: the public name
# without aux, which is what a BPF program links against, and a
# scx_bpf_*_impl twin that keeps aux by design, which the kernel calls behind
# it. Only the public names are judged; flagging the _impl twins kept a
# correctly built 7.2.7 (47 of them) marked broken and the scheduler off.
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

# Named explicitly so a missing interpreter is "cannot determine" with a
# reason, not a bare 127 from set -e that the caller has to decode.
command -v python3 >/dev/null || die "python3 is required to read BTF"

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

# A malformed kfunc is a PUBLIC one whose final parameter is the implicit
# prog aux pointer (an _impl twin keeps it by design: see the top). Matching
# on the parameter NAME is what upstream's own diagnostic does, and the name
# is stable across every affected kernel.
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

funcs = {}
for ln in lines:
    m = re.match(r"\[\d+\] FUNC '(scx_bpf_\w+)' type_id=(\d+)", ln)
    if m:
        funcs[m.group(1)] = m.group(2)

clean, malformed = [], []
for name, tid in funcs.items():
    # an _impl twin keeps aux by design, but only beside its public name;
    # alone, a program has nothing clean to link against
    if name.endswith("_impl") and name[:-5] in funcs:
        continue
    if tid not in protos:
        # a kfunc with no arguments still has a proto (vlen=0): a missing one
        # is a dump this cannot read, and that is never "clean"
        print(f"check-scx-btf: {name} has no FUNC_PROTO [{tid}] in the dump", file=sys.stderr)
        sys.exit(2)
    params = protos[tid]
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
