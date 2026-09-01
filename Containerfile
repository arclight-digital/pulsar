ARG FEDORA_VERSION=44
FROM quay.io/fedora-ostree-desktops/silverblue:${FEDORA_VERSION}
ARG FEDORA_VERSION

# ===========================================================================
# Pulsar -- vanilla.
#
# Branding, fonts, scheduler, papercuts. NO hardware-specific drivers, and
# deliberately NO build secrets: nothing in this file needs the Secure Boot
# signing key, so this image can be built anywhere, including public CI.
#
# NVIDIA lives in Containerfile.nvidia, which derives from this image and is
# the only artifact that touches the MOK private key.
# ===========================================================================

# ---------------------------------------------------------------------------
# Repos: rpmfusion + the updates-archive. The archive is not needed here, but
# the nvidia variant needs it to resolve kernel-devel for this image's exact
# kernel, and enabling it once here keeps the two images on identical repo
# state.
#
# Retried, because this is the first thing in the build that touches a mirror
# and a slow one kills the whole night three minutes in. On 2026-08-12
# mirrors.rpmfusion.org handed the release RPM to mirror.fcix.net, which then
# trickled under librepo's floor -- "Operation too slow. Less than 1000 bytes/
# sec transferred the last 30 seconds", curl error 28 -- and STEP 3 took the
# build down with it. Nothing was wrong with the build or with rpmfusion; one
# mirror out of the redirector's pool was having an evening.
#
# A retry rather than a raised timeout or a pinned mirror. dnf5 re-resolves the
# mirrorlist on each attempt, so attempt two usually lands somewhere else
# entirely, which is the actual fix -- waiting longer on the same bad mirror
# just fails slower. Pinning a mirror trades a transient failure for a
# permanent dependency on someone else's uptime.
#
# THE DISK IS CHECKED BEFORE THE MIRROR IS BLAMED, because on 2026-09-01 it
# was not. The build cache volume had reached zero free -- the builder's log
# said `(0 free)` at mount, before anything ran -- and rpm said exactly that,
# "needs 60KB more space on the / filesystem", three times, each time under a
# line from this loop reading "attempt N failed (mirror)" and then
# "rpmfusion release RPMs unreachable after 3 attempts". rpmfusion was fine.
# No retry can add disk, so a full one stops here rather than being reported
# as somebody else's outage. Every retry loop in both Containerfiles carries
# the same check for the same reason, and scripts/build.sh refuses to start a
# build on a filesystem that is already this short.
# ---------------------------------------------------------------------------
RUN for attempt in 1 2 3; do \
      dnf5 install -y \
        https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm \
        https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm \
        fedora-repos-archive && break; \
      free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"; \
      [ "${free_kb:-0}" -gt 262144 ] || \
        { echo "FATAL: ${free_kb}KB free on /; a full disk is not a mirror" >&2; exit 1; }; \
      [ "${attempt}" -lt 3 ] || { echo "rpmfusion release RPMs unreachable after 3 attempts" >&2; exit 1; }; \
      echo "attempt ${attempt} failed (mirror); retrying" >&2; \
      dnf5 clean all >/dev/null 2>&1 || true; \
      sleep $((attempt * 15)); \
    done && \
    dnf5 swap -y ffmpeg-free ffmpeg --allowerasing

# ---------------------------------------------------------------------------
# sched_ext. Arrow Lake-HX is 8 P-cores + 16 E-cores with no SMT, which is
# exactly where stock EEVDF placement underperforms.
#
# scx_bpfland, NOT scx_lavd: lavd --autopilot hits sched-ext/scx#3340 on this
# CPU and leaks ~300MB/s until it is OOM-killed. bpfland is reported
# unaffected, and ships on ALL hardware -- one scheduler everywhere beats a
# per-CPU conditional nobody can test the other branch of.
#
# scx.service carries ConditionPathExists=/sys/kernel/sched_ext. That proves
# the KERNEL supports sched_ext; it does NOT prove a scheduler attached: when
# the unit fails, the kernel keeps running stock EEVDF and NOTHING says so.
# The service can sit there reporting active while sched_ext reads disabled.
# The only honest check is `cat /sys/kernel/sched_ext/state`, which must read
# "enabled" -- which is why greenboot check 20-scx-scheduler.sh reads exactly
# that file.
# ---------------------------------------------------------------------------
#
# Retried for the reason given at the rpmfusion step, and more sharply: a COPR
# is ONE host. Fedora's own repos have a mirror pool librepo fails over across
# -- the 2026-08-12 log shows it walking eleven of them -- but
# copr.fedorainfracloud.org has no alternate to fail over to, so a bad minute
# there is a failed build unless something waits and asks again.
RUN for attempt in 1 2 3; do \
      dnf5 install -y 'dnf5-command(copr)' && \
      dnf5 copr enable -y bieszczaders/kernel-cachyos-addons && \
      dnf5 install -y scx-scheds && break; \
      free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"; \
      [ "${free_kb:-0}" -gt 262144 ] || \
        { echo "FATAL: ${free_kb}KB free on /; a full disk is not a mirror" >&2; exit 1; }; \
      [ "${attempt}" -lt 3 ] || { echo "copr kernel-cachyos-addons unreachable after 3 attempts" >&2; exit 1; }; \
      echo "attempt ${attempt} failed (copr); retrying" >&2; \
      sleep $((attempt * 15)); \
    done

