#!/bin/sh
# Runs as root inside an Alpine aarch64 machine (see build.sh). Usage: mkimage.sh <work dir>
# Leaves <work dir>/TinyMac.img: GPT disk, 32 MB FAT ESP (standalone GRUB) + ext4 root labelled TINYMAC.
set -eu
work=$1
src=$work/src
tmp=/var/tmp/tinymac # the VM's own disk: the shared folder can't hold suid files or device nodes
root=$tmp/rootfs
branch=v$(cut -d. -f1,2 /etc/alpine-release)
mirror=https://dl-cdn.alpinelinux.org/alpine

apk add -q e2fsprogs dosfstools mtools sfdisk grub-efi

rm -rf "$tmp" && mkdir -p "$root/etc/apk" "$root/etc/mkinitfs"
printf '%s/%s/main\n%s/%s/community\n' $mirror $branch $mirror $branch > "$root/etc/apk/repositories"
# Only what Macaroon's VM has: NVMe disk, ext4, virtio, USB keyboard/tablet.
echo 'features="base ext4 nvme virtio"' > "$root/etc/mkinitfs/mkinitfs.conf"
cp -R /etc/apk/keys "$root/etc/apk/"

apk add -q --root "$root" --initdb --no-cache \
    alpine-base linux-virt eudev doas \
    xorg-server xf86-input-libinput xinit xsetroot \
    icewm xterm xfe nedit xrdb font-dejavu spice-vdagent

# Our files: theme, session, config.
cp -R "$src/overlay/." "$root/"
chmod +x "$root/usr/local/bin/"*

chroot "$root" /bin/sh -eu <<'EOF'
adduser -D -s /bin/sh -G users mac
addgroup mac video; addgroup mac input; addgroup mac audio
passwd -d mac >/dev/null; passwd -d root >/dev/null
cp -R /etc/skel-mac/. /home/mac/ && chown -R mac:users /home/mac && rm -rf /etc/skel-mac
mkdir -p /home/mac/Shared && chown mac:users /home/mac/Shared
for s in devfs dmesg udev udev-trigger udev-settle; do rc-update add $s sysinit; done
for s in modules sysctl hostname bootmisc syslog networking; do rc-update add $s boot; done
for s in udev-postmount localmount spice-vdagentd; do rc-update add $s default; done
for s in mount-ro killprocs savecache; do rc-update add $s shutdown; done
EOF

sed -i -e 's|^tty1::.*|tty1::respawn:/usr/local/bin/tinymac-x|' -e '/^tty[2-6]::/d' "$root/etc/inittab"
cat > "$root/etc/fstab" <<'EOF'
LABEL=TINYMAC / ext4 rw,noatime 0 1
com.apple.virtio-fs.automount /home/mac/Shared virtiofs rw,nofail 0 0
EOF
rm -rf "$root/var/cache/apk/"*

# Standalone GRUB with its config embedded: finds the root by label and boots the kernel straight from it.
cat > "$tmp/grub.cfg" <<'EOF'
search --no-floppy --label --set=root TINYMAC
linux /boot/vmlinuz-virt root=LABEL=TINYMAC rootfstype=ext4 modules=ext4,nvme quiet console=tty0
initrd /boot/initramfs-virt
boot
EOF
grub-mkstandalone -O arm64-efi -o "$tmp/BOOTAA64.EFI" \
    --modules="part_gpt ext2 search search_label linux normal echo" "boot/grub/grub.cfg=$tmp/grub.cfg"

img=$work/TinyMac.img
rm -f "$img" "$tmp/esp.img" "$tmp/root.img"
mkfs.vfat -C -n ESP "$tmp/esp.img" $((32 * 1024)) >/dev/null
mmd -i "$tmp/esp.img" ::/EFI ::/EFI/BOOT
mcopy -i "$tmp/esp.img" "$tmp/BOOTAA64.EFI" ::/EFI/BOOT/BOOTAA64.EFI
truncate -s 1984M "$tmp/root.img"
mkfs.ext4 -q -L TINYMAC -d "$root" "$tmp/root.img"

# 1 MiB GPT header, 32 MiB ESP, 1984 MiB root + backup GPT.
truncate -s 2018M "$img"
sfdisk -q "$img" <<'EOF'
label: gpt
start=2048, size=65536, type=uefi, name=ESP
start=67584, size=4063232, type=linux, name=TINYMAC
EOF
dd if="$tmp/esp.img" of="$img" bs=1M seek=1 conv=notrunc status=none
dd if="$tmp/root.img" of="$img" bs=1M seek=33 conv=notrunc status=none
rm -f "$tmp/esp.img" "$tmp/root.img"
chmod 644 "$img"
