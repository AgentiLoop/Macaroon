#!/bin/zsh
# Run inside the TinyMacII VM: removes the NeXTSkin tweak (Ammonia itself stays). Add --all to remove Ammonia too.
set -euo pipefail
if [ "$(id -u)" != 0 ]; then exec sudo "$0" "$@"; fi
rm -f /private/var/ammonia/core/tweaks/NeXTSkin.dylib /private/var/ammonia/core/tweaks/NeXTSkin.dylib.allowlist
if [ "${1:-}" = --all ]; then
    launchctl bootout system /Library/LaunchDaemons/com.bedtime.ammonia.plist 2>/dev/null || true
    rm -f /Library/LaunchDaemons/com.bedtime.ammonia.plist
    rm -rf /private/var/ammonia
fi
echo "Removed. Restart the VM."
