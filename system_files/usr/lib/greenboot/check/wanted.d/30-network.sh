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
# WAITS FOR NETWORKMANAGER TO FINISH STARTING, NOT FOR A ROUTE. greenboot runs
# about eight seconds into boot and, with NetworkManager-wait-online disabled,
# nothing holds it for Wi-Fi: a single look failed on every boot on cherenkov
# (check at 11:18:33, link up at 11:18:36), and a warning that fires on every
# healthy boot teaches everyone to ignore it.
#
# But this check is NOT off the boot path. greenboot-healthcheck.service is
# wanted by multi-user.target, so the target waits for it, and scx.service is
# ordered after multi-user.target -- a long wait here delays the scheduler.
# An earlier version polled for a route for up to a minute, which an offline
# laptop paid in full on every boot. `nm-online -s` returns as soon as
# NetworkManager reports startup complete: right after the link comes up when
# there is one, and almost at once when there is nothing to connect to. The
# 10s cap bounds the rare slow case.
set -euo pipefail

if command -v nm-online >/dev/null 2>&1; then
    nm-online -s -q -t 10 || true
fi

if [ -n "$(ip route show default 2>/dev/null)" ]; then
    echo "default route present:"
    ip route show default
    exit 0
fi

echo "no default route once NetworkManager finished starting -- system booted without usable networking"
exit 1
