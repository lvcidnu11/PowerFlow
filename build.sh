#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) PowerFlow.app next to this script.
# Usage: ./build.sh            -> PowerFlow.app
#        ./build.sh --zip      -> also PowerFlow.zip (for releases)
set -e
cd "$(dirname "$0")"
APP=PowerFlow.app
VERSION=${VERSION:-1.0.0}
rm -rf $APP build
mkdir -p $APP/Contents/MacOS build
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macosx14.0 PowerFlow.swift -o build/PowerFlow-$arch
done
lipo -create build/PowerFlow-arm64 build/PowerFlow-x86_64 -output $APP/Contents/MacOS/PowerFlow
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
