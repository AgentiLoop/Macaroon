#!/bin/zsh
# Builds NeXTWeb, the web browser for NeXTSTEP 3.3 in Previous that shows today's web:
#   • NeXTWebServer (server.swift), its web engine on the Mac → ~/Previous/NeXTWebServer
#   • NeXTWeb.app (NeXTWeb.m), the NeXTSTEP application → ~/Previous/Shared/NeXTWeb.app, which is
#     /Net/nfs/NeXTWeb.app in NeXTSTEP. It is compiled in NeXTSTEP itself, with cc from the Developer CD
#     (/NEXTSTEP_Dev_3.3; nothing gets installed), so NeXTSTEP has to be running: ../setup-previous.sh run
# ./build.sh server builds only the first.
set -euo pipefail
here=${0:A:h}
shared="$HOME/Previous/Shared"

swiftc -O "$here/server.swift" -o "$HOME/Previous/NeXTWebServer"
echo "Built $HOME/Previous/NeXTWebServer"
[ "${1:-}" = server ] && exit

mkdir -p "$shared/NeXTWeb.app" "$shared/.nxsh"
cp "$here/NeXTWeb.m" "$shared/.nxsh/NeXTWeb.m"
# cc's own driver for the assembler looks only in /lib, so the steps are run one by one from the CD
"$here/../nxsh.py" -t 900 '
D=/NEXTSTEP_Dev_3.3
H=$D/NextDeveloper/Headers
cd /Net/nfs/.nxsh || exit 1
$D/bin/cc -B$D/lib/ -Wno-precomp -nostdinc -I$H -I$H/ansi -I$H/bsd -O -S -o /tmp/NeXTWeb.s NeXTWeb.m || exit 1
$D/lib/m68k/as -o /tmp/NeXTWeb.o /tmp/NeXTWeb.s || exit 1
$D/bin/ld -o /tmp/NeXTWeb $D/lib/crt0.o /tmp/NeXTWeb.o -L$D/lib -L$D/usr/lib -lNeXT_s -lsys_s || exit 1
cp /tmp/NeXTWeb /Net/nfs/NeXTWeb.app/NeXTWeb.new && mv /Net/nfs/NeXTWeb.app/NeXTWeb.new /Net/nfs/NeXTWeb.app/NeXTWeb
'
echo "Built $shared/NeXTWeb.app"
