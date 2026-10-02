#!/bin/sh
exec ssh -q -i ${BENCH:-/var/tmp/pulsar-installer-vm}/id -p 2222 -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 tester@127.0.0.1 "$@"
