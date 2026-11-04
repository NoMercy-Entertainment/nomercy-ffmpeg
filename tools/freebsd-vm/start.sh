#!/bin/bash
# A real FreeBSD kernel under QEMU TCG, contained entirely in a Linux container.
set -euo pipefail

readonly IMAGE=FreeBSD-14.3-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz
readonly IMAGE_SHA256=002e4ba15a5af021f9765f85c19e03edae396ea83306671a7484659d5fd9da69
readonly IMAGE_URL=https://archive.freebsd.org/old-releases/VM-IMAGES/14.3-RELEASE/amd64/Latest
readonly WORK=/work
readonly STATE=/run/freebsd-vm
mkdir -p "$WORK" "$STATE"
rm -f "$STATE/ready"
: >"$STATE/known_hosts"

# Check the pinned digest against the official manifest and against the image.
curl --fail --location --retry 3 --connect-timeout 15 --max-time 120 \
    "$IMAGE_URL/CHECKSUM.SHA256" -o "$STATE/CHECKSUM.SHA256"
grep -Fqx "SHA256 ($IMAGE) = $IMAGE_SHA256" "$STATE/CHECKSUM.SHA256"
if [[ ! -f "$WORK/$IMAGE" ]]; then
    echo "Downloading official FreeBSD image (~836 MiB compressed)"
    curl --fail --location --retry 3 --connect-timeout 15 --max-time 1200 \
        "$IMAGE_URL/$IMAGE" -o "$WORK/$IMAGE.part"
    printf '%s  %s\n' "$IMAGE_SHA256" "$WORK/$IMAGE.part" | sha256sum --check -
    mv "$WORK/$IMAGE.part" "$WORK/$IMAGE"
fi
printf '%s  %s\n' "$IMAGE_SHA256" "$WORK/$IMAGE" | sha256sum --check -

readonly BASE="$WORK/freebsd-14.3-base.qcow2"
if [[ ! -f "$BASE" ]]; then
    echo 'Decompressing the verified base image'
    xz --decompress --stdout "$WORK/$IMAGE" >"$BASE.part"
    qemu-img check "$BASE.part"
    mv "$BASE.part" "$BASE"
fi
overlay_stamp=$(date +%s)
readonly OVERLAY="$WORK/guest-$overlay_stamp-$$.qcow2"
qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$OVERLAY"

# The private key lives only inside the container, never in the host bind mount.
if [[ ! -f "$STATE/key" ]]; then
    ssh-keygen -q -t ed25519 -N '' -f "$STATE/key"
fi
pubkey=$(cat "$STATE/key.pub")
mkdir -p "$STATE/seed"
printf 'instance-id: nomercy-freebsd-validation\nlocal-hostname: nm-freebsd-vm\n' >"$STATE/seed/meta-data"
cat >"$STATE/seed/user-data" <<EOF
#!/bin/sh
set -eu
mkdir -p /root/.ssh
chmod 700 /root/.ssh
printf '%s\n' '$pubkey' >/root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
pw usermod root -w none
sysrc sshd_enable=YES ifconfig_vtnet0=DHCP firstboot_freebsd_update_enable=NO
# rc.conf can already be cached by the parent boot shell at this point.
# Replace this disposable guest's firstboot updater before rc executes it.
if [ -f /usr/local/etc/rc.d/firstboot_freebsd_update ]; then
    printf '#!/bin/sh\n# Disabled in the disposable validation guest.\n' >/usr/local/etc/rc.d/firstboot_freebsd_update
fi
sed -i '' '/^PermitRootLogin /d; /^PasswordAuthentication /d; /^KbdInteractiveAuthentication /d' /etc/ssh/sshd_config
printf '\nPermitRootLogin prohibit-password\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' >>/etc/ssh/sshd_config
echo 'NoMercy cloud configuration ready' >/dev/console
EOF
chmod +x "$STATE/seed/user-data"
xorriso -as mkisofs -quiet -volid cidata -joliet -rock \
    -output "$STATE/cidata.iso" "$STATE/seed"

qemu-system-x86_64 -machine pc -accel tcg,thread=multi -cpu qemu64 -smp 2 -m 2048 \
    -drive "file=$OVERLAY,if=virtio,format=qcow2" \
    -drive "file=$STATE/cidata.iso,media=cdrom,readonly=on" \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
    -device virtio-net-pci,netdev=net0,romfile= \
    -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
    -rtc base=utc,driftfix=slew -display none -serial "file:$WORK/serial.log" \
    -monitor "unix:$STATE/monitor.sock,server=on,wait=off" -no-reboot &
qemu_pid=$!
cleanup() {
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

ready=0
deadline=$((SECONDS + 900))
while ((SECONDS < deadline)); do
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        echo 'FreeBSD VM exited before SSH became ready; see /work/serial.log' >&2
        exit 1
    fi
    if /tools/ssh.sh true 2>/dev/null; then
        ready=1
        break
    fi
    sleep 5
done
if [[ "$ready" != 1 ]]; then
    echo 'Timed out waiting for FreeBSD SSH; see /work/serial.log' >&2
    exit 1
fi
/tools/ssh.sh 'uname -a; freebsd-version -kru' | tee "$WORK/guest-version.txt"
touch "$STATE/ready"
echo 'FreeBSD VM ready. Use docker exec <container> /tools/ssh.sh <command>.'
wait "$qemu_pid"
