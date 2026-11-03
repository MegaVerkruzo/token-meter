#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="build/Codex Context.app"
mkdir -p "$app/Contents/MacOS" build/modules
swiftc -target "$(uname -m)-apple-macosx13.0" -O -module-cache-path build/modules Usage.swift Widget.swift -o "$app/Contents/MacOS/CodexContext"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexContext</string>
<key>CFBundleIdentifier</key><string>io.github.megaverkruzo.codex-context-widget</string>
<key>CFBundleName</key><string>Codex Context</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
