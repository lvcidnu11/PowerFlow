#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) PowerFlow.app next to this script.
# Usage: ./build.sh            -> PowerFlow.app
#        ./build.sh --zip      -> also PowerFlow.zip (for releases)
set -e
cd "$(dirname "$0")"
APP=PowerFlow.app
VERSION=${VERSION:-1.2.0}
rm -rf $APP build
mkdir -p $APP/Contents/MacOS build
for arch in arm64 x86_64; do
  swiftc -O -wmo -Xlinker -dead_strip -target $arch-apple-macosx14.0 PowerFlow.swift -o build/PowerFlow-$arch
done
lipo -create build/PowerFlow-arm64 build/PowerFlow-x86_64 -output $APP/Contents/MacOS/PowerFlow
strip -x $APP/Contents/MacOS/PowerFlow
mkdir -p $APP/Contents/Resources
# Icon: light/dark-aware Icon Composer icon when Xcode's actool is available, else plain .icns
ICON_NAME_KEY=""
if xcrun --find actool >/dev/null 2>&1 && \
   xcrun actool "$PWD/icon/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
     --minimum-deployment-target 14.0 --app-icon AppIcon \
     --output-partial-info-plist "$PWD/build/icon.plist" >/dev/null 2>&1 && \
   [[ -f $APP/Contents/Resources/Assets.car ]]; then
  ICON_NAME_KEY="<key>CFBundleIconName</key><string>AppIcon</string>"
else
  echo "note: actool (Xcode 26+) unavailable — using static icon"
  rm -f $APP/Contents/Resources/Assets.car
  cp icon/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
fi
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>PowerFlow</string>
<key>CFBundleIdentifier</key><string>io.github.powerflow</string>
<key>CFBundleExecutable</key><string>PowerFlow</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
$ICON_NAME_KEY
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force -s - $APP
if [[ "$1" == "--zip" ]]; then
  rm -f PowerFlow.zip
  ditto -c -k --keepParent $APP PowerFlow.zip
  echo "Built $PWD/PowerFlow.zip"
fi
echo "Built $PWD/$APP"
