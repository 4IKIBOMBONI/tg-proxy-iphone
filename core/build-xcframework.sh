#!/usr/bin/env bash
#
# Builds the Go proxy core (tg-ws-proxy.go + ios_bridge.go) into a multi-arch
# XCFramework that the Xcode project links against.
#
# Output: build/TgWsProxyCore.xcframework
#
# The Go core exposes a plain C API via //export directives (StartProxy,
# StopProxy, GetStats, GetLogs, ...), so we compile it with
# `-buildmode=c-archive` for each Apple slice and bundle the static archives
# with their generated header into an XCFramework. No gomobile bind is needed
# because the surface is already C.
#
# Requirements (run on macOS):
#   - Xcode + command line tools (xcrun, xcodebuild, lipo)
#   - Go >= 1.21 (go.mod targets 1.26; CGO_ENABLED=1)
#
set -euo pipefail

cd "$(dirname "$0")"

MIN_IOS="15.0"
OUT_DIR="build"
FRAMEWORK_NAME="TgWsProxyCore"
LIB_NAME="libtgwsproxy.a"
HEADER_NAME="libtgwsproxy.h"

if ! command -v go >/dev/null 2>&1; then
  echo "error: go toolchain not found in PATH" >&2
  exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found — run this on macOS with Xcode installed" >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# build_slice <name> <GOARCH> <sdk> <min-flag>
build_slice() {
  local name="$1" goarch="$2" sdk="$3" minflag="$4"
  local dir="$OUT_DIR/$name"
  mkdir -p "$dir"

  # clang uses different arch names than Go's GOARCH (amd64 -> x86_64).
  local clangarch="$goarch"
  [ "$goarch" = "amd64" ] && clangarch="x86_64"

  local sdk_path clang
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  clang="$(xcrun --sdk "$sdk" --find clang)"

  echo ">> building slice: $name (GOARCH=$goarch sdk=$sdk)"
  CGO_ENABLED=1 \
  GOOS=ios \
  GOARCH="$goarch" \
  CGO_CFLAGS="-isysroot $sdk_path -arch $clangarch $minflag" \
  CGO_LDFLAGS="-isysroot $sdk_path -arch $clangarch $minflag" \
  CC="$clang" \
    go build -buildmode=c-archive -tags ios \
      -o "$dir/$LIB_NAME" .
}

# Device (arm64, iphoneos)
build_slice "ios-arm64" "arm64" "iphoneos" "-mios-version-min=$MIN_IOS"

# Simulator arm64 (Apple Silicon Macs) — required.
build_slice "sim-arm64" "arm64" "iphonesimulator" "-mios-simulator-version-min=$MIN_IOS"

# Simulator x86_64 (Intel Macs) — optional. Skip with BUILD_SIM_X86=0, and
# don't fail the whole build if this slice can't compile.
SIM_X86_OK=0
if [ "${BUILD_SIM_X86:-1}" = "1" ]; then
  if build_slice "sim-amd64" "amd64" "iphonesimulator" "-mios-simulator-version-min=$MIN_IOS"; then
    SIM_X86_OK=1
  else
    echo ">> warning: x86_64 simulator slice failed — building arm64-only simulator" >&2
  fi
fi

# Fat simulator archive
SIM_DIR="$OUT_DIR/ios-simulator"
mkdir -p "$SIM_DIR"
if [ "$SIM_X86_OK" = "1" ]; then
  lipo -create \
    "$OUT_DIR/sim-arm64/$LIB_NAME" \
    "$OUT_DIR/sim-amd64/$LIB_NAME" \
    -output "$SIM_DIR/$LIB_NAME"
else
  cp "$OUT_DIR/sim-arm64/$LIB_NAME" "$SIM_DIR/$LIB_NAME"
fi
# header is identical across slices
cp "$OUT_DIR/sim-arm64/$HEADER_NAME" "$SIM_DIR/$HEADER_NAME"

# Lay out per-slice headers in their own include dir (xcframework requirement)
prepare_headers() {
  local dir="$1"
  mkdir -p "$dir/include"
  cp "$dir/$HEADER_NAME" "$dir/include/$HEADER_NAME"
}
prepare_headers "$OUT_DIR/ios-arm64"
prepare_headers "$SIM_DIR"

# Assemble the XCFramework
rm -rf "$OUT_DIR/$FRAMEWORK_NAME.xcframework"
xcodebuild -create-xcframework \
  -library "$OUT_DIR/ios-arm64/$LIB_NAME"     -headers "$OUT_DIR/ios-arm64/include" \
  -library "$SIM_DIR/$LIB_NAME"               -headers "$SIM_DIR/include" \
  -output "$OUT_DIR/$FRAMEWORK_NAME.xcframework"

echo
echo "✅ built $OUT_DIR/$FRAMEWORK_NAME.xcframework"
echo "   link it from the app + tunnel targets (see TgWsProxy/project.yml)."
