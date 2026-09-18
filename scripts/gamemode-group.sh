#!/usr/bin/env bash
# gamemode-group.sh -- add every human account on this machine to the
# `gamemode` group, then stamp /var/lib/pulsar so it never runs again. Shared
# by pulsar-gamemode-group.service (first boot) and `pulsar setup gamemode`
# (on demand), the same two-entry-point shape flatpak-defaults.sh has.
#
# WHY THIS EXISTS AT ALL. /etc/gamemode.ini sets renice=10, and the nice
# budget that makes it possible already ships: the gamemode RPM installs
# /etc/security/limits.d/10-gamemode.conf granting "@gamemode - nice -10".
# The only missing piece is membership, and membership is per-account state --
# the one category of thing a bootc image genuinely cannot bake, because
# /etc/group on a running system is not the /etc/group in the image.
#
# WHY IT CANNOT HELP THE FIRST SESSION. Supplementary groups are resolved by
# PAM at LOGIN and held for the life of the session. On a fresh install the
# account does not exist until the user finishes gnome-initial-setup, which is
# well after multi-user.target, so the first pass of this unit finds nobody,
# fails, and retries; by the time it succeeds the user is already logged in
# with a session that predates the group. renice therefore does nothing until
# the NEXT login. This is a property of how groups work, not a bug to fix
# here, and it is the reason the unit does not try to be clever about timing.
# Everything else gamemode does is unaffected.
#
# WHO COUNTS AS HUMAN. uid >= 1000 excludes system accounts; nobody (65534) is
# excluded explicitly; a shell of nologin/false excludes service accounts that
# were handed a high uid anyway. No hardcoded 1000 -- a machine with three
# users enrols three.
#
# WHAT IT DOES NOT DO. An account created AFTER the stamp is written is not
# enrolled, in the same way a Flatpak removed after that stamp does not come
# back. `pulsar setup gamemode` is the answer to both, and re-running it is
# harmless.
set -euo pipefail

# Overridable for the same reason flatpak-defaults.sh overrides its paths:
# the tests exercise the real decisions, not a reimplementation of them.
STAMP_DIR=${PULSAR_STATE_DIR:-/var/lib/pulsar}
STAMP="${STAMP_DIR}/gamemode-group-enrolled"
LIMITS_DIR=${PULSAR_LIMITS_DIR:-/etc/security/limits.d}
LIMITS_CONF=${PULSAR_LIMITS_CONF:-/etc/security/limits.conf}
GROUP=gamemode

[ "$(id -u)" -eq 0 ] || { echo "gamemode-group: must run as root" >&2; exit 1; }

# The group is created by the gamemode RPM's %pre. If it is missing, the
# package layout changed underneath us and enrolling people into a group that
# no limits.d file references would be a silent no-op -- fail loudly instead.
if ! getent group "$GROUP" >/dev/null; then
  echo "gamemode-group: no '${GROUP}' group; the gamemode package no longer creates it" >&2
  exit 1
fi

# The grant this whole file exists to make usable. If it is gone, renice=10
# cannot work no matter who is in the group, and enrolling them would be
# theatre.
if ! grep -rqs -- "@${GROUP}" "$LIMITS_DIR" "$LIMITS_CONF"; then
  echo "gamemode-group: no '@${GROUP}' nice grant in limits.d; renice=10 would be inert" >&2
  exit 1
fi

mapfile -t humans < <(
  getent passwd | awk -F: '
    $3 >= 1000 && $3 != 65534 &&
    $7 !~ /(nologin|\/false)$/ { print $1 }
  ' | sort -u
)

if [ ${#humans[@]} -eq 0 ]; then
  # The expected first-boot path on a fresh install: gnome-initial-setup has
  # not created anyone yet. No stamp, so the unit retries.
  echo "gamemode-group: no human accounts yet; nothing to enrol" >&2
  exit 1
fi

for user in "${humans[@]}"; do
  if id -nG "$user" | tr ' ' '\n' | grep -qx "$GROUP"; then
    echo "gamemode-group: ${user} already in ${GROUP}"
    continue
  fi
  if usermod -aG "$GROUP" "$user"; then
    echo "gamemode-group: enrolled ${user} in ${GROUP}"
  else
    echo "gamemode-group: failed to enrol ${user}" >&2
  fi
done

# Ask the system what is actually true rather than trusting the loop above.
missing=()
for user in "${humans[@]}"; do
  id -nG "$user" | tr ' ' '\n' | grep -qx "$GROUP" || missing+=("$user")
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "gamemode-group: ${#missing[@]} of ${#humans[@]} accounts are still not in ${GROUP}:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "gamemode-group: no stamp written, so the service will try again" >&2
  exit 1
fi

install -d "$STAMP_DIR"
touch "$STAMP"
echo "gamemode-group: ${#humans[@]} account(s) in ${GROUP}; stamped ${STAMP}"
echo "gamemode-group: renice takes effect at each account's NEXT login"
