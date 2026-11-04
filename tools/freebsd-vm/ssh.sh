#!/bin/bash
set -euo pipefail
exec ssh -i /run/freebsd-vm/key -p 2222 \
    -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/run/freebsd-vm/known_hosts root@127.0.0.1 "$@"