# ---------------------------------------------------------------------------
# System-level capability, not applications.
#
# The line: anything that extends what the OS can DO ships here. Anything you
# merely run is a Flatpak.
#
#   gnome-tweaks    settings surface stock Silverblue does not expose, and
#                   has no Flatpak -- it is part of the "advanced" premise
#   steam-devices   udev rules; a Flatpak Steam cannot install these itself
#   gamemode        host daemon the Flatpak reaches through the portal
#   mangohud        Vulkan layer for native games (Flatpak games use the
#                   org.freedesktop.Platform.VulkanLayer.MangoHud extension)
#   gamescope       micro-compositor for forcing resolution/refresh/frame
#                   caps on misbehaving games; compositing is OS territory
#   distrobox       dev containers with exported binaries -- compilers and
#                   SDKs live in boxes, never in this image
#   android-tools   adb/fastboot udev rules; same logic as steam-devices --
#                   a sandboxed IDE cannot grant itself raw USB access
#   libvirt+qemu    virtualization is a host daemon stack; the GUI (Boxes,
#                   virt-manager) stays a Flatpak
#   greenboot       boot-time health checks with automatic rollback. This is
#                   what turns "the last good version is one reboot away"
#                   from a manual `bootc rollback` into something the
#                   machine does itself --
#                   and a manual rollback is precisely what you CANNOT run
#                   when the deployment you need to escape has no session to
#                   type it in. Checks ship in system_files under
#                   /usr/lib/greenboot/check/; rollback is armed by GRUB's
#                   boot_counter, installed via bootupd (asserted below).
#   urw-base35-     the document font, per zz0-pulsar.gschema.override. Already
#   nimbus-sans     present transitively (libgs requires urw-base35-fonts), and
#                   asked for by name anyway: the desktop's body face should
#                   not ride on ghostscript staying in the Silverblue base, and
#                   the failure mode is silent, because fontconfig SUBSTITUTES
#                   for a family it cannot find rather than erroring. Asserted
#                   below with the other two.
#
# `gh` was here once, carried as an admitted exception to the rule above so
# that `pulsar attest` had its verifier on a fresh install. The exception is
# withdrawn: by its own entry it extended nothing about what the OS can DO and
# worked fine in a distrobox, which is the test every other line here has to
# pass. Verifying is something you do TO this image, from wherever you already
# are, and one convenience is not worth a vendor's client in the base layer.
# `pulsar attest` still prints the exact command; it just no longer pretends
# the tool is the OS's problem. Do not add it back without a reason the rule
# above does not already answer.
# ---------------------------------------------------------------------------
RUN dnf5 install -y \
      greenboot \
      greenboot-default-health-checks \
      gnome-tweaks \
      urw-base35-nimbus-sans-fonts \
      steam-devices \
      gamemode \
      mangohud \
      gamescope \
      distrobox \
      android-tools \
      libvirt \
      qemu-kvm

# ---------------------------------------------------------------------------
# Fedora's Background Logo extension paints /usr/share/fedora-logos over the
# bottom-right of the desktop. It ships enabled on Silverblue, and it is not
# this image's brand.
#
# Removed as a PACKAGE, not disabled by gschema. The override in
# zz0-pulsar.gschema.override sets enabled-extensions, but that is only a
# DEFAULT: the moment a session writes its own enabled-extensions to the
# user's dconf -- which happens the first time anyone toggles any extension --
# that list wins and the default is never consulted again. A file that is not
# on disk cannot be enabled by anyone.
# ---------------------------------------------------------------------------
RUN dnf5 remove -y gnome-shell-extension-background-logo || true; \
    if [ -e "/usr/share/gnome-shell/extensions/background-logo@fedorahosted.org" ]; then \
      echo "FATAL: the background-logo extension is still installed"; \
      exit 1; \
    fi; \
    echo "background-logo extension: removed"

