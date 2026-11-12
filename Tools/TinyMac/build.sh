#!/bin/zsh
# Builds TinyMac: a tiny Alpine Linux (arm64) with a Mac OS 8 "Platinum" look (IceWM + Xfe), made only for
# Macaroon's EFI VM. Output: ~/Library/Application Support/Macaroon/TinyMac/TinyMac.img (raw GPT disk:
# FAT ESP with a standalone GRUB, ext4 root labelled TINYMAC).
# Needs Lima (brew install lima). The image is assembled inside a small Alpine Lima VM, "macaroon-tinymac".
set -euo pipefail
here=${0:A:h}
work=/tmp/tinymac-out
dest="$HOME/Library/Application Support/Macaroon/TinyMac"
vm=macaroon-tinymac
mkdir -p "$work" "$dest"

if ! limactl list -q 2>/dev/null | grep -qx $vm; then
    limactl start --name=$vm --tty=false --cpus=4 --memory=4 --mount-writable --mount="$work" template:alpine
elif [[ $(limactl list --format '{{.Status}}' $vm) != Running ]]; then
    limactl start $vm
fi

rm -rf "$work/src" && cp -R "$here" "$work/src"
limactl shell --workdir / $vm sudo sh "$work/src/mkimage.sh" "$work"
mv -f "$work/TinyMac.img" "$dest/TinyMac.img"
ls -lh "$dest/TinyMac.img"
echo "Built $dest/TinyMac.img"
