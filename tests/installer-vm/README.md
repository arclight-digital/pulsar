# Installer VM bench

The installer's root-only steps (`pulsar-install-system`: unlock, mount,
`bootc install`, firmware entry, GRUB's Windows entry) can't run on disk
images, so they run here, inside a throwaway Fedora Cloud VM under qemu as
your own user: no sudo on the host, and every disk is a qcow2 file in
`$BENCH` (default `/var/tmp/pulsar-installer-vm`, ~20G). `/tmp` is RAM on
Pulsar; keep the bench off it.

One-time setup in `$BENCH`: the Fedora Cloud Base qcow2 (verify its
CHECKSUM's signature and hash), an ed25519 key `id`, a cloud-init `seed.iso`
(user `tester`, NOPASSWD sudo, that key), `bench.qcow2` as an 80G overlay on
the cloud image, and in the VM: `cryptsetup dosfstools e2fsprogs` and
`podman pull ghcr.io/arclight-digital/pulsar:latest`.

A run:

    qemu-img create -f qcow2 $BENCH/dual.qcow2 64G
    tests/installer-vm/bench-up.sh dual.qcow2 PULSARDUAL &      # the target: /dev/disk/by-id/virtio-PULSARDUAL
    # copy scripts/pulsar-install-{disk,system}, the repart layouts and the
    # two helper scripts in; in the VM:
    ./fake-windows.sh $D && ./fingerprint.sh $D > before.txt   # refuse to go on unless the hashes differ and none is empty
    sudo efibootmgr > nvram-before.txt
    sudo PULSAR_INSTALLER_LAYOUTS=... PULSAR_BOOTC_PREFIX="podman run --rm --privileged --pid=host \
        -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v /run/pulsar-install:/run/pulsar-install \
        --security-opt label=type:unconfined_t ghcr.io/arclight-digital/pulsar:latest" \
      scripts/pulsar-install-system --mode alongside --key-file ~/key \
        --source-imgref containers-storage:ghcr.io/arclight-digital/pulsar:latest \
        --target-imgref ghcr.io/arclight-digital/pulsar:latest --karg console=ttyS0,115200 $D
    ./fingerprint.sh $D > after.txt; diff before.txt after.txt   # only EFI/BOOT and Pulsar's own files may differ
    diff nvram-before.txt <(sudo efibootmgr)                     # nothing removed; one Pulsar entry added

Then boot the target alone with fresh firmware variables and drive its
console with `bootcheck.py SOCKET LOG` (a chardev socket on `-serial`): it
needs the passphrase prompt, a wrong passphrase refused and asked again, and
the right one reaching a login. It waits for a QUIET prompt: the prompt is
redrawn for every echoed `*`, and matching the text alone once passed a run
that never unlocked.

Not mounted on `/tmp` in the wrapper: bootc copies itself there to enter
SELinux's install_t, and sharing the host's `/tmp` breaks that.