# ---------------------------------------------------------------------------
# Dev layer. Two kinds of thing that genuinely cannot live in a container.
#
#   bpftrace     kernel tracing. A distrobox cannot attach BPF programs to
#   bcc-tools    the host kernel, so these are worthless anywhere but here.
#   sysstat      sar/iostat/pidstat -- the boring numbers you want when the
#                machine is ALREADY misbehaving and you are not going to get
#                a second reproduction.
#   perf         same story, plus a version constraint (below).
#   direnv       per-directory environments; pairs with mise.
#
# perf is version-coupled to the kernel, so it gets a guard -- but the guard
# is on the SERIES, not the exact build, and that distinction was measured
# rather than assumed. The base currently ships kernel-core 7.1.5-201.fc44
# and NO perf-7.1.5-201 exists in any enabled repo, archive included; the
# repos carry 7.1.6-201 and 6.19.10-300. An exact pin therefore fails every
# build, immediately.
#
# What actually breaks a profile is a perf from a different kernel SERIES,
# and that is a live possibility here: 6.19.10 sits in the same repo, and it
# only loses the version comparison to 7.1.6 by luck of ordering. Z-stream
# drift within a series is harmless -- the perf_event ABI is stable across
# it -- so the check permits 7.1.5 vs 7.1.6 and rejects 7.1 vs 6.19.
# ---------------------------------------------------------------------------
RUN dnf5 install -y \
      bpftrace \
      bcc-tools \
      bpftool \
      sysstat \
      direnv \
      perf && \
    KV=$(rpm -q --qf '%{VERSION}' kernel-core) && \
    PV=$(rpm -q --qf '%{VERSION}' perf) && \
    echo "kernel-core ${KV} / perf ${PV}" && \
    if [ "${KV%.*}" != "${PV%.*}" ]; then \
      echo "FATAL: perf ${PV} is from a different kernel series than ${KV}; profiles would be wrong"; exit 1; \
    fi

# ---------------------------------------------------------------------------
# Can the kernel this image ships actually load a sched_ext scheduler?
#
# `ConditionPathExists=/sys/kernel/sched_ext` proves sched_ext EXISTS. It says
# nothing about whether a BPF scheduler can load, and on Fedora 7.1.5/7.1.6 it
# cannot: 38 scx kfuncs publish the implicit 'struct bpf_prog_aux *' in their
# BTF prototypes, so every scheduler dies with 'func_proto incompatible with
# vmlinux'. Asking at build time turns a boot-time mystery into a build log
# line, and drops the marker scx.service conditions on.
#
# Deliberately not fatal when the answer is "no" -- a kernel that cannot run
# sched_ext is a fine machine, just a machine on EEVDF. It IS fatal when the
# answer cannot be determined, because shipping an image whose scheduler
# behaviour nobody can explain is the failure this whole gate exists to stop.
# ---------------------------------------------------------------------------
COPY scripts/check-scx-btf.sh /usr/libexec/pulsar/check-scx-btf.sh
RUN chmod 0755 /usr/libexec/pulsar/check-scx-btf.sh && \
    mkdir -p /usr/lib/pulsar && \
    if /usr/libexec/pulsar/check-scx-btf.sh --image; then \
      touch /usr/lib/pulsar/scx-supported; \
      echo "scx: kernel BTF is clean, scx.service will start at boot"; \
    else \
      rc=$?; \
      if [ "${rc}" != "1" ]; then \
        echo "FATAL: could not determine whether this kernel can load sched_ext (exit ${rc})"; \
        exit 1; \
      fi; \
      echo "scx: this kernel cannot load a BPF scheduler; scx.service will be skipped"; \
    fi

# ---------------------------------------------------------------------------
# mise: one tool to pin node/python/go/rust per project, so toolchains never
# get layered into this image and Homebrew never has to exist.
#
# It is NOT in Fedora's repos, so this adds mise.jdx.dev as a trust root. That
# is a real supply-chain decision, so it is made explicitly rather than by a
# curl|sh: the signing key's FULL fingerprint is asserted before the repo is
# written, and a swapped or rotated key fails the build instead of quietly
# installing whatever the new key signed. Precedent already set by rpmfusion
# and the cachyos COPR above -- this is the same trade, stated out loud.
# ---------------------------------------------------------------------------
#
# The two network reaches are retried; the fingerprint assertion between them
# is NOT, and that separation is the point. mise.jdx.dev is a single host with
# no mirror, so a transient fetch failure deserves another go -- but a key that
# imported cleanly and turned out to be the WRONG key is a supply-chain answer,
# not a flake, and retrying it three times would only spend more time arriving
# at the same refusal.
RUN for attempt in 1 2 3; do \
      rpm --import https://mise.jdx.dev/gpg-key.pub && break; \
      free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"; \
      [ "${free_kb:-0}" -gt 262144 ] || \
        { echo "FATAL: ${free_kb}KB free on /; a full disk is not a mirror" >&2; exit 1; }; \
      [ "${attempt}" -lt 3 ] || { echo "FATAL: could not fetch the mise signing key" >&2; exit 1; }; \
      echo "attempt ${attempt} failed (mise key); retrying" >&2; \
      sleep $((attempt * 15)); \
    done; \
    if ! rpm -qa 'gpg-pubkey*' | grep -qi '^gpg-pubkey-24853ec9f655ce80b48e6c3a8b81c9d17413a06d-'; then \
      echo "FATAL: mise signing key is not 24853EC9F655CE80B48E6C3A8B81C9D17413A06D"; exit 1; \
    fi && \
    printf '[mise]\nname=mise\nbaseurl=https://mise.jdx.dev/rpm/\nenabled=1\ngpgcheck=1\ngpgkey=https://mise.jdx.dev/gpg-key.pub\n' \
      > /etc/yum.repos.d/mise.repo && \
    for attempt in 1 2 3; do \
      dnf5 install -y mise && break; \
      free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"; \
      [ "${free_kb:-0}" -gt 262144 ] || \
        { echo "FATAL: ${free_kb}KB free on /; a full disk is not a mirror" >&2; exit 1; }; \
      [ "${attempt}" -lt 3 ] || { echo "mise.jdx.dev unreachable after 3 attempts" >&2; exit 1; }; \
      echo "attempt ${attempt} failed (mise repo); retrying" >&2; \
      sleep $((attempt * 15)); \
    done

