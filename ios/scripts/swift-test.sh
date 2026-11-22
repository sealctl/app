#!/usr/bin/env bash
# Runs a package's unit tests on this Mac with `swift test` (SealCore, Relay, Vault, Engine).
# The Relay and Engine suites need the fake relay and fake machine:
#   cargo build --release -p fake-relay -p fake-machine
#   target/release/fake-relay &
#   SEALCTL_TEST_RELAY=http://127.0.0.1:8787 FAKE_MACHINE_BIN=$PWD/target/release/fake-machine ios/scripts/swift-test.sh Engine
# Command Line Tools builds sometimes lose the Testing macro plugin on an incremental build;
# the test intermediates are removed and the build retried.
set -uo pipefail
pkg=$1; shift
cd "$(dirname "$0")/../Packages/$pkg"
log=$(mktemp)
for attempt in 1 2 3; do
  swift test "$@" >"$log" 2>&1
  status=$?
  if grep -q "plugin for module 'TestingMacros' not found" "$log"; then
    rm -rf .build
    continue
  fi
  break
done
grep -v 'ld: warning' "$log"
rm -f "$log"
exit $status
