#!/usr/bin/env bash
# Builds SealctlFFI.xcframework (sealctl-core + sealctl-app as static libraries) and regenerates
# the Swift bindings into ios/Packages/SealCore (SPEC.md 5.3).
#
#   scripts/build-core-ios.sh                      # iPhone, simulator (arm64 + x86_64) and macOS
#   PLATFORMS="sim macos" scripts/build-core-ios.sh  # a subset: ios, sim, macos
#   BINDINGS_ONLY=1 scripts/build-core-ios.sh        # regenerate the Swift only
#   SWIFT_OUT=<dir> BINDINGS_ONLY=1 ...              # write the Swift elsewhere (check-core.sh)
#
# The macOS slice is not shipped; it lets the Swift packages run their unit tests with
# `swift test` on a Mac. The XCFramework is assembled by hand (Info.plist and slices), so it
# builds the same with or without xcodebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORMS=${PLATFORMS:-"ios sim macos"}
PROFILE=${PROFILE:-release}
PKG=ios/Packages/SealCore
SWIFT=${SWIFT_OUT:-"$PKG/Sources/SealCore"}
XCF="$PKG/SealctlFFI.xcframework"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0

out_dir() { if [ "$PROFILE" = dev ]; then echo debug; else echo "$PROFILE"; fi; }

# ---- Swift bindings (UniFFI library mode, from an unstripped host build) ----
cargo build -q -p sealctl-app -p uniffi-bindgen
case "$(uname)" in Darwin) hostlib=target/debug/libsealctl_app.dylib ;; *) hostlib=target/debug/libsealctl_app.so ;; esac
gen=$(mktemp -d)
trap 'rm -rf "$gen"' EXIT
target/debug/uniffi-bindgen generate --library "$hostlib" --language swift --out-dir "$gen" --no-format
mkdir -p "$SWIFT"
rm -f "$SWIFT"/sealctl_*.swift
# One C module for both crates, so both Swift files share one RustBuffer type.
for f in sealctl_core sealctl_app; do
  sed -e "s/^#if canImport(${f}FFI)$/#if canImport(SealctlFFI)/" \
      -e "s/^import ${f}FFI$/import SealctlFFI/" "$gen/$f.swift" > "$SWIFT/$f.swift"
done
headers="$gen/headers"
mkdir -p "$headers"
cp "$gen"/sealctl_coreFFI.h "$gen"/sealctl_appFFI.h "$headers/"
cat > "$headers/module.modulemap" <<'EOF'
module SealctlFFI {
    header "sealctl_coreFFI.h"
    header "sealctl_appFFI.h"
    export *
}
EOF
if [ -n "${BINDINGS_ONLY:-}" ]; then
  echo "bindings -> $SWIFT"
  exit 0
fi

# ---- static libraries ----
need=()
for p in $PLATFORMS; do
  case $p in
    ios) need+=(aarch64-apple-ios) ;;
    sim) need+=(aarch64-apple-ios-sim x86_64-apple-ios) ;;
    macos) need+=(aarch64-apple-darwin) ;;
    *) echo "unknown platform $p" >&2; exit 2 ;;
  esac
done
installed=$(rustup target list --installed)
for t in "${need[@]}"; do
  grep -qx "$t" <<<"$installed" || rustup target add "$t"
done
for t in "${need[@]}"; do
  cargo build -q --profile "$PROFILE" -p sealctl-app --target "$t"
done
lib() { echo "target/$1/$(out_dir)/libsealctl_app.a"; }

rm -rf "$XCF"
mkdir -p "$XCF"
entries=""
slice() { # id platform variant archs libpath...
  local id=$1 platform=$2 variant=$3 archs=$4; shift 4
  mkdir -p "$XCF/$id/Headers"
  cp "$headers"/* "$XCF/$id/Headers/"
  if [ $# -gt 1 ]; then lipo -create "$@" -output "$XCF/$id/libsealctl_app.a"; else cp "$1" "$XCF/$id/libsealctl_app.a"; fi
  local arch_xml="" a
  for a in $archs; do arch_xml+="<string>$a</string>"; done
  local variant_xml=""
  [ -n "$variant" ] && variant_xml="<key>SupportedPlatformVariant</key><string>$variant</string>"
  entries+="<dict><key>BinaryPath</key><string>libsealctl_app.a</string><key>HeadersPath</key><string>Headers</string><key>LibraryIdentifier</key><string>$id</string><key>LibraryPath</key><string>libsealctl_app.a</string><key>SupportedArchitectures</key><array>$arch_xml</array><key>SupportedPlatform</key><string>$platform</string>$variant_xml</dict>"
}
for p in $PLATFORMS; do
  case $p in
    ios) slice ios-arm64 ios "" arm64 "$(lib aarch64-apple-ios)" ;;
    sim) slice ios-arm64_x86_64-simulator ios simulator "arm64 x86_64" "$(lib aarch64-apple-ios-sim)" "$(lib x86_64-apple-ios)" ;;
    macos) slice macos-arm64 macos "" arm64 "$(lib aarch64-apple-darwin)" ;;
  esac
done
cat > "$XCF/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>AvailableLibraries</key><array>$entries</array><key>CFBundlePackageType</key><string>XFWK</string><key>XCFrameworkFormatVersion</key><string>1.0</string></dict></plist>
EOF
echo "built: $PLATFORMS -> $XCF; bindings -> $SWIFT"
