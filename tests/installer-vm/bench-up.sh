#!/bin/sh
# bench-up.sh TARGET.qcow2 SERIAL -- boot the bench VM with one target disk
cd "${BENCH:-/var/tmp/pulsar-installer-vm}"
exec qemu-system-x86_64 -name bench -machine q35,accel=kvm -cpu host -smp 4 -m 8192 \
 -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd -drive if=pflash,format=raw,file=bench-vars.fd \
 -drive file=bench.qcow2,if=virtio,format=qcow2 \
 -drive file="$1",if=none,id=t,format=qcow2 -device virtio-blk-pci,drive=t,serial="$2" \
 -cdrom seed.iso -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
 -display none -serial file:bench-serial.log -pidfile bench.pid
