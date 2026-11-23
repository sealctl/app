#!/usr/bin/env bash
# Runs the Swift packages' tests in CI: built first, then `swift test` under a pseudo-terminal,
# so the test log is printed while the tests run (through a pipe it only comes at the end). A
# package whose tests still run after LIMIT seconds (default 600) prints the tests that started
# but never finished, the processes under `swift test` and every thread's stack of the test
# process (lldb, or `sample`); then it fails. A hang names its test and where it waits instead
# of holding the job.
#   ios/scripts/package-tests.sh SealCore Vault Relay Engine DesignSystem
# SWIFT_BUILD_FLAGS: extra `swift build` arguments (Command Line Tools need the Testing macro
# plugin path: -Xswiftc -plugin-path -Xswiftc <CLT>/usr/lib/swift/host/plugins/testing).
set -uo pipefail
cd "$(dirname "$0")/../Packages"
limit=${LIMIT:-600}

for p in "$@"; do
  echo "::group::$p"
  # shellcheck disable=SC2086
  (cd "$p" && swift build --build-tests ${SWIFT_BUILD_FLAGS:-}) || exit 1
  log=$(mktemp)
  (cd "$p" && exec script -q -F "$log" swift test --skip-build) </dev/null &
  pid=$!
  for ((i = 0; i < limit; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "::endgroup::"
    echo "::error::$p: tests still running after ${limit}s"
    echo "Started but not finished:"
    tr -d '\r' <"$log" | sed -E 's/\x1b\[[0-9;]*m//g' | awk '
      /Test run / { next }
      /Test .* started\./ { sub(/.*Test /, ""); sub(/ started\..*/, ""); s[$0] = 1 }
      /Test .* (passed|failed|skipped)/ { sub(/.*Test /, ""); sub(/ (passed|failed|skipped).*/, ""); delete s[$0] }
      END { for (t in s) print "  " t }'
    echo "Processes under swift test:"
    tree() { for c in $(pgrep -P "$1"); do ps -o pid=,ppid=,etime=,command= -p "$c" | cut -c1-220; tree "$c"; done; }
    tree "$pid"
    # every thread's stack (CI runners allow sudo without a password); each tool gets a minute
    for t in $(pgrep -f '[P]ackageTests|[s]wiftpm-testing-helper'); do
      echo "::group::stacks of $t"
      sudo -n perl -e 'alarm 60; exec @ARGV' lldb --batch -p "$t" -o 'thread backtrace all' -o detach 2>&1 | head -3000 ||
        sudo -n perl -e 'alarm 60; exec @ARGV' sample "$t" 2 -mayDie 2>&1 | head -3000
      echo "::endgroup::"
    done
    pkill -f '[P]ackageTests|[s]wiftpm-testing-helper'
    kill "$pid" 2>/dev/null
    exit 1
  fi
  wait "$pid"
  status=$?
  rm -f "$log"
  echo "::endgroup::"
  [ "$status" -eq 0 ] || exit "$status"
done
