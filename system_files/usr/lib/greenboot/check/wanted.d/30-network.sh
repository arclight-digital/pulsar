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
set -euo pipefail

if [ -n "$(ip route show default 2>/dev/null)" ]; then
    echo "default route present:"
    ip route show default
    exit 0
fi

echo "no default route -- system booted without usable networking"
exit 1
