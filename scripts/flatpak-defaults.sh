#!/usr/bin/env bash
# flatpak-defaults.sh -- install the default Flatpaks from
# /usr/share/pulsar/flatpaks.list, then stamp /var/lib/pulsar so it never
# runs again. Shared by pulsar-flatpaks.service (first online boot) and
# `pulsar setup apps` (on demand); both paths run as root and install
# system-wide, which is why this is not a setup recipe inlined in the CLI.
#
# `--or-update` makes a rerun idempotent rather than an error, so a failed
# half-install (network died mid-download) converges on the next attempt
# instead of wedging on "already installed".
#
# The stamp is deliberately success-only: a failed run leaves no stamp, the
# service retries, and nothing pretends the apps are there when they are not.
# It also means the stamp encodes "the defaults landed once" -- NOT "the
# defaults are present". Removing a default app afterwards is a user choice
# this script will never see and never revert.
set -euo pipefail

LIST=${PULSAR_FLATPAKS_LIST:-/usr/share/pulsar/flatpaks.list}
STAMP_DIR=/var/lib/pulsar
STAMP=${STAMP_DIR}/flatpaks-installed

[ -r "$LIST" ] || { echo "flatpak-defaults: no list at ${LIST}" >&2; exit 1; }

# Strip comments and blank lines. An empty result is a broken list, not a
# quiet no-op: the build asserts the shipped list is non-empty, so hitting
# this at runtime means someone edited it down to nothing.
mapfile -t apps < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$LIST")
[ ${#apps[@]} -gt 0 ] || { echo "flatpak-defaults: ${LIST} lists no apps" >&2; exit 1; }

flatpak install --system --noninteractive --or-update flathub "${apps[@]}"

install -d "$STAMP_DIR"
touch "$STAMP"
echo "flatpak-defaults: ${#apps[@]} apps present; stamped ${STAMP}"
