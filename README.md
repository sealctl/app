# sealctl app

The sealctl phone app: it holds the root made from your 24 words and approves your computers'
requests for keys. API keys, SSH and git signing keys, encrypted volumes and backups, unlocked from your phone: once per work session or on every use. Your AI agents use the key without seeing it. This repository has the iPhone app (Swift, SwiftUI), the Android app (Kotlin,
Jetpack Compose) and the Rust crate both apps share. [`SPEC.md`](SPEC.md) is the build spec.

To install the app on your phone, see [sealctl.com/docs#install](https://sealctl.com/docs#install).

License: AGPL-3.0. The protocol core, `sealctl-core`, is MIT and lives in
[sealctl/sealctl](https://github.com/sealctl/sealctl).

Contributions: issues and security reports are welcome; code pull requests are not accepted
for now. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Layout

| Path | What |
| --- | --- |
| `shared/` | `sealctl-app` (Rust): state, merge, levels of asking (`decide`), days, places, lifetimes, card checks, the SQLite store |
| `tools/fake-relay/` | In-memory Relay API with `/test/` controls, for tests |
| `tools/fake-machine/` | A command-line machine: pairs and sends every request kind with `sealctl-core` |
| `scripts/` | `build-core-ios.sh` (XCFramework and Swift bindings), `build-core-android.sh` (the `.so` files and Kotlin bindings), `check-core.sh` |
| `ios/` | XcodeGen project (`project.yml`): the app, the Notification Service Extension, UI tests; packages `SealCore`, `Vault`, `Relay`, `Places`, `Engine`, `DesignSystem` |
| `android/` | Gradle project: `app`, `core`, `vault`, `relay`, `places`, `notify`, `designsystem` |
| `brand/` | Icon, marks and tokens from the brand kit |

## Build

Rust (pinned in `rust-toolchain.toml`) with the Android targets, `cargo-ndk`, the Android SDK
with NDK 27, and JDK 17 or later.

```sh
cargo test --workspace                 # Rust tests
scripts/build-core-android.sh          # libsealctl_app.so for arm64-v8a, armeabi-v7a, x86_64 + bindings
cd android && ./gradlew assembleDebug lint test
```

Build settings go in `android/local.properties`, which is not committed:

| Key | Default | Use |
| --- | --- | --- |
| `sealctl.relayUrl` | `https://relay.sealctl.com` | The relay this build talks to (point it at a staging relay for testing) |
| `sealctl.testDelaySecs` | `0` | Debug builds only: shortens the level 3 delay for tests |

Push needs the Firebase app configuration at `android/app/google-services.json`, written at
build time and never committed (SPEC.md 17.2). Without it the app builds with push turned off.

## iPhone

Xcode 26 or later, XcodeGen (`brew install xcodegen`), and the Rust toolchain above.

```sh
scripts/build-core-ios.sh              # SealctlFFI.xcframework (iPhone, simulator, macOS) + Swift bindings
cd ios && xcodegen generate            # sealctl.xcodeproj (not committed)
xcodebuild test -project sealctl.xcodeproj -scheme sealctl -destination 'platform=iOS Simulator,name=iPhone 17'
```

To run the app on your own iPhone or iPad with a free (personal) Apple developer team, connect
it and run `scripts/install-ios-personal.sh <team-id> <device-udid>`. It builds
`ios/project-personal.yml` (bundle id `com.sealctl.app.personal`), which has no push, no Time
Sensitive notifications, no Notification Service Extension, no sealctl.com links and no app
group, because a personal team cannot sign them: requests appear while the app is open. A free
team's install expires after 7 days; run the script again to renew it.

The packages' unit tests also run on a Mac without the simulator (`ios/scripts/swift-test.sh
<Package>`); the Relay and Engine tests then talk to the fake relay and fake machine:

```sh
cargo build --release -p fake-relay -p fake-machine
target/release/fake-relay &
SEALCTL_TEST_RELAY=http://127.0.0.1:8787 FAKE_MACHINE_BIN=$PWD/target/release/fake-machine ios/scripts/swift-test.sh Engine
```

The Engine timing tests start a fake relay of their own on a free loopback port, with its clock
and failures set per test; they need only the two binaries:

```sh
FAKE_RELAY_BIN=$PWD/target/release/fake-relay FAKE_MACHINE_BIN=$PWD/target/release/fake-machine \
  ios/scripts/swift-test.sh Engine --filter Timing
```

The UI tests (scheme `sealctlUITests`) drive the app on a simulator with Face ID enrolled. They
need the fake relay and `ios/scripts/harness.py`, which runs the fake machine (and, with
`SEALCTL_BIN`, the real `sealctl` CLI in a temporary HOME) for them and sends pushes with
`xcrun simctl push`. `.github/workflows/ios.yml` runs all of it.

Build settings go in `ios/Config/Local.xcconfig`, which is not committed:

| Setting | Default | Use |
| --- | --- | --- |
| `SEALCTL_RELAY_URL` | `https://relay.sealctl.com` | The relay this build talks to (write `https:/$()/host`) |
| `SEALCTL_TEST_DELAY_SECS` | `0` | Debug builds only: shortens the level 3 delay for tests |

Debug builds also take `SEALCTL_RELAY` and `SEALCTL_TEST_DELAY` from the launch environment and
`-resetForTests` as a launch argument (used by the UI tests). There is no biometric bypass in any
build: the UI tests match Face ID through the simulator's own BiometricKit notifications.

Without an Apple developer account the app runs on the simulator only: no device builds, no
APNs (pushes are delivered with `xcrun simctl push`), no iCloud Keychain sync, no universal links
(the app also opens `sealctl://p#<payload>`).

## Test against the fake relay

```sh
cargo run --release -p fake-relay &                      # 127.0.0.1:8787
adb reverse tcp:8787 tcp:8787
adb shell run-as com.sealctl.app sh -c 'echo http://127.0.0.1:8787 > no_backup/relay-override.txt'   # debug builds only
export SEALCTL_RELAY=http://127.0.0.1:8787 FAKE_MACHINE_HOME=/tmp/m1
cargo run --release -p fake-machine -- pair --name dev@mbp.example.com
cargo run --release -p fake-machine -- request --kind open --subject secret:OPENAI_API_KEY --new-key secrets:store-1
adb shell am broadcast -n com.sealctl.app/.DebugPushReceiver --es type request   # stands in for FCM (debug builds)
```

## sealctl-core version

`Cargo.toml` takes `sealctl-core` from [sealctl/sealctl](https://github.com/sealctl/sealctl) as a
git dependency and `Cargo.lock` pins the exact commit (SPEC.md 5.2). `CHANGELOG.md` names the
commit each build uses.
