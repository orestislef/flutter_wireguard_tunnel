#!/bin/sh
# Rebuilds WireGuardKitGo.xcframework (libwg-go.a, the WireGuard engine the
# tunnel extension links against). Only needed when bumping WireGuard, the
# xcframework is shipped prebuilt so apps build without Go.
# Runs on a Mac with Xcode. Go and wireguard-apple stay in a temp folder.
set -eu

GO_VERSION=1.26.10
GO_SHA256=0b5183492292ada170f9b561a834863808dd02edba599e4ad0e89899330020b3
WG_COMMIT=2fec12a6e1f6e3460b6ee483aa00ad29cddadab1 # tag 1.0.16-27
MIN_IOS=16.0

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/WireGuardKitGo.xcframework"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK"; rm -rf "$WORK"' EXIT

cd "$WORK"
curl -sSfLO "https://go.dev/dl/go$GO_VERSION.darwin-arm64.tar.gz"
echo "$GO_SHA256  go$GO_VERSION.darwin-arm64.tar.gz" | shasum -a 256 -c -
tar xzf "go$GO_VERSION.darwin-arm64.tar.gz"
export PATH="$WORK/go/bin:$PATH"

git clone -q https://github.com/WireGuard/wireguard-apple.git
git -C wireguard-apple checkout -q "$WG_COMMIT"
cd wireguard-apple/Sources/WireGuardKitGo

build() { # platform, archs, clang version flag, version env
  make PLATFORM_NAME="$1" ARCHS="$2" \
    SDKROOT="$(xcrun --sdk "$1" --show-sdk-path)" \
    GOOS_iphonesimulator=ios \
    DEPLOYMENT_TARGET_CLANG_FLAG_NAME="$3" \
    DEPLOYMENT_TARGET_CLANG_ENV_NAME="$4" \
    "$4=$MIN_IOS" \
    CONFIGURATION_BUILD_DIR="$WORK/lib/$1" \
    CONFIGURATION_TEMP_DIR="$WORK/tmp-$1" \
    build
}

build iphoneos arm64 miphoneos-version-min IPHONEOS_DEPLOYMENT_TARGET
build iphonesimulator "arm64 x86_64" mios-simulator-version-min IOS_SIMULATOR_DEPLOYMENT_TARGET
lipo -info "$WORK/lib/iphoneos/libwg-go.a" "$WORK/lib/iphonesimulator/libwg-go.a"

mkdir -p "$WORK/headers"
cp wireguard.h "$WORK/headers/"
# Includes sys/types.h itself, newer SDKs no longer pull it in.
grep -q 'sys/types.h' "$WORK/headers/wireguard.h" ||
  sed -i '' 's|#include <stdint.h>|#include <sys/types.h>\n#include <stdint.h>|' "$WORK/headers/wireguard.h"
cat > "$WORK/headers/module.modulemap" <<'EOF'
module WireGuardKitGo {
    umbrella header "wireguard.h"
    export *
}
EOF

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$WORK/lib/iphoneos/libwg-go.a" -headers "$WORK/headers" \
  -library "$WORK/lib/iphonesimulator/libwg-go.a" -headers "$WORK/headers" \
  -output "$OUT"
du -sh "$OUT"
echo "WireGuardKitGo.xcframework built"
