#!/bin/zsh
# Builds the NeXT skin test into Macaroon's shared folder (/Volumes/My Shared Files/NeXTSkin in the VM):
#  • the Ammonia tweak loader (MachLiberation/Ammonia, the maintained fork, pinned), built once and cached
#  • NeXTSkin.dylib (arm64 + arm64e) and its allowlist (TextEdit only for this test)
#  • "Install NeXT Skin.command" / "Remove NeXT Skin.command" to run inside the VM (SIP must be off there)
set -euo pipefail
here=${0:A:h}
shared="$HOME/Library/Application Support/Macaroon/VM/Shared"
out="$shared/NeXTSkin"
cache="$HOME/Library/Caches/Macaroon/ammonia"
commit=fe7f5f66076442cb18872d615f188e92c4a8f9a2

if [ ! -f "$cache/Build/libopener.dylib" ]; then
    rm -rf "$cache"
    git clone -q https://github.com/MachLiberation/Ammonia "$cache"
    git -C "$cache" checkout -q "$commit"
    (cd "$cache" && sh setup_frida.sh && sh compile.sh) > "$cache.log" 2>&1 || { echo "Ammonia build failed, see $cache.log"; exit 1; }
fi

rm -rf "$out"
mkdir -p "$out/core"
cp "$cache/Build/ammonia" "$cache/Build/liblibinfect.dylib" "$cache/Build/libopener.dylib" "$cache/fridagum.dylib" "$out/core/"
clang -arch arm64 -arch arm64e -dynamiclib -fobjc-arc -O2 -mmacosx-version-min=14.0 -framework AppKit \
    "$here/NeXTSkin.m" -o "$out/NeXTSkin.dylib"
echo TextEdit > "$out/NeXTSkin.dylib.allowlist"
for f in "$out"/core/* "$out/NeXTSkin.dylib"; do codesign -s - -f "$f" 2>/dev/null; done
cp "$here/Install NeXT Skin.command" "$here/Remove NeXT Skin.command" "$out/"
chmod +x "$out"/*.command
echo "Built $out"
