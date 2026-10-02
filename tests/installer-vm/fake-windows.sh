#!/bin/bash
# fake-windows.sh DISK -- a Windows-shaped GPT disk with a real FAT ESP
set -euo pipefail
D=$1
sudo wipefs -aq $D
sudo sfdisk -q $D <<SF
label: gpt
start=2048, size=100MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI system partition"
size=16MiB, type=E3C9E316-0B5C-4DB8-817D-F92DF00215AE, name="Microsoft reserved partition"
size=20GiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="Basic data partition"
start=133000000, size=600MiB, type=DE94BBA4-06D1-4D40-A16A-BFD50179D6AC, name="Recovery"
SF
sudo udevadm settle
sudo mkfs.vfat -F 32 -n SYSTEM ${D}-part1 >/dev/null
m=$(mktemp -d); sudo mount ${D}-part1 $m
sudo mkdir -p $m/EFI/Microsoft/Boot $m/EFI/Microsoft/Recovery $m/EFI/BOOT
for f in Boot/bootmgfw.efi Boot/bootmgr.efi Boot/BCD Boot/memtest.efi Recovery/BCD; do head -c $((200000 + RANDOM)) /dev/urandom | sudo tee $m/EFI/Microsoft/$f >/dev/null; done
{ echo WINDOWS-FALLBACK-LOADER; head -c 150000 /dev/urandom; } | sudo tee $m/EFI/BOOT/BOOTX64.EFI >/dev/null
sudo umount $m
for n in 2 3 4; do head -c 4M /dev/urandom | sudo dd of=${D}-part$n bs=1M conv=fsync status=none; done
