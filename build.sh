#!/bin/zsh
set -eu
cd -- "${0:A:h}"
destination="${1:-$PWD/dist}"
mkdir -p -- "$destination"
destination="${destination:A}"
build_dir="$(mktemp -d)"
trap 'rm -rf -- "$build_dir"' EXIT

bundle="$build_dir/HDD mac sentinel.app"
mkdir -p -- "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Info.plist "$bundle/Contents/Info.plist"
cp AppIcon.icns "$bundle/Contents/Resources/"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
    xcrun swiftc -target "${arch}-apple-macosx13.0" -sdk "$sdk" -O \
        -o "$build_dir/HDDMacSentinel-$arch" Sources/*.swift
done
xcrun lipo -create "$build_dir/HDDMacSentinel-arm64" "$build_dir/HDDMacSentinel-x86_64" \
    -output "$bundle/Contents/MacOS/HDDMacSentinel"
/usr/bin/codesign --force --sign - "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
/usr/bin/ditto "$bundle" "$destination/HDD mac sentinel.app"
print -r -- "$destination/HDD mac sentinel.app"