# ---------------------------------------------------------------------------
# gamescale -- run a game at 1x monitor scale so XWayland is handed the panel's
# real mode, then put the desktop back when it exits.
#
# Display configuration is OS territory, and this needs a systemd user unit to
# reconcile a scale left behind by a crash, so it earns a place in the image
# rather than a Flatpak.
#
# Pinned to a TAG, never main: this is a script that rewrites your display
# configuration, and "whatever upstream pushed today" is not a thing to boot
# into. gamescale.sh is checksum-verified against the hash recorded HERE, not
# merely against the SHA256SUMS shipped beside it -- a re-cut release would
# update both, and the point of pinning is that WE decide when the image
# changes.
#
# The extension is fetched from the tag rather than the release, because
# releases deliberately ship only the script (upstream's reasoning: shipping
# more unverifiable pieces is not worth an icon). Fetching by pinned hash is
# what makes that safe to do anyway.
#
# Everything is ALSO staged at /usr/share/pulsar/gamescale/ in the exact
# layout upstream's installer recognises as a checkout -- install.sh beside
# gamescale.sh, with extension/metadata.json under it. That is not a spare
# copy for its own sake:
#
# A Flatpak launcher can never reach /usr/bin/gamescale. Flatpak reserves
# /usr for the runtime and refuses to bind the host's over it ("Path /usr is
# reserved by Flatpak"), so a sandbox-visible copy under $HOME is not a
# preference, it is the only arrangement that works. Granting a launcher
# therefore always means running the installer.
#
# Staged here, that install runs OFFLINE against these pinned, hash-verified
# files instead of curling main. So the ~/.local copy is a projection of the
# image's copy rather than an independently downloaded second version, and
# `pulsar setup gamescale` can be a thin wrapper over upstream's own logic
# rather than a reimplementation of its flatpak grants that drifts.
# ---------------------------------------------------------------------------
#
# Every fetch goes through get(), which is curl with retries. github.com and
# raw.githubusercontent.com are single origins with no mirror, and there are
# seven round trips here -- seven chances for one blip to cost the build. The
# sha256sum block below is unchanged and still decides what is acceptable, so
# retrying can only affect whether bytes arrive, never which bytes count.
ARG GAMESCALE_VERSION=v2.0.0
ARG GAMESCALE_UUID=gamescale@arclight.digital
RUN set -eux; \
    REL="https://github.com/arclight-digital/gamescale/releases/download/${GAMESCALE_VERSION}"; \
    RAW="https://raw.githubusercontent.com/arclight-digital/gamescale/${GAMESCALE_VERSION}/extension"; \
    SRC="/usr/share/pulsar/gamescale"; \
    EXT="/usr/share/gnome-shell/extensions/${GAMESCALE_UUID}"; \
    mkdir -p "${SRC}/extension/icons" "${EXT}/icons"; \
    get() { curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors "$1" -o "$2"; }; \
    get "${REL}/gamescale.sh" "${SRC}/gamescale.sh"; \
    get "${REL}/install.sh"   "${SRC}/install.sh"; \
    get "${RAW}/extension.js"                 "${SRC}/extension/extension.js"; \
    get "${RAW}/metadata.json"                "${SRC}/extension/metadata.json"; \
    get "${RAW}/stylesheet.css"               "${SRC}/extension/stylesheet.css"; \
    get "${RAW}/icons/gamescale-symbolic.svg" "${SRC}/extension/icons/gamescale-symbolic.svg"; \
    get "${RAW}/icons/gamescale.svg"          "${SRC}/extension/icons/gamescale.svg"; \
    ( cd "${SRC}" && printf '%s\n' \
      "5f0ef1f338ea915fb6f5f141e625b813ac57fdbc4a7333b7b7d0094518dc5f91  gamescale.sh" \
      "6a2bafdde0e3589c8e0d3a8ffcde41181fdfef18ce5f487d36ec0ef62410775f  install.sh" \
      "99d4e239a212c3ad90118eaf3a609c2ca582c9df2cf490c7580358c03f242890  extension/extension.js" \
      "e49e9bf6fc9956bfc0c9f31b0457fa9bd1bc6c42e11a1b6804abea0c28ee430f  extension/metadata.json" \
      "7c41ae899869994c5056c2ed6e0ce939c46333e90fe355f26cf7e3e580f79e27  extension/stylesheet.css" \
      "57e345929be538ed1542c5c7b1d7a25b9c8551d3c5de193f4883416ec00ba708  extension/icons/gamescale-symbolic.svg" \
      "ddea876638fca8e25dfd4508385a881e529de9b1c0f4db65585e26aaacdca206  extension/icons/gamescale.svg" \
      | sha256sum -c - ); \
    install -m 0755 "${SRC}/gamescale.sh" /usr/bin/gamescale; \
    chmod 0755 "${SRC}/install.sh"; \
    install -m 0644 "${SRC}/extension/extension.js" "${SRC}/extension/metadata.json" \
                    "${SRC}/extension/stylesheet.css" "${EXT}/"; \
    install -m 0644 "${SRC}/extension/icons/gamescale-symbolic.svg" \
                    "${SRC}/extension/icons/gamescale.svg" "${EXT}/icons/"; \
    test "$(jq -r .uuid "${EXT}/metadata.json")" = "${GAMESCALE_UUID}"; \
    SHELL_MAJOR="$(gnome-shell --version | sed 's/[^0-9.]//g' | cut -d. -f1)"; \
    if ! jq -e --arg v "${SHELL_MAJOR}" '."shell-version" | index($v)' "${EXT}/metadata.json" >/dev/null; then \
      echo "FATAL: gamescale ${GAMESCALE_VERSION} does not support GNOME Shell ${SHELL_MAJOR}"; \
      echo "       it declares: $(jq -c '."shell-version"' "${EXT}/metadata.json")"; \
      echo "       a shipped-but-incompatible extension is silently dead in the top bar"; \
      exit 1; \
    fi; \
    gamescale --version >/dev/null 2>&1 || true

