#!/bin/zsh
# Builds GoodMouse.app (universal: Apple Silicon + Intel, ad-hoc signed) into dist/GoodMouse <version>/.
# The version comes from the VERSION file; earlier versions stay untouched.
# Needs only the Xcode Command Line Tools. For a public release, sign it afterwards with sign-and-notarize.sh.
set -e
cd "${0:A:h}"
VERSION="$(tr -d '[:space:]' < VERSION)"
swift build -c release --arch arm64
swift build -c release --arch x86_64
OUT="dist/GoodMouse $VERSION"
APP="$OUT/GoodMouse.app"

# Never replace an app that is running: a running event tap whose app file disappears loses
# its permission and can freeze mouse and keyboard input. Only this exact copy is quit.
if pgrep -f "$APP/Contents/MacOS/GoodMouse" >/dev/null; then
    pkill -TERM -f "$APP/Contents/MacOS/GoodMouse" || true
    for i in {1..20}; do pgrep -f "$APP/Contents/MacOS/GoodMouse" >/dev/null || break; sleep 0.25; done
    pkill -KILL -f "$APP/Contents/MacOS/GoodMouse" 2>/dev/null || true
    sleep 0.5
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon: Icon/make-icon.swift → 1024 px PNG → .icns (regenerated only when missing).
if [[ ! -f Icon/AppIcon.icns ]]; then
    [[ -f Icon/icon-1024.png ]] || swift Icon/make-icon.swift Icon/icon-1024.png
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s Icon/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) Icon/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o Icon/AppIcon.icns
fi
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
lipo -create .build/arm64-apple-macosx/release/GoodMouse .build/x86_64-apple-macosx/release/GoodMouse \
     -output "$APP/Contents/MacOS/GoodMouse"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.janeinhub.GoodMouse</string>
    <key>CFBundleName</key><string>GoodMouse</string>
    <key>CFBundleExecutable</key><string>GoodMouse</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 JaNeinHub · GPL-3.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - --timestamp=none "$APP"
lipo -archs "$APP/Contents/MacOS/GoodMouse"
echo "Built $APP"
