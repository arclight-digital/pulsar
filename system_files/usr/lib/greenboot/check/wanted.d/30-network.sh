#!/usr/bin/bash
# WANTED (warn-only), NOT required -- on both counts deliberately.
#
# greenboot-default-health-checks does NOT ship a default-route check, despite
# being the obvious place for one. What it ships is 01_repository_dns_check.sh,
# which keys off /etc/ostree/remotes.d -- a directory that is present but
# EMPTY on a bootc system, because bootc pulls from a container registry and
# never writes an ostree remote. The script's own "directory is empty,
# skipping check" branch therefore fires on every boot and it exits 0 without
# testing networking at all. This file fills that gap honestly.
#
# Warn-only because this is a laptop image. Booting with no network is a
# completely normal state -- no wifi in range, ethernet unplugged, on a
# plane -- and a REQUIRED network check would roll back a perfectly healthy
# deployment for it, repeatedly, with no way to stop it from the air.
#
# WAITS UP TO A MINUTE FIRST. greenboot runs about eight seconds into boot,
# and with NetworkManager-wait-online disabled nothing holds it for Wi-Fi, so
# a single look failed on every boot on cherenkov: the check ran at 11:18:33
# and the link came up at 11:18:36. A warning that fires on every healthy boot
# teaches everyone to ignore it. Nothing waits on greenboot except
# boot-complete.target -- not the display manager, not login -- so the wait
# costs nothing visible.
set -euo pipefail

for _ in $(seq 1 30); do
    if [ -n "$(ip route show default 2>/dev/null)" ]; then
        echo "default route present:"
        ip route show default
        exit 0
    fi
    sleep 2
done

echo "no default route after 60s -- system booted without usable networking"
exit 1