# No GUI apps are layered here. Apps are Flatpaks; this image is the OS.
#
# Flathub, unfiltered -- Fedora ships a filtered remote. Shipped as a
# preconfigured remote (etc/flatpak/remotes.d/ in the overlay below), NOT via
# `flatpak remote-add`: remote-add writes /var/lib/flatpak, and /var content
# from an image seeds first boot only, so it never reliably survived a rebase.
# A remotes.d file lives in /etc, which ostree merges into existing systems
# too -- this fixes rebases, not just fresh installs.
#
# The same /var constraint is why the DEFAULT apps are not baked either: the
# image carries only a list (/usr/share/pulsar/flatpaks.list, in the overlay)
# and pulsar-flatpaks.service installs it on the first boot that can reach
# flathub, stamping /var/lib/pulsar so user removals stick afterwards.
# `sudo pulsar setup apps` is the same script run on demand.

# ---------------------------------------------------------------------------
# Branding + config overlay. system_files/ mirrors / exactly.
#
# Also carries /etc/pki/pulsar/MOK.der -- the PUBLIC half of the keypair the
# nvidia variant signs modules with. It is public, so it is a plain committed
# file, and it ships in BOTH variants so a Secure Boot machine can enroll it
# BEFORE rebasing onto nvidia:
#   sudo mokutil --import /etc/pki/pulsar/MOK.der
# ---------------------------------------------------------------------------
COPY system_files/ /

