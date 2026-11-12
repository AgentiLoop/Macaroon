#!/bin/zsh
# Builds "NeXT Workspace.app" (NeXTSTEP Dock + vertical main menu for TinyMacII), "NeXT Calculator.app" and
# "NeXT Browser.app" into Macaroon's shared folder, where "Set Up NeXT Look.command" installs them inside the VM from /Volumes/My Shared Files.
set -euo pipefail
here=${0:A:h}
shared="$HOME/Library/Application Support/Macaroon/VM/Shared"

# build <source> <app name> <executable> <bundle id> <LSUIElement true|false>
build() {
    local app="$shared/$2.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    swiftc -O -target arm64-apple-macos14 "$here/$1" -o "$app/Contents/MacOS/$3"
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$4</string>
    <key>CFBundleName</key><string>$2</string>
    <key>CFBundleExecutable</key><string>$3</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><$5/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF
    # A designated requirement on the identifier (not the ad-hoc hash), so permissions survive rebuilds
    codesign -s - -f -r="designated => identifier \"$4\"" "$app"
    echo "Built $app"
}

build NeXTWorkspace.swift "NeXT Workspace" NeXTWorkspace com.macaroon.NeXTWorkspace true
build NeXTCalculator.swift "NeXT Calculator" NeXTCalculator com.macaroon.NeXTCalculator false
build NeXTBrowser.swift "NeXT Browser" NeXTBrowser com.macaroon.NeXTBrowser false
