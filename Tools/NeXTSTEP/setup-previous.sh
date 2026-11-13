#!/bin/zsh
# Sets up the Previous NeXT emulator with a fresh NeXTSTEP 3.3 install (verified 2026-11-12: installs and boots
# to the Workspace as user "me").
#   ./setup-previous.sh install   build Previous (SVN trunk), blank 1 GB disk, boot the 3.3 boot floppy + user CD
#   ./setup-previous.sh run       boot the installed disk
# Network: Ethernet is connected through SLiRP (NAT), which NeXTSTEP 3.3 configures by itself, and ~/Previous/Shared
# is /Net/nfs in NeXTSTEP. Web browser: OmniWeb 2.7b3 for NeXT (m68k) is unpacked there, /Net/nfs/OmniWeb.app, from
#   http://files.omnigroup.com/software/Archive/NEXTSTEP/OmniWeb/OmniWeb-2.7b3-N.tar.gz
# Install steps in the emulator: 1 (English) → 1 (install on target 0) → 1 (start) → wait for "Completed",
# then quit Previous and run `./setup-previous.sh run`.
# Media (NeXTSTEP is Apple's; you supply it): ~/Downloads/NeXTSTEP33/{user.iso,developer.iso,3.3_Moto_Boot_Disk.img}
#   archive.org/details/nextstep3-3dev (user.iso, developer.iso), archive.org/details/NeXTSTEP33CISC (boot floppy)
set -euo pipefail
src=/tmp/prev-trunk
media="$HOME/Downloads/NeXTSTEP33"
disk="$HOME/Previous/NeXTSTEP33/HD.img"
shared="$HOME/Previous/Shared"   # /Net/nfs in NeXTSTEP (Previous' NFS server)
cfg="$HOME/Library/Application Support/Previous/previous.cfg"
app="$src/build/src/Previous.app"

if [ ! -x "$app/Contents/MacOS/Previous" ]; then
    brew list subversion sdl3 libpng >/dev/null 2>&1 || brew install subversion sdl3 libpng
    [ -d "$src" ] || svn checkout -q https://svn.code.sf.net/p/previous/code/trunk "$src"
    mkdir -p "$src/build" && cd "$src/build"
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null && make -j8 >/dev/null
fi

mode=${1:-run}
# Previous rewrites its config when it quits, so stop it fully before writing
pkill -x Previous 2>/dev/null && sleep 3; pkill -9 -x Previous 2>/dev/null || true
if [ "$mode" = install ]; then
    mkdir -p "${disk:h}" && rm -f "$disk" && mkfile -n 1g "$disk"
    boot=4 floppy=TRUE   # boot from the floppy
else
    boot=1 floppy=FALSE  # boot from SCSI disk 0
fi
mkdir -p "${cfg:h}" "$shared"
cat > "$cfg" <<EOF
[ConfigDialog]
bShowConfigDialogAtStartup = FALSE

[Boot]
nBootDevice = $boot

[HardDisk]
szImageName0 = $disk
nDeviceType0 = 1
bDiskInserted0 = TRUE
bWriteProtected0 = FALSE
szImageName1 = $media/user.iso
nDeviceType1 = 2
bDiskInserted1 = TRUE
bWriteProtected1 = TRUE
szImageName2 = $media/developer.iso
nDeviceType2 = 2
bDiskInserted2 = TRUE
bWriteProtected2 = TRUE

[Floppy]
szImageName0 = $media/3.3_Moto_Boot_Disk.img
bDriveConnected0 = TRUE
bDiskInserted0 = $floppy
bWriteProtected0 = TRUE

[Ethernet]
bEthernetConnected = TRUE
nHostInterface = 0
szNFSPathName0 = $shared
szNFSHostName0 = nfs

[System]
nMachineType = 1
nCpuLevel = 4
nCpuFreq = 25
EOF
open "$app"
