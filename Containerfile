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
#   gh              needed ON THE HOST, as root: build.sh verifies the ghcr
#                   base's provenance attestation with it, and .gitconfig
#                   uses it as the github credential helper. A toolbox copy
#                   cannot serve either.
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
