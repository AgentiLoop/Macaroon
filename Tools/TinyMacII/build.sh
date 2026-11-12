#!/bin/zsh
# Builds "NeXT Workspace.app" (NeXTSTEP Dock + vertical main menu for TinyMacII) into Macaroon's shared folder,
# where "Set Up NeXT Look.command" installs it inside the VM from /Volumes/My Shared Files.
set -euo pipefail
here=${0:A:h}
app="$HOME/Library/Application Support/Macaroon/VM/Shared/NeXT Workspace.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -target arm64-apple-macos14 "$here/NeXTWorkspace.swift" -o "$app/Contents/MacOS/NeXTWorkspace"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.macaroon.NeXTWorkspace</string>
    <key>CFBundleName</key><string>NeXT Workspace</string>
    <key>CFBundleExecutable</key><string>NeXTWorkspace</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF
codesign -s - -f "$app"
echo "Built $app"
