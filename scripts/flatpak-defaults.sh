#!/usr/bin/env bash
# flatpak-defaults.sh -- install the default Flatpaks from
# /usr/share/pulsar/flatpaks.list, then stamp /var/lib/pulsar so it never
# runs again. Shared by pulsar-flatpaks.service (first online boot) and
# `pulsar setup apps` (on demand); both paths run as root and install
# system-wide, which is why this is not a setup recipe inlined in the CLI.
#
# ONE APP AT A TIME, AND SKIP WHAT IS ALREADY HERE. This used to be a single
# batched `flatpak install ... "${apps[@]}"`, which failed whole on 2026-08-11:
#
#   error: com.github.wwmm.easyeffects/x86_64/stable is already installed
#          from remote fedora
#
# The Silverblue base ships a set of Fedora Flatpaks preinstalled from the
# `fedora` OCI remote, and easyeffects is one of them. Our list asks for the
# same application from flathub. `--or-update` absorbs "already installed from
# THIS remote"; a cross-remote collision is a hard error, and in a batch that
# error takes the other seven apps with it -- on cherenkov, ProtonPlus,
# Flatseal, Bottles and OBS Studio were never installed at all, quietly, while
# the unit retried every 120s for six days and reached 767 restarts. Nothing
# was wrong with those four; they were downstream of an argument list that
# never ran.
#
# So: check what is present first, skip those, and install the rest
# individually. A collision becomes a no-op, and one app that genuinely cannot
# install costs that app rather than the set.
#
# `--or-update` still makes a rerun idempotent rather than an error, so a
# failed half-install (network died mid-download) converges on the next
# attempt instead of wedging on "already installed".
#
# The stamp is deliberately success-only, and SUCCESS IS MEASURED, not
# inferred: every listed app has to be present when the loop finishes, which
# is not the same as every install command having exited 0. A failed run
# leaves no stamp, the service retries, and nothing pretends the apps are
# there when they are not. The stamp still encodes "the defaults landed once"
# -- NOT "the defaults are present". Removing a default app afterwards is a
# user choice this script will never see and never revert.
set -euo pipefail

LIST=${PULSAR_FLATPAKS_LIST:-/usr/share/pulsar/flatpaks.list}
STAMP_DIR=${PULSAR_STATE_DIR:-/var/lib/pulsar}
STAMP=${STAMP_DIR}/flatpaks-installed

[ -r "$LIST" ] || { echo "flatpak-defaults: no list at ${LIST}" >&2; exit 1; }

# Strip comments and blank lines. An empty result is a broken list, not a
# quiet no-op: the build asserts the shipped list is non-empty, so hitting
# this at runtime means someone edited it down to nothing.
mapfile -t apps < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$LIST")
[ ${#apps[@]} -gt 0 ] || { echo "flatpak-defaults: ${LIST} lists no apps" >&2; exit 1; }

# --system scope on both sides, because that is the only scope this installs
# into. A user-scope copy of the same app is not a conflict and must not be
# read as one -- it would skip a system-wide default on the strength of one
# user having it, and stamp as though the default had landed.
#
# Snapshotted rather than queried per app: eight apps twice over is sixteen
# `flatpak list` invocations for one string that changes only when we change
# it.
snapshot=""
refresh() { snapshot="$(flatpak list --system --app --columns=application 2>/dev/null || true)"; }
present() { printf '%s\n' "${snapshot}" | grep -Fxq -- "$1"; }

refresh
for app in "${apps[@]}"; do
  if present "${app}"; then
    echo "flatpak-defaults: ${app} is already installed; leaving it alone"
    continue
  fi
  # Not fatal on its own. The verdict is the presence check below, which is
  # the honest question -- an install that failed because something else
  # already provides the app is not a failure of this script.
  if flatpak install --system --noninteractive --or-update flathub "${app}"; then
    echo "flatpak-defaults: installed ${app}"
  else
    echo "flatpak-defaults: could not install ${app}" >&2
  fi
done

# Ask the system what is actually there rather than trusting the loop above.
refresh
missing=()
for app in "${apps[@]}"; do
  present "${app}" || missing+=("${app}")
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "flatpak-defaults: ${#missing[@]} of ${#apps[@]} apps are still missing:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "flatpak-defaults: no stamp written, so the service will try again" >&2
  exit 1
fi

install -d "$STAMP_DIR"
touch "$STAMP"
echo "flatpak-defaults: ${#apps[@]} apps present; stamped ${STAMP}"
