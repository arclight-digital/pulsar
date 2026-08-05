#!/usr/bin/bash
# WANTED (warn-only), deliberately NOT required.
#
# This asserts the one thing scx.service itself cannot: that a scheduler
# ACTUALLY ATTACHED. During the incident that motivated the scx.service
# hardening, `systemctl is-active scx.service` reported active for over two
# minutes at a stretch while /sys/kernel/sched_ext/state read "disabled" and
# the machine ran stock EEVDF the whole time. Unit state is not scheduler
# state, and this file is where that distinction is enforced.
#
# It lives in wanted.d, not required.d, on purpose: a scheduler that fails to
# attach is a performance regression, not a broken boot. The kernel falls
# back to EEVDF and the desktop is entirely usable. Rolling a whole
# deployment back over it would be the worse outcome -- and a crash-looping
# scheduler is exactly the thing that would do it on every boot, including
# boots of a deployment that is otherwise perfectly healthy.
set -euo pipefail

STATE_FILE=/sys/kernel/sched_ext/state

if [ ! -e "$STATE_FILE" ]; then
    echo "kernel does not support sched_ext; nothing to check"
    exit 0
fi

state=$(cat "$STATE_FILE")
if [ "$state" != "enabled" ]; then
    # Distinguish "the scheduler broke" from "this kernel was never able to
    # run one". The build tests the shipped kernel's BTF and leaves this
    # marker only when a BPF scheduler can load; without it, scx.service is
    # skipped by design and the machine is on EEVDF on purpose. Reporting
    # that as a failure would be crying wolf every boot until Fedora ships a
    # fixed kernel, and a warning nobody can act on is one they stop reading.
    if [ ! -e /usr/lib/pulsar/scx-supported ]; then
        echo "sched_ext present but this kernel's BTF cannot load a BPF scheduler"
        echo "(known Fedora issue: scx kfuncs carry the implicit prog-aux argument)"
        echo "scx.service is skipped by design; the machine is running stock EEVDF"
        exit 0
    fi
    echo "sched_ext state is '${state}', expected 'enabled' -- running stock EEVDF"
    systemctl status scx.service --no-pager --lines=10 || true
    exit 1
fi

sched=$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null || echo "unknown")
echo "sched_ext enabled, root scheduler: ${sched}"
exit 0
