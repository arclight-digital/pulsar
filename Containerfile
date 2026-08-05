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
# ---------------------------------------------------------------------------
RUN dnf5 install -y \
      https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm \
      https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm \
      fedora-repos-archive && \
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
# the KERNEL supports sched_ext; it does NOT prove a scheduler attached, and
# an earlier version of this comment claimed it "degrades to stock scheduling"
# as though the two were the same thing. They are not: when the unit fails,
# the kernel keeps running stock EEVDF and NOTHING says so. The service can
# sit there reporting active while sched_ext reads disabled. The only honest
# check is `cat /sys/kernel/sched_ext/state`, which must read "enabled" --
# which is why greenboot check 20-scx-scheduler.sh reads exactly that file.
# ---------------------------------------------------------------------------
RUN dnf5 install -y 'dnf5-command(copr)' && \
    dnf5 copr enable -y bieszczaders/kernel-cachyos-addons && \
    dnf5 install -y scx-scheds

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
#   gh              a deliberate exception to the Flatpak rule above, stated
#                   as one. gh extends nothing about what the OS can DO, needs
#                   no host privilege, and would work fine in a distrobox --
#                   by the letter of the rule it does not belong here.
#                   It stays because this image is developed ON a machine
#                   running it: the repo is on GitHub, the images are on ghcr,
#                   and `gh attestation verify` is the command the README and
#                   the site tell strangers to run against those images. On a
#                   fresh install there is no box yet to run it in, and the
#                   one command this project asks you to trust it by should
#                   not require building a container first.
#   greenboot       boot-time health checks with automatic rollback. This is
#                   what turns "lighthouses don't drift" from a manual
#                   `bootc rollback` into something the machine does itself --
#                   and a manual rollback is precisely what you CANNOT run
#                   when the deployment you need to escape has no session to
#                   type it in. Checks ship in system_files under
#                   /usr/lib/greenboot/check/; rollback is armed by GRUB's
#                   boot_counter, installed via bootupd (asserted below).
# ---------------------------------------------------------------------------
RUN dnf5 install -y \
      gh \
      greenboot \
      greenboot-default-health-checks \
      gnome-tweaks \
      steam-devices \
      gamemode \
      mangohud \
      gamescope \
      distrobox \
      android-tools \
      libvirt \
      qemu-kvm

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
RUN rpm --import https://mise.jdx.dev/gpg-key.pub && \
    if ! rpm -qa 'gpg-pubkey*' | grep -qi '^gpg-pubkey-24853ec9f655ce80b48e6c3a8b81c9d17413a06d-'; then \
      echo "FATAL: mise signing key is not 24853EC9F655CE80B48E6C3A8B81C9D17413A06D"; exit 1; \
    fi && \
    printf '[mise]\nname=mise\nbaseurl=https://mise.jdx.dev/rpm/\nenabled=1\ngpgcheck=1\ngpgkey=https://mise.jdx.dev/gpg-key.pub\n' \
      > /etc/yum.repos.d/mise.repo && \
    dnf5 install -y mise

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
# ---------------------------------------------------------------------------
ARG GAMESCALE_VERSION=v2.0.0
ARG GAMESCALE_UUID=gamescale@arclight.digital
RUN set -eux; \
    REL="https://github.com/arclight-digital/gamescale/releases/download/${GAMESCALE_VERSION}"; \
    RAW="https://raw.githubusercontent.com/arclight-digital/gamescale/${GAMESCALE_VERSION}/extension"; \
    EXT="/usr/share/gnome-shell/extensions/${GAMESCALE_UUID}"; \
    curl -fsSL "${REL}/gamescale.sh" -o /usr/bin/gamescale; \
    echo "5f0ef1f338ea915fb6f5f141e625b813ac57fdbc4a7333b7b7d0094518dc5f91  /usr/bin/gamescale" \
      | sha256sum -c -; \
    chmod 0755 /usr/bin/gamescale; \
    mkdir -p "${EXT}/icons"; \
    curl -fsSL "${RAW}/extension.js"                 -o "${EXT}/extension.js"; \
    curl -fsSL "${RAW}/metadata.json"                -o "${EXT}/metadata.json"; \
    curl -fsSL "${RAW}/stylesheet.css"               -o "${EXT}/stylesheet.css"; \
    curl -fsSL "${RAW}/icons/gamescale-symbolic.svg" -o "${EXT}/icons/gamescale-symbolic.svg"; \
    curl -fsSL "${RAW}/icons/gamescale.svg"          -o "${EXT}/icons/gamescale.svg"; \
    ( cd "${EXT}" && printf '%s\n' \
      "99d4e239a212c3ad90118eaf3a609c2ca582c9df2cf490c7580358c03f242890  extension.js" \
      "e49e9bf6fc9956bfc0c9f31b0457fa9bd1bc6c42e11a1b6804abea0c28ee430f  metadata.json" \
      "7c41ae899869994c5056c2ed6e0ce939c46333e90fe355f26cf7e3e580f79e27  stylesheet.css" \
      "57e345929be538ed1542c5c7b1d7a25b9c8551d3c5de193f4883416ec00ba708  icons/gamescale-symbolic.svg" \
      "ddea876638fca8e25dfd4508385a881e529de9b1c0f4db65585e26aaacdca206  icons/gamescale.svg" \
      | sha256sum -c - ); \
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
# running.
# Nothing here touches update policy. Stock Silverblue behaviour is what we
# want -- GNOME Software (its rpm-ostree plugin is installed) checks and
# notifies, and the update installs when you choose. bootc's
# fetch-apply-updates.timer is deliberately left DISABLED: it runs
# `bootc upgrade --apply`, which reboots on its own.
RUN [ -f /usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg ] || \
      { echo "FATAL: greenboot no longer ships its bootupd grub fragment; without it GRUB never decrements boot_counter and automatic rollback silently never arms"; exit 1; }; \
    fc-cache -f && \
    glib-compile-schemas /usr/share/glib-2.0/schemas && \
    systemctl enable scx.service && \
    systemctl enable greenboot-healthcheck.service && \
    systemctl --global enable podman-auto-update.timer && \
    systemctl --global enable gamescale-reconcile.service && \
    systemctl disable NetworkManager-wait-online.service && \
    plymouth-set-default-theme pulsar && \
    KV=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core) && \
    dracut --force --no-hostonly --reproducible --add ostree \
      --kver ${KV} /usr/lib/modules/${KV}/initramfs.img && \
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

# /var is machine-local state; nothing the build left there (dnf caches,
# anything flatpak-shaped) belongs in the image, so clear it wholesale. Then
# put back an empty /var/tmp WITH the sticky bit: unprivileged tooling in
# derived builds (akmodsbuild in the nvidia variant) needs it writable, and
# if a later dnf run recreates it instead, it comes back root-only 0755.
RUN dnf5 clean all && \
    rm -rf /tmp/* /var/* && \
    install -d -m 1777 /var/tmp && \
    bootc container lint
