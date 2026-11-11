#!/bin/zsh
# Builds virgl_test_server for macOS: virglrenderer 1.3.0 with macos-cgl.patch (OpenGL contexts from CGL,
# so the guest's GL runs on the Mac's GPU) and libepoxy linked in statically, then installs it where
# Macaroon looks for it: ~/Library/Application Support/Macaroon/VirGL/virgl_test_server.
# Needs: meson, ninja, pkgconf (brew install meson ninja pkgconf) and python3.
set -euo pipefail
here=${0:A:h}
work=${TMPDIR:-/tmp}/macaroon-virgl
dest="$HOME/Library/Application Support/Macaroon/VirGL"
mkdir -p "$work" "$dest"
cd "$work"

[[ -d venv ]] || { python3 -m venv venv && venv/bin/pip -q install pyyaml; }
export PATH="$work/venv/bin:$PATH"

if [[ ! -d libepoxy-1.5.10 ]]; then
    curl -fL https://github.com/anholt/libepoxy/archive/refs/tags/1.5.10.tar.gz | tar xz
fi
if [[ ! -d epoxy ]]; then
    (cd libepoxy-1.5.10 && meson setup build --prefix="$work/epoxy" --buildtype=release \
        -Ddefault_library=static -Degl=no -Dglx=no -Dx11=false -Dtests=false && ninja -C build install)
fi

if [[ ! -d virglrenderer-1.3.0 ]]; then
    curl -fL https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/1.3.0/virglrenderer-1.3.0.tar.bz2 | tar xj
    patch -d virglrenderer-1.3.0 -p1 < "$here/macos-cgl.patch"
fi
cd virglrenderer-1.3.0
[[ -d build ]] || PKG_CONFIG_PATH="$work/epoxy/lib/pkgconfig" meson setup build --buildtype=release \
    -Ddefault_library=static -Dtests=false
ninja -C build vtest/virgl_test_server
cp build/vtest/virgl_test_server "$dest/"
codesign -s - -f "$dest/virgl_test_server"
otool -L "$dest/virgl_test_server"
echo "Installed $dest/virgl_test_server"