# Plymouth: inherit Fedora's spinner assets, then let our own watermark and
# .plymouth config (copied above) override them.
# The || true is load-bearing: cp -n exits nonzero when it SKIPS a file, and
# it always skips watermark.png, which the overlay shipped first. But that
# tolerance would also hide the spinner theme disappearing from a future base
# image, leaving a splash with no throbber, discovered only at boot -- so
# assert the source exists before tolerating the copy's exit code.
RUN [ -f /usr/share/plymouth/themes/spinner/throbber-0001.png ] || \
      { echo "FATAL: base image no longer ships the spinner theme assets"; exit 1; }; \
    cp -n /usr/share/plymouth/themes/spinner/*.png \
          /usr/share/plymouth/themes/pulsar/ 2>/dev/null || true

# ---------------------------------------------------------------------------
# Version stamp. CI passes the build version; a local build leaves it empty and
# keeps the plain "Pulsar 44", so ./scripts/build.sh needs no arguments.
#
# PRETTY_NAME is the whole mechanism: ostree composes each BLS entry title as
# PRETTY_NAME + " (ostree:N)". That is why a stock entry reads "Fedora Linux
# 44.20260804.0 (Silverblue)" while ours read "Pulsar 44" -- the version was
# never in the string. Setting it here is what puts it in the boot menu, and
# the same value goes on the image label so `bootc status` agrees with GRUB.
#
# VERSION_ID is deliberately left alone, which is also what stock Fedora does:
# it keeps VERSION_ID=44 and puts the datestamp only in VERSION and
# PRETTY_NAME. VERSION_ID is the field third-party scripts compare
# numerically, for the same reason ID stays "fedora" in os-release itself.
# ---------------------------------------------------------------------------
ARG PULSAR_VERSION=""
RUN if [ -n "${PULSAR_VERSION}" ]; then \
      sed -i \
        -e "s|^VERSION=.*|VERSION=\"${PULSAR_VERSION}\"|" \
        -e "s|^PRETTY_NAME=.*|PRETTY_NAME=\"Pulsar ${PULSAR_VERSION}\"|" \
        /usr/lib/os-release; \
      grep -E '^(VERSION|VERSION_ID|PRETTY_NAME)=' /usr/lib/os-release; \
      vid=$(. /usr/lib/os-release; echo "${VERSION_ID}"); \
      if [ "${vid}" != "${FEDORA_VERSION}" ]; then \
        echo "FATAL: VERSION_ID became '${vid}'; it must stay ${FEDORA_VERSION} or numeric comparisons break"; \
        exit 1; \
      fi; \
    fi

# ID stays `fedora`, deliberately: dnf's $releasever, some flatpak remote
# filtering, and a pile of third-party scripts key off it. Bazzite and Bluefin
# keep it too. Change NAME/PRETTY_NAME/VARIANT in system_files, not ID.
#
# That explanation used to be a comment inside os-release itself, which cost an
# ISO build to discover: bootc-image-builder's parser skips blank lines but has
# no comment handling at all, so any line without an `=` is fatal --
# `readOSRelease: invalid input`, with no hint which line. The os-release spec
# does allow comments; bib does not. So the file stays strictly KEY=VALUE and
# this asserts it, unconditionally, rather than trusting the next editor to
# remember.
RUN bad=$(grep -vE '^[[:space:]]*$' /usr/lib/os-release | grep -vE '^[A-Z0-9_]+=' || true); \
    if [ -n "${bad}" ]; then \
      echo "FATAL: /usr/lib/os-release has lines that are not KEY=VALUE:"; \
      echo "${bad}"; \
      echo "       bootc-image-builder rejects these and the ISO build dies with"; \
      echo "       'readOSRelease: invalid input'. Comments belong in the Containerfile."; \
      exit 1; \
    fi; \
    echo "os-release: $(grep -cE '^[A-Z0-9_]+=' /usr/lib/os-release) keys, no stray lines"
LABEL org.opencontainers.image.version="${PULSAR_VERSION}"

# ---------------------------------------------------------------------------
# The pulsar CLI, and the manifest it prints.
#
# The SBOM generator is shared with CI rather than reimplemented: the same
# script describes a container image there and the running system here, so the
# two can never disagree about what a package version looks like.
#
# There is deliberately NO baked sbom.spdx.json. A file inside the image cannot
# describe the image that contains it -- adding it changes what it describes.
# `pulsar sbom` reads the live rpm database instead, which is the same source
# and is correct by construction; the published per-build copies live in R2.
# ---------------------------------------------------------------------------
ARG PULSAR_CHANGELOG_URL="https://pulsar.arclight.digital/changelog.json"
COPY cli/pulsar /usr/bin/pulsar
COPY scripts/rpm-sbom.sh /usr/libexec/pulsar/rpm-sbom.sh
COPY scripts/flatpak-defaults.sh /usr/libexec/pulsar/flatpak-defaults.sh
RUN chmod 0755 /usr/bin/pulsar /usr/libexec/pulsar/rpm-sbom.sh \
      /usr/libexec/pulsar/flatpak-defaults.sh && \
    grep -qvE '^\s*(#|$)' /usr/share/pulsar/flatpaks.list || \
      { echo "FATAL: flatpaks.list ships no apps; pulsar-flatpaks.service would fail on every boot forever"; exit 1; } && \
    mkdir -p /usr/share/pulsar && \
    jq -n \
      --arg image     "pulsar" \
      --arg variant   "vanilla" \
      --arg version   "${PULSAR_VERSION:-${FEDORA_VERSION}}" \
      --arg base      "fedora-silverblue:${FEDORA_VERSION}" \
      --arg built     "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg kernel    "$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)" \
      --arg scheduler "scx_bpfland" \
      --arg scxbtf    "$([ -e /usr/lib/pulsar/scx-supported ] && echo ok || echo malformed)" \
      --arg gamescope "$(rpm -q --qf '%{VERSION}-%{RELEASE}' gamescope)" \
      --arg gamemode  "$(rpm -q --qf '%{VERSION}-%{RELEASE}' gamemode)" \
      --arg mangohud  "$(rpm -q --qf '%{VERSION}-%{RELEASE}' mangohud)" \
      --arg mesa      "$(rpm -q --qf '%{VERSION}-%{RELEASE}' mesa-dri-drivers)" \
      --arg gamescale "${GAMESCALE_VERSION}" \
      --arg changelog "${PULSAR_CHANGELOG_URL}" \
      '{image:$image, variant:$variant, version:$version, base:$base, built:$built, \
        kernel:$kernel, \
        components:{scheduler:$scheduler, scheduler_btf:$scxbtf, \
                    gamescope:$gamescope, gamemode:$gamemode, mangohud:$mangohud, \
                    mesa:$mesa, gamescale:$gamescale}, \
        changelog_url:$changelog, \
        attestation:"gh attestation verify oci://ghcr.io/arclight-digital/pulsar --owner arclight-digital"}' \
      > /usr/share/pulsar/manifest.json && \
    jq -e '.version and .kernel and .components.scheduler' /usr/share/pulsar/manifest.json >/dev/null && \
    pulsar --version && \
    for t in jq skopeo notify-send; do \
      command -v "$t" >/dev/null || \
        { echo "FATAL: ${t} is gone from the base image; pulsar-update-check.timer would fail every six hours and this system would go stale in silence, which is the exact failure it exists to prevent"; exit 1; }; \
    done && \
    echo "update check: jq / skopeo / notify-send present"

# ---------------------------------------------------------------------------
# Finalize. The initramfs carries the plymouth theme, so the dracut regen has
# to come after the overlay lands. The nvidia variant regenerates it a second
# time because it adds modprobe.d options that also live in the initramfs.
# ---------------------------------------------------------------------------
# scx.service and greenboot-healthcheck.service are enabled HERE, not by the
# preset file: presets only run on a fresh `bootc install`, never on a rebase,
# so on a rebased system the units would silently never start. This writes the
# /etc wants symlink, which the ostree /etc merge carries onto rebased systems.
# greenboot in particular ships NO preset entry of its own (checked against
# the F44 package), so without this line it installs and never runs.
#
# Enabling greenboot-healthcheck.service also pulls in greenboot-success.target
# and greenboot-set-rollback-trigger.service via its [Install] Also=.
#
# podman-auto-update.timer is enabled --global, i.e. for every USER session,
# not the system. Quadlets in this image's workflow are rootless by design, so
# the system timer would find nothing to update. It only touches containers
# explicitly labelled AutoUpdate= (see the shipped template), so enabling it
# by default cannot surprise a container that did not opt in.
#
# Deliberately the ONLY enablement. A second symlink under /usr/lib would
# survive `systemctl disable`, leaving a unit that reports disabled and keeps
# running. The preset files mirror this list as POLICY, not symlinks -- see
# their headers for why that does not recreate the problem -- and the
# assertion below keeps them in lockstep with the calls here.
# pulsar-update-check.timer is enabled --global, for the same reason
# podman-auto-update.timer is: it ends in a desktop notification and the
# session bus lives in the user session. It only READS -- one rpm-ostree
# status, one registry call -- and never stages or applies anything.
#
# It is here because this image cannot rely on GNOME Software for the job, and
# that is worth stating plainly since the comment this replaces claimed the
# opposite for months. GNOME Software's rpm-ostree plugin asks the daemon via
# AutomaticUpdateTrigger and reads the answer back with
# GetCachedUpdateRpmDiff. On a deployment carrying layered packages the
# daemon's container query dies on a missing ostree.manifest-digest -- the
# layering merge commit does not carry the key, only the base commit does --
# reports the transaction successful regardless, and caches nothing. The UI
# then shows no updates, indefinitely, on a system that is months stale. Any
# user who layers a single package lands in this state, so "we ship no update
# policy and let GNOME Software handle it" was not a policy, it was an outage.
#
# The fix is a comparison rpm-ostree already has both halves for, so the timer
# stays small: see cmd_update_check in cli/pulsar.
#
# Still deliberately NOT enabled: bootc's fetch-apply-updates.timer, which
# runs `bootc upgrade --apply` and reboots on its own, and would additionally
# drop the layers on any system that has them. Notifying is the policy;
# applying stays the user's call. rpm-ostree-countme.timer stays at its stock
# enablement too: an anonymous population count that keeps the Fedora base
# this image rides on counted, and a fork that objects turns off one timer.
RUN [ -f /usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg ] || \
      { echo "FATAL: greenboot no longer ships its bootupd grub fragment; without it GRUB never decrements boot_counter and automatic rollback silently never arms"; exit 1; }; \
    fc-cache -f && \
    for f in "Host Grotesk" "JetBrains Mono" "Nimbus Sans"; do \
      got=$(fc-match -f '%{family[0]}' "$f"); \
      [ "$got" = "$f" ] || \
        { echo "FATAL: font '$f' does not resolve; fontconfig substitutes '$got'. Every font key in zz0-pulsar.gschema.override would silently render in the wrong face"; exit 1; }; \
    done; \
    for g in sans-serif:"Host Grotesk" monospace:"JetBrains Mono"; do \
      got=$(fc-match -f '%{family[0]}' "${g%%:*}"); \
      [ "$got" = "${g#*:}" ] || \
        { echo "FATAL: generic '${g%%:*}' resolves to '$got', not '${g#*:}'; 52-pulsar.conf is not winning its sort order against Fedora's font configs"; exit 1; }; \
    done; \
    fc-match -f '%{family[0]}' sans-serif:lang=ja | grep -q '^Noto' || \
      { echo "FATAL: non-Latin sans-serif fallback no longer reaches Noto; 52-pulsar.conf has pinned a Latin-only face ahead of the CJK chain"; exit 1; }; \
    echo "fonts: Host Grotesk / JetBrains Mono / Nimbus Sans resolve; generics bound; non-Latin fallback intact" && \
    glib-compile-schemas /usr/share/glib-2.0/schemas && \
    systemctl enable scx.service && \
    systemctl enable greenboot-healthcheck.service && \
    systemctl enable pulsar-flatpaks.service && \
    systemctl --global enable podman-auto-update.timer && \
    systemctl --global enable gamescale-reconcile.service && \
    systemctl --global enable pulsar-update-check.timer && \
    systemctl disable NetworkManager-wait-online.service && \
    for u in scx.service greenboot-healthcheck.service pulsar-flatpaks.service; do \
      grep -qx "enable ${u}" /usr/lib/systemd/system-preset/50-pulsar.preset || \
        { echo "FATAL: ${u} is enabled here but missing from the system preset; a full preset-all would disable it"; exit 1; }; \
    done && \
    for u in podman-auto-update.timer gamescale-reconcile.service pulsar-update-check.timer; do \
      grep -qx "enable ${u}" /usr/lib/systemd/user-preset/50-pulsar.preset || \
        { echo "FATAL: ${u} is enabled --global here but missing from the user preset; a full preset-all would disable it"; exit 1; }; \
    done && \
    plymouth-set-default-theme pulsar && \
    KV=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core) && \
    install -d -m 0700 /var/roothome && \
    { DRACUT_NO_XATTR=1 dracut --force --no-hostonly --reproducible --add ostree \
        --kver ${KV} /usr/lib/modules/${KV}/initramfs.img >/tmp/dracut.log 2>&1 || \
      { cat /tmp/dracut.log; echo "FATAL: dracut exited nonzero"; exit 1; }; }; \
    cat /tmp/dracut.log; \
    if grep -q 'dracut\[E\]: FAILED' /tmp/dracut.log; then \
      echo "FATAL: dracut logged a module-install failure above and exited 0 anyway"; \
      exit 1; \
    fi; \
    lsinitrd /usr/lib/modules/${KV}/initramfs.img | grep -q ostree-prepare-root || \
      { echo "FATAL: initramfs is missing ostree-prepare-root; the image cannot switch root"; exit 1; }

# `--add ostree` is BOOT-CRITICAL, learned the hard way: dracut decides which
# modules to include by probing the environment it runs in, and a container
# build has no /run/ostree-booted -- so a plain `dracut` silently omits the
# ostree module. The resulting image boots the initramfs, shows plymouth, and
# then dies at switch-root with "/sysroot does not seem to be an OS tree.
# os-release file is missing", because nothing ever ran ostree-prepare-root.
# The lsinitrd assertion turns that brick into a red build. --no-hostonly for
# the same probing reason (the "host" is a build container, not the laptop),
# --reproducible because there is no reason not to.
#
# DRACUT_NO_XATTR=1 is what lets this build on an SELinux host at all, and it
# is not a workaround for a policy problem -- there is no denial and no AVC.
# podman mounts the container rootfs with a MOUNT-WIDE context=:
#
#   overlay / overlay rw,context="system_u:object_r:container_file_t:s0:c793,c938",...
#
# A filesystem mounted that way has one label for every file by definition, so
# the kernel answers setxattr("security.selinux") with EOPNOTSUPP -- Operation
# not supported, never Permission denied. dracut-init.sh then builds its copy
# command as `cp --preserve=mode,xattr,timestamps,ownership` whenever it is
# root and DRACUT_NO_XATTR is unset, cp exits 1 on the failed attribute, and
# dracut logs dracut[E]: FAILED and EXITS 0 -- caught only by the grep below.
#
# Because it is a mount option rather than an enforcement decision, SELinux
# being permissive does not help: permissive relaxes denials, and this is not
# one. Only a host with SELinux fully disabled avoids it, which is why this
# never appeared on the Ubuntu runners and appeared immediately on Rocky.
#
# Dropping the xattr costs nothing here. The labels being copied are the
# container's own mount-wide label, not the image's, and files inside an
# initramfs cpio are labelled from policy at runtime regardless. It also makes
# the initramfs identical to the one an SELinux-less builder produces, which
# is what --reproducible is for.
#
# /var/roothome exists before dracut runs because /root is an ostree symlink
# into it and the base image started shipping /var empty: dracut's base
# module installs /root, and a dangling symlink turned into
# "dracut-install: ERROR: installing '/root'" -- which dracut logs as
# dracut[E]: FAILED and then EXITS 0. That is why the log is grepped: the
# lsinitrd assertion checks one known-critical file, the grep catches every
# module-install failure dracut swallowed. Grepped for "FAILED" specifically,
# not every [E] line -- "No '/dev/log' or 'logger'" is chronic container
# noise with nothing behind it.

# /var is machine-local state; nothing the build left there (dnf caches,
# anything flatpak-shaped) belongs in the image, so clear it wholesale. Then
# put back an empty /var/tmp WITH the sticky bit: unprivileged tooling in
# derived builds (akmodsbuild in the nvidia variant) needs it writable, and
# if a later dnf run recreates it instead, it comes back root-only 0755.
RUN dnf5 clean all && \
    rm -rf /tmp/* /var/* && \
    install -d -m 1777 /var/tmp && \
    bootc container lint
