# sealctl app

The sealctl phone app: it holds the root made from your 24 words and answers key requests from
your computers. This repository has the Android app (Kotlin, Jetpack Compose) and the Rust crate
both apps share. The iPhone app follows. [`SPEC.md`](SPEC.md) is the build spec.

License: AGPL-3.0. The protocol core, `sealctl-core`, is MIT and lives in
[sealctl/sealctl](https://github.com/sealctl/sealctl).

## Layout

| Path | What |
| --- | --- |
| `shared/` | `sealctl-app` (Rust): state, merge, levels of asking (`decide`), days, places, lifetimes, card checks, the SQLite store |
| `tools/fake-relay/` | In-memory Relay API with `/test/` controls, for tests |
| `tools/fake-machine/` | A command-line machine: pairs and sends every request kind with `sealctl-core` |
| `scripts/` | `build-core-android.sh` (the `.so` files and Kotlin bindings), `check-core.sh` |
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

## Pre-release exception

SPEC.md 5.2 pins `sealctl-core` to a `sealctl` release tag. No release contains the core yet, so
`Cargo.toml` takes it from the `phone` branch and `Cargo.lock` pins the commit. This changes to
`tag = "v0.7.0"` when that release exists.
