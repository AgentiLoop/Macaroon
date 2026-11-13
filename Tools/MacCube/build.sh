#!/bin/zsh
# Builds "NeXT Workspace.app" (NeXTSTEP Dock + vertical main menu for MacCube), "NeXT Calculator.app",
# "NeXT Browser.app", "NeXT Edit.app" and "NeXT Terminal.app" into Macaroon's shared folder, where "Set Up NeXT Look.command" installs
# them inside the VM from /Volumes/My Shared Files.
set -euo pipefail
here=${0:A:h}
shared="$HOME/Library/Application Support/Macaroon/VM/Shared"

# Documents NeXT Edit opens: plain text, RTF and source files
textDocuments='<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Text</string><key>CFBundleTypeRole</key><string>Editor</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>public.text</string><string>public.rtf</string></array></dict></array>'

# build <source> <app name> <executable> <bundle id> <LSUIElement true|false> [kit] [extra Info.plist keys]
# "kit": compile with NeXTKit.swift (the shared NeXT look); the app's file becomes main.swift so its top-level code runs.
build() {
    local app="$shared/$2.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    # NeXT Workspace's Dock tile (and its app icon) is the colour NeXT logo
    [ "$4" = com.macaroon.NeXTWorkspace ] && cp "$here/NeXT_logo.svg" "$app/Contents/Resources/"
    if [ "${6:-}" = kit ]; then
        local tmp=$(mktemp -d)
        cp "$here/$1" "$tmp/main.swift"
        swiftc -O -target arm64-apple-macos14 "$here/NeXTKit.swift" "$tmp/main.swift" -o "$app/Contents/MacOS/$3"
        rm -rf "$tmp"
    else
        swiftc -O -target arm64-apple-macos14 "$here/$1" -o "$app/Contents/MacOS/$3"
    fi
    # NeXT icon: drawn by NeXT Workspace (built first) exactly like its Dock tile, as AppIcon.icns
    local iconKey="" ws="$shared/NeXT Workspace.app/Contents/MacOS/NeXTWorkspace" set=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$set"
    if [ -x "$ws" ] && "$ws" --icon "$4" "$set/icon_512x512@2x.png"; then
        for s in 16 32 128 256 512; do
            sips -z $s $s "$set/icon_512x512@2x.png" --out "$set/icon_${s}x${s}.png" >/dev/null
            [ $s = 512 ] || sips -z $((s * 2)) $((s * 2)) "$set/icon_512x512@2x.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
        done
        mkdir -p "$app/Contents/Resources"
        iconutil -c icns "$set" -o "$app/Contents/Resources/AppIcon.icns" && iconKey="<key>CFBundleIconFile</key><string>AppIcon</string>"
        # macOS 26+ draws a placeholder or shrinks old-style icons onto a white plate; an Icon Composer icon
        # (AppIcon.icon: the drawing as a layer on a solid NeXT grey fill) compiled by actool fills the app shape
        local ic="${set:h}/AppIcon.icon"
        mkdir -p "$ic/Assets"
        cp "$set/icon_512x512@2x.png" "$ic/Assets/art.png"
        print -r -- '{"fill":{"solid":"srgb:0.66700,0.66700,0.66700,1.00000"},"groups":[{"layers":[{"image-name":"art.png","name":"art"}]}],"supported-platforms":{"squares":["macOS"]}}' > "$ic/icon.json"
        if xcrun actool "$ic" --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
                --app-icon AppIcon --output-partial-info-plist "${set:h}/partial.plist" >/dev/null 2>&1; then
            iconKey+="<key>CFBundleIconName</key><string>AppIcon</string>"
        else
            echo "actool failed for $2 (icns only)"
        fi
    fi
    rm -rf "${set:h}"
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
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M%S)</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><$5/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    $iconKey
    ${7:-}
</dict>
</plist>
EOF
    # A designated requirement on the identifier (not the ad-hoc hash), so permissions survive rebuilds
    codesign -s - -f -r="designated => identifier \"$4\"" "$app"
    # Finder and the Dock cache icons by path: tell them this bundle (and its icon) changed
    touch "$app"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
    echo "Built $app"
}

build NeXTWorkspace.swift "NeXT Workspace" NeXTWorkspace com.macaroon.NeXTWorkspace true
build NeXTCalculator.swift "NeXT Calculator" NeXTCalculator com.macaroon.NeXTCalculator false
build NeXTBrowser.swift "NeXT Browser" NeXTBrowser com.macaroon.NeXTBrowser false kit
build NeXTEdit.swift "NeXT Edit" NeXTEdit com.macaroon.NeXTEdit false kit "$textDocuments"
build NeXTTerminal.swift "NeXT Terminal" NeXTTerminal com.macaroon.NeXTTerminal false kit
