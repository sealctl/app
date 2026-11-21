#!/usr/bin/env bash
# Builds libsealctl_app.so (sealctl-core + sealctl-app) for each Android ABI into
# android/core/src/main/jniLibs and regenerates the Kotlin bindings (SPEC.md 5.3).
#
#   ABIS="arm64-v8a x86_64" scripts/build-core-android.sh   # a subset of ABIs
#   BINDINGS_ONLY=1 scripts/build-core-android.sh           # regenerate Kotlin only
set -euo pipefail
cd "$(dirname "$0")/.."

ABIS=${ABIS:-"arm64-v8a armeabi-v7a x86_64"}
PROFILE=${PROFILE:-release}
SDK=${ANDROID_HOME:-$HOME/Library/Android/sdk}
export ANDROID_NDK_HOME=${ANDROID_NDK_HOME:-$(ls -d "$SDK"/ndk/* | sort -V | tail -1)}
JNI=android/core/src/main/jniLibs
KOTLIN=android/core/src/main/java

targets=()
for abi in $ABIS; do targets+=(-t "$abi"); done

if [ -z "${BINDINGS_ONLY:-}" ]; then
  cargo ndk "${targets[@]}" --platform 28 -o "$JNI" build --profile "$PROFILE" -p sealctl-app
fi

# Bindings come from the library itself (UniFFI library mode). Release libraries are
# stripped of the metadata symbols, so the bindings are read from an unstripped host build of
# the same sources.
cargo build -q -p sealctl-app -p uniffi-bindgen
case "$(uname)" in Darwin) lib=target/debug/libsealctl_app.dylib ;; *) lib=target/debug/libsealctl_app.so ;; esac
rm -rf "$KOTLIN/com/sealctl/core"
target/debug/uniffi-bindgen generate --library "$lib" --language kotlin \
  --config uniffi-bindings.toml --out-dir "$KOTLIN" --no-format
find "$JNI" -name "libsealctl_core-*.so" -delete
echo "built: $ABIS -> $JNI; bindings -> $KOTLIN/com/sealctl/core"
