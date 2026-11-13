#!/bin/zsh
# Run inside the MacCube VM (SIP off, -arm64e_preview_abi set). Installs the Ammonia tweak loader the way its
# package does (files in /private/var/ammonia/core, a LaunchDaemon, library validation off) and the NeXTSkin
# tweak, which only loads into the apps in NeXTSkin.dylib.allowlist (TextEdit). Then restart the VM.
set -euo pipefail
src=${0:A:h}
if [ "$(id -u)" != 0 ]; then exec sudo "$0" "$@"; fi

if ! csrutil status | grep -q disabled; then echo "SIP is on: turn it off in Recovery first (see SIP-OFF-PLAN.md)."; exit 1; fi
case "$(nvram boot-args 2>/dev/null)" in *-arm64e_preview_abi*) ;; *) echo "Warning: boot-args lack -arm64e_preview_abi";; esac

core=/private/var/ammonia/core
mkdir -p "$core/tweaks" "$core/gui"
chmod 777 "$core/tweaks" "$core/gui"
cp "$src"/core/* "$core/"
cp "$src/NeXTSkin.dylib" "$src/NeXTSkin.dylib.allowlist" "$core/tweaks/"
chmod 755 "$core/ammonia"

cat > /Library/LaunchDaemons/com.bedtime.ammonia.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.bedtime.ammonia</string>
    <key>ProgramArguments</key><array><string>/private/var/ammonia/core/ammonia</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
</dict>
</plist>
EOF
defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true
launchctl bootstrap system /Library/LaunchDaemons/com.bedtime.ammonia.plist 2>/dev/null || true

echo "Installed. Restart the VM, then open TextEdit."
echo "Check:  log show --last 5m --predicate 'eventMessage CONTAINS \"NeXTSkin\"'"
