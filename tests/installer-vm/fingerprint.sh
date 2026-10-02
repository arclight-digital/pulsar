#!/bin/bash
# fingerprint.sh DISK -- sha256 of every ESP file and the first 4 MiB of partitions 2-4, plus the GPT entries 1-4
set -euo pipefail
D=$1; m=$(mktemp -d); sudo mount -o ro ${D}-part1 $m
(cd $m && sudo find . -type f -print0 | sort -z | xargs -0 sudo sha256sum)
sudo umount $m
for n in 2 3 4; do echo "$(sudo head -c 4M ${D}-part$n | sha256sum | cut -c1-64)  part$n"; done
sudo sfdisk -d $D | grep -E 'part[1-4] :' | sed 's/^/gpt /'
