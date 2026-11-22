#!/bin/sh
# Write notices/rust-crates.txt: the licences of every Rust crate in the apps' shared library,
# for the app targets in about.toml. Needs cargo-about 0.9.3 (release binary from
# github.com/EmbarkStudios/cargo-about; aarch64-apple-darwin SHA-256
# 45520df8680978a6e7c4023ace0e3f311c73efc208cd68e5a7f4ed4822fa0349, x86_64-unknown-linux-musl
# 3ad1e94ea1e63d69d1961f4fb15ccbbe9575d906111f96d2cb4dce6df48f71b4).
#   scripts/notices.sh            regenerate the file
#   scripts/notices.sh --check    fail if the committed file is out of date
set -eu
cd "$(dirname "$0")/.."
cargo fetch --locked >/dev/null
OUT=notices/rust-crates.txt
[ "${1:-}" = --check ] && OUT="${TMPDIR:-/tmp}/sealctl-app-notices.$$.txt"
cargo about generate --locked --offline --fail \
  -c about.toml -m shared/Cargo.toml -o "$OUT" scripts/notices.hbs
if [ "${1:-}" = --check ]; then
  if ! diff -u notices/rust-crates.txt "$OUT"; then
    rm -f "$OUT"
    echo "notices/rust-crates.txt is out of date: run scripts/notices.sh and commit it" >&2
    exit 1
  fi
  rm -f "$OUT"
fi
