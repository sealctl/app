#!/usr/bin/env bash
# Fails if the committed Kotlin or Swift bindings differ from what the library generates (SPEC.md 5.3).
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cargo build -q -p sealctl-app -p uniffi-bindgen
case "$(uname)" in Darwin) lib=target/debug/libsealctl_app.dylib ;; *) lib=target/debug/libsealctl_app.so ;; esac
target/debug/uniffi-bindgen generate --library "$lib" --language kotlin \
  --config uniffi-bindings.toml --out-dir "$tmp" --no-format
if ! diff -ru "$tmp/com/sealctl/core" android/core/src/main/java/com/sealctl/core; then
  echo "Kotlin bindings are out of date: run scripts/build-core-android.sh and commit them." >&2
  exit 1
fi
# The Swift bindings (scripts/build-core-ios.sh), the same way.
SWIFT_OUT="$tmp/swift" BINDINGS_ONLY=1 scripts/build-core-ios.sh >/dev/null
if ! diff -ru "$tmp/swift" ios/Packages/SealCore/Sources/SealCore; then
  echo "Swift bindings are out of date: run scripts/build-core-ios.sh and commit them." >&2
  exit 1
fi
echo "bindings up to date"
