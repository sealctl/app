# sealctl app: implementation spec

This is the build spec for the sealctl phone apps: the iPhone app (Swift, SwiftUI) in `ios/` and the Android app (Kotlin, Jetpack Compose) in `android/`. Both use one Rust library for derivation, crypto, protocol types and the app's own rules, through UniFFI.

The wire formats live in the public [`sealctl` protocol](https://github.com/sealctl/sealctl/blob/main/docs/protocol.md). This spec names its sections instead of repeating them:

- **Derivation and test vectors**: the 24 words, the root, every purpose string, the words fingerprint.
- **Store format**: `.id` files and key checks.
- **Pairing QR code and proof**: what the machine's QR code carries and how the phone proves the pairing.
- **Request and reply encryption**: how requests are sealed to the phone and replies sealed to the machine.
- **Relay API**: endpoints, signing, errors, limits. Final.

Section 19 lists what this app still needs added to those sections.

## Contents

1. What the app is
2. Rules the app never breaks
3. Platforms
4. Repository layout
5. Build: the Rust library and bindings
6. Architecture and state
7. Key storage
8. Relay client
9. Requests and the levels of asking
10. Notifications and background work
11. Screens and flows
12. Accessibility
13. Localisation
14. Privacy: data, manifest, store forms, permissions
15. Store listings and review notes
16. Testing
17. CI and release
18. Milestones
19. Needs from the protocol, core and relay
20. Open questions

## 1. What the app is

sealctl keeps a developer's keys off their laptop's disk. When an agent or a command on a paired machine needs a key, the machine asks the phone. The phone derives the key from the root, seals it to that one request and sends it back through the relay. The agent never sees the key.

The phone is the only approver. It holds the root, made from 24 words written by hand on a paper card. It also keeps the list of paired machines, the places it trusts, the answers it remembers and the inventory of every key it handed out.

The app does these jobs:

| Job | Where in this spec |
| --- | --- |
| Create or restore the 24 words; write and check the card; keep backups of the root | 7, 11.3, 11.4 |
| Pair machines by QR code; tell duplicate names apart | 11.5, 11.6 |
| Answer requests: automatically, with one tap, or in the app | 9, 10, 11.7 |
| Confirm sensitive and leaving actions: biometrics, number match, plan, delay, card check, report | 9.6, 11.23 |
| Show each machine as Locked, Open or Waiting; lock on demand | 11.8, 11.17 |
| Learn places; lock machines when the phone leaves one | 11.9 |
| Remember answers; keep the usage log, the inventory and a monthly summary | 11.10 to 11.13 |
| Change the words and follow the move of every object | 11.14, 11.15 |
| Ask for 2 words a year to check the card | 11.16 |
| Delete the user's relay data; unpair machines | 11.17, 11.19 |
| Leave sealctl: walk through `sealctl unseal --all` on each computer, then delete the relay data and the words backup | 11.22 |

## 2. Rules the app never breaks

Every change to the app is checked against this list. Reviewers reject a change that breaks one.

1. **The words never leave the phone in readable form.** The app never prints, exports, shares, copies or screenshots them. It hides them during screen recording, mirroring and in the app switcher.
2. **The paper card comes first.** No machine can be paired and no key handed out until the card has passed the 3-of-4 check.
3. **No price, no payment, no licence.** The app sells nothing and shows nothing about payment: no price, no "buy", no "paid" badge, no link to a checkout. It may show the monthly summary.
4. **Derived keys stay inside the Rust library.** Swift and Kotlin code never hold a derived key, only opaque handles and sealed strings.
5. **Locations stay on the phone.** No maps, no reverse geocoding, no location in any request to any server. Places reach the relay only inside the encrypted state blob.
6. **No account, no analytics, no ads, no trackers, no crash-reporting SDK.** Platform crash reports (App Store Connect, Play Console) are the only diagnostics.
7. **No logs of secrets or context.** Key names, paths, commands, repository names and machine names are logged only with private redaction (`OSLog` `.private`; no `Log` calls in Android release builds).
8. **None of the asking rules is a setting.** Levels of asking, confirmation levels, allowances, lifetimes and the two-hour delay are fixed. The user can turn off backups, places and notifications, nothing else that changes when the phone asks.
9. **Same words everywhere:** Locked, Open, Waiting, One tap, Places, Answers, Inventory, words, card.

## 3. Platforms

| | iPhone | Android |
| --- | --- | --- |
| Minimum | iOS 17.0 | Android 9 (API 28) |
| Target | Current iOS SDK (Xcode 26) | `targetSdk` 36 |
| Devices | iPhone only (`TARGETED_DEVICE_FAMILY = 1`), portrait | Phones, portrait; tablets run the phone layout |
| Language | Swift 6, strict concurrency | Kotlin 2.x |
| UI | SwiftUI, Observation (`@Observable`) | Jetpack Compose, Material 3 with sealctl tokens |
| Secure lock screen | Required (passcode set) | Required (`KeyguardManager.isDeviceSecure`) |
| Push | APNs, alert pushes with a Notification Service Extension | FCM high-priority data messages |
| Root backup | iCloud Keychain | Block Store |
| Region monitoring | `CLMonitor` | Geofencing API (Google Play services) |
| QR scanning | AVFoundation `AVCaptureMetadataOutput` | CameraX with zxing-cpp |

Why these minimums: iOS 17 brings `CLMonitor` and the Observation framework. Android 9 is the floor for Block Store end-to-end encryption and `setUnlockedDeviceRequired`. Android 12 (API 31) adds notification buttons that require an unlock first; on Android 9 to 11 the request notification has no buttons (11.7).

Google Play services is required on Android (FCM, Block Store, geofencing). Phones without it are not supported in version 1 (open question 20.6).

## 4. Repository layout

```text
app/
  LICENSE                     AGPL-3.0
  CONTRIBUTING.md             contribution terms, including app store distribution (20.1)
  SPEC.md                     this file
  rust-toolchain.toml         pinned Rust version
  Cargo.toml, Cargo.lock      Rust workspace; pins sealctl-core to a sealctl release tag
  shared/                     crate sealctl-app (AGPL): state, rules, merge, places maths, summaries
  tools/
    fake-relay/               Rust: in-memory implementation of the Relay API, plus test controls
    fake-machine/             Rust: pairs and sends sealed requests like a machine
    card/                     card.svg sources and the script that renders the blank card PDFs
  scripts/
    build-core-ios.sh         XCFramework and Swift bindings
    build-core-android.sh     .so files and Kotlin bindings, packaged as the :core module
    check-core.sh             fails if the generated bindings differ from what is committed
    install-ios-personal.sh   local install with a free Apple team (ios/project-personal.yml)
  brand/                      app-icon.svg, mark.svg, mark-dark.svg, tokens (copied from the brand kit)
  .github/CODEOWNERS          the maintainer owns everything; ios/ and android/ may gain platform owners
  ios/
    project.yml               XcodeGen project (the .xcodeproj is generated, not committed)
    project-personal.yml      local-only variant for a free Apple team: no push, extension or app group
    App/                      app target: scenes, AppDelegate, notification delegate
    NotifyExtension/          Notification Service Extension target
    Packages/
      SealCore/               generated UniFFI Swift + binary target SealctlFFI.xcframework
      Vault/                  Keychain items and LocalAuthentication
      Relay/                  HTTP, WebSocket, signing headers, retries
      Places/                 CLMonitor, location samples
      Engine/                 app model over the Rust rules and store
      DesignSystem/           tokens, components, the approval card
    Resources/                Assets.xcassets, Localizable.xcstrings, InfoPlist.xcstrings,
                              PrivacyInfo.xcprivacy, card-a4.pdf, card-letter.pdf
    Tests/, UITests/, SnapshotTests/
    fastlane/
  android/
    settings.gradle.kts, gradle/libs.versions.toml
    app/                      single activity, navigation, screens
    core/                     generated UniFFI Kotlin + jniLibs (built as an AAR)
    vault/                    Keystore, BiometricPrompt, Block Store
    relay/                    OkHttp HTTP and WebSocket
    places/                   geofences and location samples
    notify/                   FirebaseMessagingService, channels, action receiver
    designsystem/             tokens, components, the approval card
    fastlane/
  store/
    ios/                      App Store metadata in fastlane deliver layout, review notes
    android/                  Play metadata in fastlane supply layout
  .github/workflows/          core.yml, ios.yml, android.yml, devices.yml, bench.yml, release.yml
```

Identifiers:

| Item | Value |
| --- | --- |
| iOS bundle id | `com.sealctl.app` |
| Notification Service Extension | `com.sealctl.app.notify` |
| App group | `group.com.sealctl.app` |
| Keychain access group | `$(AppIdentifierPrefix)com.sealctl.shared` |
| Android application id | `com.sealctl.app` |
| Push device id | 22 characters of random base64url (16 bytes), made once per install; iOS keeps it in the app group's `UserDefaults`, Android in `noBackupFilesDir`, so a reinstall gets a new id |
| Rust library name | `sealctl_app` (one library holding `sealctl-core` and `sealctl-app`) |
| Swift module | `SealCore` |
| Kotlin package | `com.sealctl.core` |

## 5. Build: the Rust library and bindings

### 5.1 Two crates, one library

- **`sealctl-core`** lives in the public `sealctl` repository (MIT). It holds derivation, the words, the fingerprint, relay signing, pairing, request opening and reply sealing, state encryption and the test vectors. It carries UniFFI proc-macro annotations behind a `uniffi` feature.
- **`sealctl-app`** lives here in `shared/` (AGPL). It holds what both apps must do the same way: the state model and its encoding, the merge of state versions, the levels-of-asking rules, the day record, place clustering, answer and inventory lifetimes, the monthly summary. It depends on `sealctl-core` and adds its own UniFFI exports.

Both are compiled into one library and bindings are generated in UniFFI library mode (`uniffi-bindgen generate --library`), which emits Swift and Kotlin for every crate in the library. Keeping the rules in Rust means one set of tests decides when the phone asks, on both platforms.

### 5.2 Versioning against sealctl releases

- `Cargo.toml` pins `sealctl-core` as a git dependency on a release tag of `sealctl` (for example `tag = "v0.7.0"`); `Cargo.lock` pins the commit. No branch dependencies on `main` in release builds.
- The UniFFI version is the one `sealctl-core` uses; `cargo deny` and a CI check fail on a mismatch.
- The app reads `core_version()` and `protocol_version()` at start and shows them in About.
- A pairing QR code or a request with a newer protocol major version than the library knows is refused with "This machine runs a newer sealctl. Update the app." An older minor version is accepted.
- The app's own version is `MAJOR.MINOR.PATCH`, independent of the CLI. The build number is the CI run number. `CHANGELOG.md` names the `sealctl` tag each release is built on.
- Updating the core is one pull request: bump the tag, run both build scripts, commit the regenerated bindings, pass CI.

### 5.3 Build outputs

| Platform | Rust targets | Output | Script |
| --- | --- | --- | --- |
| iOS | `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios` | `SealctlFFI.xcframework` (static libraries) plus `SealCore.swift`, used as a binary target in the `SealCore` package | `scripts/build-core-ios.sh` |
| Android | `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android` | `libsealctl_app.so` per ABI in `android/core/src/main/jniLibs`, plus generated Kotlin; the `:core` module builds as an AAR | `scripts/build-core-android.sh` (uses `cargo-ndk`) |

- Release profile: `lto = true`, `codegen-units = 1`, `strip = true`, `panic = "abort"` is not used, so a Rust panic becomes a thrown error through UniFFI instead of a crash.
- Binaries are built from source in CI on every run; nothing is downloaded prebuilt. Generated bindings are committed so a Swift or Kotlin developer can build without Rust only if `SKIP_CORE_BUILD=1` and a cached library is present; CI never skips.
- Android release builds keep JNI symbols in R8 rules for JNA (`-keep class com.sun.jna.** { *; }` and the generated package).

### 5.4 Library surface

Secrets cross the boundary as UniFFI objects that zero their memory when released (`Root`, `Words`, `PhoneKeys`). Their raw bytes are exposed only to the Vault module for storage. The exact function list the app needs from `sealctl-core` is in 19.1. `sealctl-app` exports:

| Export | Purpose |
| --- | --- |
| `Store` object: `open(path)`, `snapshot()`, `apply(event)` | The local database (SQLite, bundled) and every change to it |
| `decide(request, context) -> Decision` | Level of asking and confirmation level for one request, and what the confirmation needs: biometrics, number match, plan, delay (section 9) |
| `merge_state(local, remote) -> State` | Merge when the relay answers `409 conflict` |
| `encode_state(state) -> bytes` / `decode_state(bytes)` | The plaintext inside the relay state blob, versioned |
| `place_sample(lat, lon, accuracy, time) -> Option<PlaceCandidate>` | Clustering; returns a candidate when it reaches 3 days |
| `prune(now, utc_offset_secs)` | Drops answers unused for 90 days; flags machines unseen for 90 days; marks inventory unseen for a year as stale; trims the usage log to 90 days and the daily counts to 400 days |
| `usage_since(machine, since)`, `daily_counts(from_day, to_day, utc_offset_secs)` | The Activity log's days and the heatmap's counts (11.12) |
| `activity_row(entry, machine)`, `activity_counts(entries)`, `heat_levels(counts)` | An Activity row's text, a day's figures, the heatmap's levels (11.12) |
| `summary(month) -> Summary` | Keys used, requests declined |
| `nse_snapshot()` | The small read-only file the iOS extension reads (6.4) |

## 6. Architecture and state

### 6.1 App states

The app is always in exactly one of these states. Each platform keeps it in one observable model (`AppModel` on iOS, `AppViewModel` on Android).

| State | Means | What the user sees |
| --- | --- | --- |
| `NeedsScreenLock` | The phone has no passcode or screen lock | A blocking screen (11.20) |
| `NoWords` | First run, nothing found | Welcome (11.3) |
| `BackupFound` | No local words, but iCloud Keychain or Block Store holds some | Welcome with "Restore" first (11.4) |
| `CardUnchecked` | Words created, the 3-of-4 check not passed | Onboarding resumes at the card |
| `Ready` | Words checked | Main tabs |
| `Changing` | A change of words is in progress | Main tabs with the change banner (11.14) |
| `WordsLost` | The root item is gone (passcode removed on iOS, keys invalidated on Android) | A restore screen (11.20) |

### 6.2 Navigation

Four tabs, in this order: **Machines**, **Activity**, **Inventory**, **Settings**. Sheets on top of any tab: the approval card, pairing, the duplicate-machine card, "Trust this place?", the yearly check. The change of words and onboarding are full-screen flows.

### 6.3 Modules and threads

- iOS: `Vault` and `Relay` are actors. UI code calls the `Engine`, which calls the Rust `Store` on a serial executor. The NSE links `SealCore`, `Vault`, `Relay` and a read-only part of `Engine`; it never opens the database.
- Android: one process. A `Graph` object builds the singletons by hand (no DI framework). ViewModels expose `StateFlow`. Rust calls run on `Dispatchers.Default`; network on `Dispatchers.IO`.
- The approval path (open request, decide, seal reply, post) must finish within 2 seconds on the slowest phone in the matrix (16.4).

### 6.4 Data model

Defined once in `sealctl-app`. "Relay" means the record is part of the encrypted state blob; "Local" means it stays in the phone database only.

| Record | Fields | Kept |
| --- | --- | --- |
| Machine | pairing key, name (`user@host`), OS, model, hardware hint, paired at, nickname, last seen (the relay's `lastSeen`), last status, tag shown, flagged | Relay; until unpaired; flagged after 90 days unseen. The hardware hint lives only here: the relay does not store it |
| Answer | agent, key name, repository id, repository name, created, last used | Relay; until removed; dropped after 90 days unused |
| Place | id, name, centre, radius (150 m), created | Relay; until removed |
| Place candidate | samples (centre, accuracy, day), suppressed flag | Local; samples older than 30 days dropped |
| Day | machine, first approval time, place id or none | Local; ends at the next 02:00 local time or 24 h after the first approval, whichever is first |
| Inventory item | purpose, id, words fingerprint, key check, machine, path or URL, size, first use, last use, stale | Relay; kept; stale after a year unseen |
| Usage entry | time, machine, key or object, agent or "you", repository, command, outcome | Local; 90 days, at most 50,000 entries. "This machine was lost or stolen" (11.17) reads these 90 days |
| Daily count | local day (`YYYY-MM-DD`), keys used, requests declined | Local; 400 days (the Activity heatmap's 53 weeks and a margin) |
| Summary | month, keys used, requests declined | Relay; 12 months by the calendar (this month and the 11 before it), however many months had no use; a month after this one (counted by an install whose clock ran ahead) is dropped |
| Words | fingerprint, written on, last check, retired cards (fingerprint, retired on) | Relay |
| Change | old and new fingerprint, reason, started, per-machine progress, not-seen list | Relay; until finished |
| Settings | relay backup on, keychain backup on | Relay |
| Device | this install's push device id, push token, platform, sandbox flag | Local |
| Pending | requests seen in the last 10 minutes (id, machine, expires, outcome) | Local; used to refuse replays |
| Plan approval | machine, request id, plan hash, plan items, not-before, state | Local; 30 minutes after not-before, then kept as history with the report |
| Hold | machine, until (one hour after a wrong number) | Local |
| Delayed action | relay delayed id, what (`unseal_all`, `leave`, `words`, `delete`, or `unknown` for a phone-only action another install started, 11.23), machine, release time, state | Local; until finished, cancelled or expired; the relay holds its own record (19.2) |
| Hand-back report | machine, plan hash, items with where each went and state, run folder, time | Relay; kept |

**Daily counts.** The Activity heatmap (11.12) shows a year, longer than usage entries are kept, so the phone keeps one row of figures per local day. A day is counted the way the month summary is: "keys used" and "requests declined", on the phone's local day (by the UTC offset the app passes) when the answer was given or the report reached the phone. The count grows in the same database transaction as the usage entry, and only when an entry is stored, so the check that skips a log a machine sends again (it resends until acknowledged) keeps the figures from counting twice. That check needs the stored entry, which goes after 90 days; so an entry a machine reports that is already older than 90 days is neither stored nor counted, in the log, the day or the month: it can no longer be told apart from one counted before. The first time a database from before the daily counts is opened, the usage entries it holds are marked, and the first call that carries the UTC offset (any answer or report, `daily_counts` or `prune`) counts them once, before a prune can remove them: one use per entry (one decline for `denied`, nothing for `expired`), on the entry's own local day. Entries stored after the mark were counted when they were stored.

The local database is one SQLite file:

- iOS: `Library/Application Support/sealctl.db` in the app's own container, file protection `completeUntilFirstUserAuthentication`.
- Android: `noBackupFilesDir/sealctl.db` in credential-encrypted storage.

No secret is ever stored in the database. Places sit there protected by the OS file encryption.

**iOS extension snapshot.** The app writes `nse-snapshot.bin` to the app group container after every change, atomically (write and rename). It holds what the NSE needs: machines (key, display name, tag), answers, trusted places with the current inside or outside state, days, the active-device flag. The NSE writes its own results as small files in `inbox/` (one per answered request, with the time it answered); the app merges and deletes them at launch and on every foreground. The app may run hours after the extension answered, when the request's signed time is long outside its 10-minute window, so it opens each item against the time it was answered (`open_answered_request`) and records it at that time (`answered_at`, `apply_report_at`): the use renews the answer it used, and the usage entry, its month, the inventory's last use and a report's session status count from then, not from the merge. Neither process holds a file lock while suspended.

### 6.5 Sync with the relay

- The phone uploads its state to `PUT /v1/phones/{phone}/state` 10 seconds after the last change, and at once after pairing, unpairing, removing an answer or a place, and at each step of a change of words.
- The blob is `state_seal(root, encode_state(state))` (19.1). Sealing needs the root, so it waits for the phone to be unlocked; the debounce timer simply fires again later.
- On `409 conflict` the app downloads, merges with `merge_state` and retries, up to 3 times. Records merge one by one: the later `updated` time wins; deletions are kept as tombstones for 90 days. A record changed or added again on this phone (re-pairing, remembering an answer again, a place, a report, a lifetime applied by `prune`) gets an `updated` later than every copy of it the phone holds, removed ones included, so it wins a merge with a copy stamped by another install whose clock ran ahead. Month summaries are counters and merge differently: month by month, the larger count of each figure and every machine either side named, so one install's count is never replaced by a smaller one from an install whose clock ran ahead. Machine and place tombstones then shrink to their key and deletion time and stay, so an older copy of the state (another install, an old blob) cannot bring an unpaired machine or a removed place back.
- On launch, the app downloads if the last download is more than 1 hour old.
- If the encoded state is over 1 MiB, the app drops paths from stale inventory items first, then the oldest stale items, and says so in Settings: "The relay backup is full. Old inventory entries were shortened."
- Turning the relay backup off stops uploads and deletes the blob with `PUT` of an empty state; it does not touch pairings, which the relay needs to carry requests.
- Several installs can share one set of words (8.7). Each one merges what the others uploaded, so `409 conflict` is normal, not an error.
- The relay deletes a phone's data after 730 days with no signed call from the phone. Normal use (any answer, any launch) keeps it; the app adds no keep-alive.

### 6.6 Constraints from 0.9

sealctl 0.9 (Teams and Enterprise) puts a separate work identity, with its own 24 words and its own relay (the employer's server), next to the personal one on the same phone. Until then the app holds one identity and one relay, but the data model must not assume it:

- **The relay and the identity are properties of each pairing.** Every `Machine` records the relay origin it was paired through (it already has `relay`) and the identity it belongs to (by words fingerprint or an identity id), even while only one of each exists. Nothing reads "the" relay or "the" phone key from a global when handling a machine, a request, a status or a message: it takes them from the pairing.
- **Per-identity records stay separable.** Local records keyed by machine (days, pending, holds, plans, delayed actions, message counters) and the push registration are keyed so that a second identity can be added without a migration that rewrites them. The state blob stays per identity, sealed with that identity's own state key.
- **`decide()` takes everything from its context.** No asking rule reads app-wide settings directly; 0.9 adds an organisation's effective policy to `DecideContext` for work identities only, and a personal identity must keep behaving exactly as specified here.

The 0.9 design, including the multi-identity data model, enrolment and the policy rules for `decide()`, is in the `sealctl/enterprise` repository's `SPEC.md` (sections 4, 6.6 and 24.3).

## 7. Key storage

### 7.1 What exists

| Secret | Made from | Needed for |
| --- | --- | --- |
| Words entropy | The 24 words (32 bytes) | Showing the words, the yearly check, restoring |
| Root | The words, as in "Derivation and test vectors" | Every reply that carries a key; sealing the state |
| Phone keys | `derive(root, "phone:identity")` (Ed25519) and `derive(root, "phone:box")` (X25519), from "Derivation and test vectors" | Signing relay calls, replies and machine messages; opening requests and machine status, which machines encrypt to the box key |

The root is one-way from the words, so a separate words item with a stronger lock is a real lock, not a screen.

### 7.2 iPhone

All items are `kSecClassGenericPassword` in the shared access group, so the NSE can read them.

| Item (`kSecAttrService`) | Holds | Accessibility | Access control | Synced |
| --- | --- | --- | --- | --- |
| `com.sealctl.root` | Root | `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` | none | No |
| `com.sealctl.words` | Words entropy | `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` | `SecAccessControl` with `.userPresence` (Face ID, Touch ID or passcode) | No |
| `com.sealctl.phone` | Phone keys | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | none | No |
| `com.sealctl.words.sync` | Words entropy and its fingerprint and date | `kSecAttrAccessibleWhenUnlocked` | none (synced items cannot carry access control) | Yes, `kSecAttrSynchronizable` |
| `com.sealctl.root.old`, `com.sealctl.words.old` | The retiring words during a change | Same as the current items | Same | No |
| `com.sealctl.gate` | 32 random bytes; holds nothing secret, its read is the proof of a fresh biometric match for levels 2 and 3 (9.6) | `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` | `SecAccessControl` with `.biometryCurrentSet` | No |

- `WhenPasscodeSetThisDeviceOnly` makes the root readable only while the phone is unlocked, and iOS deletes it when the passcode is removed.
- The phone keys are readable after the first unlock since boot, so the NSE can open a request and show its contents on the lock screen, and the app can sign a lock message when the phone leaves a place while locked. These keys cannot make any derived key.
- The Secure Enclave protects these items through the keychain's data protection classes. The app adds no Secure Enclave key of its own: a P-256 wrap adds a failure mode and no protection against the threats in the design.
- `kSecAttrAccount` is the words fingerprint, so an old and a new set can live side by side during a change.
- Custom keyboards are refused app-wide (`application(_:shouldAllowExtensionPointIdentifier:)` returns `false` for `.keyboard`).

### 7.3 Android

Secrets are encrypted with AES-256-GCM using Android Keystore keys and stored as files in `noBackupFilesDir`. Each Keystore key is created with `setIsStrongBoxBacked(true)` and falls back to the TEE on `StrongBoxUnavailableException`.

| File | Holds | Keystore key | Key parameters |
| --- | --- | --- | --- |
| `root.bin` | Root | `sealctl.root` | `setUnlockedDeviceRequired(true)` |
| `words.bin` | Words entropy | `sealctl.words` | `setUserAuthenticationRequired(true)`, `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG or AUTH_DEVICE_CREDENTIAL)` on API 30+, `setInvalidatedByBiometricEnrollment(false)`; used through `BiometricPrompt` with a `CryptoObject` |
| `phone.bin` | Phone keys | `sealctl.device` | none (usable after the first unlock) |
| `root.old.bin`, `words.old.bin` | The retiring words during a change | Same keys | |
| `gate.bin` | 32 random bytes, read only to prove a fresh biometric match (9.6) | `sealctl.gate` | `setUserAuthenticationRequired(true)`, `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)` (API 30+; `setUserAuthenticationValidityDurationSeconds(-1)` before), `setInvalidatedByBiometricEnrollment(true)`; used through `BiometricPrompt` with a `CryptoObject` and `BIOMETRIC_STRONG` only |

- On API 28 and 29, `setUserAuthenticationParameters` does not exist; the words key uses `setUserAuthenticationValidityDurationSeconds(-1)` (per-use authentication, strong biometric only) and the words screen falls back to `KeyguardManager.createConfirmDeviceCredentialIntent` when the user has no biometric.
- Auto Backup is off: `android:allowBackup="false"`, and `dataExtractionRules` exclude every domain. Encrypted files without their Keystore keys would be useless on another phone anyway.
- **Block Store**: key `com.sealctl.words.v1`, holding words entropy, fingerprint and date as encoded by the core. Stored with `setShouldBackupToCloud(true)` only when `isEndToEndEncryptionAvailable()` returns true. Otherwise the copy is stored for device-to-device transfer only and Settings says the cloud copy is off and why.
- If the screen lock is removed, Android does not delete the root. The app checks `isDeviceSecure` at every start and every approval; without a secure lock it answers nothing and shows the blocking screen. A `KeyPermanentlyInvalidatedException` on any key moves the app to `WordsLost`.

### 7.4 What survives what

| Event | iPhone | Android |
| --- | --- | --- |
| App deleted and installed again | Keychain items usually remain (Apple does not promise this). On first launch the app finds `com.sealctl.root`, asks for Face ID or the passcode, and offers "Continue with seed 7Hq3". If the user declines, it deletes the items. State comes back from the relay | Keystore keys and files are gone. Block Store keeps its copy when the user's Google backup is on, so Welcome offers to restore from it. State comes back from the relay |
| Passcode or screen lock removed | iOS deletes the root and words items; the app shows `WordsLost` | The app refuses to answer until a screen lock is set |
| New phone, same Apple Account or Google account | Restore from iCloud Keychain | Restore from Block Store (cloud restore on Pixel from Android 9, on other makers from Android 12) |
| iPhone to Android or back | The words, typed in | The words, typed in |
| Phone reset or lost | The card, or the synced copy on another device | The card, or the cloud copy |

## 8. Relay client

### 8.1 Basics

- Base URL `https://relay.sealctl.com`, unless the pairing QR code names another relay (open question 20.4). One relay per phone.
- Every call except `GET /v1/health` carries `Sealctl-Key`, `Sealctl-Time` and `Sealctl-Signature`, produced by the core's signing function over the five lines in the Relay API's Signing section.
- HTTP/2 over TLS, system trust store, 10-second timeout per call. iOS: `URLSession` with an ephemeral configuration (no cache, no cookies). Android: OkHttp with no cache.
- The app keeps a clock offset. `401 clock_skew` carries the relay's `time`; the app sets the offset from it and retries once. If that fails it shows the clock error (11.20).
- **The corrected clock.** Every security window is counted on the relay's clock, not on the phone's own clock, which whoever holds the phone can set. That covers a hold (9.6), the not-before time of a plan and its 30-minute window, the level 3 delay and the two hours before a place added by hand (without an announcement, 11.9) lifts it, and the stamps they start from (the hold's end, the plan's not-before time, the place's `created`). The shared core keeps it (`Store.clock_now`), so both apps and the iOS extension count the same way:
  - The relay's time is learned from `GET /v1/health` (`time`, unsigned) when the app starts or comes to the foreground, before a level 3 decision at a place added by hand while the clock is stale, and from every `401 clock_skew`. It is carried forward on the phone's since-boot clock (Android `CLOCK_BOOTTIME`, iOS `CLOCK_MONOTONIC`, both counting sleep), which changing the date and time does not move. Precision: the relay's whole second.
  - **Fresh** means learned in this boot (the since-boot clock has not restarted and the boot id is the same: Android `/proc/sys/kernel/random/boot_id`, iOS `kern.bootsessionuuid`; where the system gives no boot id, the app process stands in for it, so a relay time stored by an earlier process is stale until learned again), less than 24 hours ago on the since-boot clock, with no signed call against it. While fresh, the clock is the relay's time plus the since-boot time since.
  - Signed calls check it: every call the relay accepts shows that the relay's clock is within its 5-minute signature window of the `Sealctl-Time` sent. If the corrected clock is further than that from it, it is **stale** until the relay's time is learned again.
  - **Stale or unknown** (not fresh, or never learned): the later of the system clock and the last-known corrected clock (the last relay time plus the since-boot time since, or only the last relay time after a reboot). A wait never ends early because the clock was set back, and a place added by hand does not lift the level 3 delay at all until the clock is fresh again (9.6). A place added by hand while the clock is stale is not stamped (`created` 0, shown as "trusted just now"): its 24 hours start when the clock is next fresh, since a stale clock can be days behind. If `/v1/health` can't be reached, the clock stays stale, which fails closed.
  - On iOS the app copies the last relay time into the extension's snapshot (6.4). When it is stale, the extension asks `/v1/health` itself before it decides.
- Calls the app makes count towards the phone's 5,000 calls a day. The app never polls on a timer.

Errors the app handles everywhere:

| Error | App does |
| --- | --- |
| `401 clock_skew` with `time` | Correct the offset, retry once |
| Other `401` | Log (private); show "The relay refused this phone's signature. Update the app." |
| `403 forbidden` | The phone key is unknown for that machine: refresh the machine list |
| `413 too_large` | Bodies other than the state stay far below the relay's 16 KiB limit, so this only means a bug; for the state, see 6.5 |
| `429 rate_limited` with `retryAfter` and `scope` | Stop calls until `retryAfter` except replies the user taps; show the limit banner |
| `500 internal`, `502`, `503`, network errors | Retry with the backoff in 8.3; replies follow 8.5 |

### 8.2 Endpoints the app uses

| When | Call |
| --- | --- |
| Pairing | `POST /v1/phones/{phone}/machines` with `machine`, `name`, `os`, `model`, `proof`. The hardware hint is not sent; it stays in the encrypted state |
| Machines list refresh, restore | `GET /v1/phones/{phone}/machines`, with `lastSeen` per machine (Unix ms, to the hour) |
| Unpair, replace a duplicate | `DELETE /v1/phones/{phone}/machines/{machine}` |
| App in the foreground | `GET /v1/phones/{phone}/socket` (WebSocket) |
| After a push, on foreground, after the socket reconnects | `GET /v1/phones/{phone}/requests` |
| Every answer | `POST /v1/phones/{phone}/requests/{id}/reply`; with `"delay": 7200` for a level 3 approval away from a trusted place (9.6) |
| Delayed actions (11.23) | `POST /v1/phones/{phone}/delayed` for an action on the phone; `GET /v1/phones/{phone}/delayed` on foreground and after a `delayed` or `cancelled` push or socket note; `POST .../delayed/{id}/cancel`; `POST .../delayed/{id}/finish` |
| Sync | `GET` and `PUT /v1/phones/{phone}/state` |
| Change of words (11.14) | `POST /v1/phones/{old}/licence/move` with `{"to", "proof"}`, signed by the old key; `proof` is the new key's Ed25519 signature over `sealctl-licence-move-v1\n<old>\n<new>`. Unpaid phones move too. The app shows nothing about it, whatever it answers (`movedTo`, `licence`, `daysUsed`) |
| Launch, token change, restore | `PUT /v1/phones/{phone}/push/{device}` with `{"platform": "apns", "token": <hex>, "sandbox": true}` for development builds (`sandbox` left out in TestFlight and App Store builds), or `{"platform": "fcm", "token"}`. Answers `200 {"devices": n}` |
| Settings, Phones getting requests | `GET /v1/phones/{phone}/push`: `{"devices": [{"device", "platform", "sandbox", "updated"}]}`; `DELETE /v1/phones/{phone}/push/{device}` |
| Settings, Send a test request | `POST /v1/phones/{phone}/push/{device}/test`: `{"ok": true}`, `502 push_failed` with `{"reason", "removed"}`, `503 push_not_configured` |
| Delete my relay data; the old key at a change of words | `DELETE /v1/phones/{phone}`: `{"deleted": true, "machines": n}` |
| Machine states (11.8), Activity inside a session | `GET /v1/phones/{phone}/status`: `{"status": [{"machine", "sealed", "updated"}]}`, each opened with `open_machine_status`; after a `{"type": "status", "machine"}` note on the socket, and on foreground |
| Lock, Lock all, leaving a place, answers | `POST /v1/phones/{phone}/machines/{machine}/messages` with `{"sealed"}` from `seal_machine_message`; `{"delivered": false}` means the relay holds it for up to 24 hours |
| Until the relay ships the machine channel | The same status and messages through `report` requests: the status arrives as a `report`, the reply carries `ack` and waiting messages (`seal_report_reply`) |

Push registration errors: `bad_device`, `bad_platform`, `bad_token` mean a bug and are logged; `404 unknown_device` on delete is treated as done. The relay keeps at most 4 devices per phone; a fifth registration evicts the oldest.

The app never calls `licence`, `checkout` or `claim`.

### 8.3 Foreground: WebSocket

- When the app becomes active, it opens `/socket`, then lists pending requests to catch up. Each `{"type": "request", ...}` message goes through the approval path (9). `{"type": "delayed", ...}` and `{"type": "cancelled", ...}` notes refresh the delayed actions (11.23).
- The app sends the text `ping` every 30 seconds; the relay answers `pong`. No `pong` within 10 seconds means the socket is dead: close and reconnect.
- The relay also pushes while the socket is open. The app ignores a push for a request it already handled through the socket and shows no notification for it in the foreground.
- Reconnect after a drop: 1, 2, 4, 8, 16, then every 30 seconds, each with ±20% jitter. At most 60 upgrades an hour, since upgrades count towards the abuse limit.
- When the app leaves the foreground the socket closes, however long it was open: a call's time limits (8.1) cover only the socket's upgrade, and the foreground and the ping bound the open socket. A message that still arrives on a closed socket is not acted on; the request waits for its push and the next catch-up. iOS would suspend it anyway; Android closes it so it does not hold a connection in the background. A foreground that ends before its work starts opens no socket and does not count as foreground, so requests then still show notifications.

### 8.4 Background: push

- A push carries only `type`, the request `id` and `expires` (10.1, 10.2). The app or extension lists pending requests and handles the one with that id, plus any others pending: the relay sends at most one push per device every 5 seconds, so one push can stand for several requests.
- If the list fails, the notification shows the generic text and the app tries again when opened.

### 8.5 Replies

- A reply is sent once per request. On a network error it is retried at 1, 2 and 4 seconds and then every 10 seconds until the request's `expires`.
- A second answer while one is on its way (a notification action and the card at once, two notification actions, or a level 2 or 3 confirm and its Deny) sends nothing: the first answer goes.
- `created` and `expires` are on the relay's clock. A phone clock ahead of the relay's by less than its 5-minute signature window raises no clock error, so the phone counts a request's time to `expires` plus the time between `created` and when it first saw the request, at most 5 minutes. A reply after the relay's own `expires` gets `404 gone`; the relay decides.
- The card's timer and an answer on its way, at any level: the answer decides. When the relay takes it, it is recorded once, as answered; when it fails after the request's time, the card shows "stopped waiting". A tap after the request's time (the timer did not run, for example after the phone slept) sends nothing and shows "stopped waiting". Claiming a card for an answer and expiring it are one step each, so on Android, where the timer and the answer run on different threads, only one of them gets the card.
- A try that got no answer or a `5xx` may still have reached the relay. When a later try gets `404 gone`, or the request's time runs out while trying, an allow is recorded as given (its use and the day, at the place it was decided; never as a remembered answer), the card shows "stopped waiting", and leaving that place locks the machine (11.9). The machine may have the keys, so the phone acts as if it does.
- When a reply the person tapped does not go (a `4xx` other than `404 gone`, `429`, or it could not be sealed), the card keeps its buttons and shows "Couldn't send your answer — try again." The core seals a request once, so the app opens it again from the relay's text for the next tap. From a notification action, the request's notification comes back with that text as its body (on iPhone an action removes the notification); when the request list could not be fetched either, a notification "Waiting for your phone" with that text opens the app.
- An answer keeps going when the person leaves the app at once: iPhone runs it inside `beginBackgroundTask`; Android runs it in the app's scope, not the screen's.
- `404 gone` means the machine stopped waiting. The app records the request as expired and shows "dev@mbp.example.com stopped waiting." if the user is looking at it.
- `429 rate_limited`: the app shows the limit banner with the reset time from `retryAfter` (and `scope` in the private log), and stops making calls until then except replies the user taps.

### 8.6 Offline

- Offline is detected with `NWPathMonitor` (iOS) and `ConnectivityManager.NetworkCallback` (Android).
- Offline banner on the Machines tab: "Offline. Requests reach this phone when it is back online."
- Lock messages are queued and sent when the phone is back online, until they are delivered or the machine's day has ended.
- Replies are never queued past `expires`.
- State uploads wait.

### 8.7 Several installs with the same words

Every install restored from the same words has the same phone key. Each registers its own push device, up to 4 per phone; the relay pushes to all of them on every request.

- Any of them can answer. The first reply wins; the others get `404 gone` and remove their notification.
- Each install keeps its own places state and day records, so automatic answers come only from the install that is inside the place.
- Settings lists them under "Phones getting requests" (11.18), named by platform and last update, with [Remove] on each one except "This phone". Removing an install stops its pushes; it does not erase it.
- After a reinstall, the old install's device stays registered until removed or evicted by a fifth one. The list marks a device not updated for 30 days as "Not updated since 2026-10-02".

## 9. Requests and the levels of asking

### 9.1 The approval path

For every request, from the socket, a push or a list:

1. Look up the request id in Pending. Ignore ids already answered or expired.
2. Check that the relay's `machine` is a paired machine in the local list. Otherwise ignore the request and log it (private).
3. Open the sealed request with the phone keys (`open_request`, 19.1). The core checks the machine's signature inside the request, the time and the protocol version. On failure, ignore and log.
4. Build the context: is the phone unlocked (the root item can be read), the relay's `near` flag and the phone's network type, the current trusted place from region monitoring, the machine's day record, answers, whether a change of words is running.
5. Call `decide(request, context)`. It returns Automatic, One tap or In the app, plus the reply options.
6. Automatic: seal the reply with the root and post it, record the use, show nothing or a quiet note (10.1, 10.2). When the relay does not take that reply (anything but `404 gone`) or the root can't be read, the request goes to the person as One tap instead of waiting unseen. One tap: show the notification or, in the foreground, the approval card. In the app: show a notification that opens the right screen.
7. After the answer, record usage, update inventory from the request's items, update the day record, take a place sample when this was the first approval of the day, and schedule a state upload.

### 9.2 Request kinds

The kinds and their fields are defined by "Request and reply encryption"; 19.1 lists what the app needs. The app treats them as follows.

| Kind | Sent when | Subject shown |
| --- | --- | --- |
| `open` | A Locked machine needs the session keys, triggered by a command, an agent, a volume mount or a backup | The key, volume or backup that triggered it, or the machine |
| `agent` | An agent uses a key in a repository for the first time inside an Open session | The key, agent and repository |
| `own` | A command uses an `--own-approval` secret | The key |
| `keys` | An Open machine needs a key it does not hold: a new object, a volume opened later, `sealctl seal`. With subject `{"k": "machine", "n": "seal"}` it is `sealctl seal` taking over an object the user already has (level 2) | The volume, backup or key |
| `unseal` | `sealctl unseal` hands objects back under the user's own passwords: one or several (level 2), or `--all` (level 3). Carries the plan | The machine and the plan, after the number match |
| `rewrap` | A machine moves its objects to new words | The machine and its object count |
| `old_words` | A machine holds an object sealed with retired words | The object and the retired fingerprint |
| `report` | A machine reports uses, inventory and its state without asking anything (until the relay's machine channel ships, and for `sealctl migrate` estimates), or what a finished `unseal` handed back (`handback`) | Nothing; recorded silently. A `handback` opens the report (11.23) |

An unknown kind is shown in the app as "dev@mbp.example.com sent a request this app doesn't understand. Update the app." with only "Deny".

### 9.3 Levels

| Kind | Automatic when | Otherwise |
| --- | --- | --- |
| `open` | All of: the machine has a day record today; that day began at a trusted place; the phone is inside that place now; the relay says the phone and the machine are `near`; the phone is unlocked; no agent in the request lacks an answer | One tap |
| `agent` | An answer exists for this agent, key and repository | One tap |
| `own` | Never | One tap |
| `keys` | The phone is unlocked and this machine's session is Open by its last status. Never for `seal` (level 2) | One tap; In the app for `seal` |
| `rewrap` | Never (level 2) | In the app |
| `unseal` | Never | In the app |
| `old_words` | Never | In the app |
| `report` | Always: the reply (`seal_report_reply`) carries `ack`, the status `seq` stored, and the machine messages waiting for it | |

In the app means: a notification with no actions that opens the screen, because levels 2 and 3 need biometrics without the passcode, which a notification action cannot ask for (9.6).

- An `open` request triggered by an agent with no answer for that key and repository is shown as one card. "Allow for this session" also records the answer. That is the only extra tap the design allows, and it is merged into the first one.
- The first approval of the day is the first `open` allowed for that machine since its day ended (02:00 local or 24 h after the previous first approval). Only an answer the person gave (One tap, Allow once) begins a day: an answer given by itself needed an active day when it was decided, and recorded after that day ended (its reply took a while to post, or the iOS extension's answer is merged later) it begins none.
- "02:00 local" is counted both by the UTC offset at the first approval and by the phone's offset now, whichever comes first: a change of daylight saving time or a new time zone while travelling ends the day at 02:00 on the phone's clock, never later. A phone clock that reads more than 5 minutes before the day's first approval (set back) ends the day too. The next 02:00 is never more than 24 hours away, so the 24 hours are a bound for the clock arithmetic, not a second rule a working day meets: a day begun at 09:00 lasts until 02:00, through the evening. The CLI keeps its own hard stop of the same 24 hours (`sealctl/sealctl`).
- "Near" is the relay's `near` flag on the request, trusted only when the phone is on Wi-Fi or Ethernet at that moment (`NWPathMonitor` `usesInterfaceType(.wifi)` or `.wiredEthernet`; Android `NetworkCapabilities.TRANSPORT_WIFI` or `TRANSPORT_ETHERNET`). On mobile data the flag is ignored: the carrier's shared address could match a stranger's. On a VPN the relay sees the VPN's address and the flag is false. Both fall back to One tap.

### 9.4 What the reply carries

Besides the keys, the reply tells the machine the place kind, which sets its allowance cap (19.1):

| Place kind | When | Machine's cap |
| --- | --- | --- |
| `trusted` | The phone is inside a trusted place, with location access Always | 4 h |
| `other` | Location access Always, the phone is elsewhere | 10 min |
| `none` | Location not given, or given only while the app is in use | 1 h |

The core's `place_kind(location, current_place)` decides it from `LocationAccess` (`Off`, `WhileInUse`, `Always`). Only Always lets the phone notice leaving a place: region monitoring (iPhone) and geofences (Android 10 and later) wake the app in the background only with it. Without it the phone does not know where it is, so the reply carries `none`, as with no location at all:

- not `other`: a phone that may well be at its trusted place would get the 10-minute allowance with no growth and ask all day;
- not `trusted`: nothing would notice the phone leaving, so no lock would follow (11.9). A place last known, a record from before, or a fix taken while the app is open does not make it `trusted` either: the fix says where the phone is now, not when it leaves.

`none` keeps every other rule of being away: no `open` answers by itself (9.3), and level 3 waits two hours (9.6).

### 9.5 Replays and forged requests

- Request ids are kept for 10 minutes; a second request with the same id is ignored. An id is kept at least as long as its signed body can still be opened (the core accepts a signed time up to 10 minutes either side of the phone's clock), counted from when it was first seen and again from when it was answered, expired or ignored, plus 10 minutes.
- A request whose sealed contents name a different machine than the relay's `machine` field is ignored.
- The relay can only lie about `near`. A lie skips a tap only for a request already signed by a paired machine, while the phone is unlocked, on Wi-Fi and inside the place where that machine's day began. At level 2 a lie can stand in for proximity; it never skips the biometric match or the list of objects.

### 9.6 Confirmation levels

Every approval also has a confirmation level (protocol, "Confirmation levels"). `decide` computes it from the kind, the subject and the plan, and applies the higher of that and the machine's `lvl`. A machine can raise its level, never lower it. Actions on the phone have fixed levels.

| Level | Requests | Actions on the phone | What the phone asks |
| --- | --- | --- | --- |
| 1 Routine | `open`, `keys`, `agent`, `own` | | As 9.3: Automatic or One tap; the allowance by place (9.4) |
| 2 Sensitive | `rewrap`; `keys` for `sealctl seal`; `unseal` of one or several objects | Pairing a machine (11.5) | Biometrics every time, no passcode; no allowance, nothing remembered; the exact objects listed; proximity |
| 3 Leaving | `unseal --all`, or any plan with a `pairing` item | Leave sealctl (11.22), Show words (11.18), Delete my relay data (11.19) | Level 2, plus: the number match (requests); the plan, signed; the two-hour delay away from a trusted place; the card check (Leave sealctl); a report |

Not level 3: showing the words during onboarding (no machine is paired yet) and the new words during a change of words (11.14), which keep Face ID or the passcode.

**Biometrics, every time.** One prompt per confirmation; nothing is reused.

- iOS: an `LAContext` with `localizedFallbackTitle = ""` (no passcode button) and `touchIDAuthenticationAllowableReuseDuration = 0` evaluates `LAPolicy.deviceOwnerAuthenticationWithBiometrics`, then reads `com.sealctl.gate` with that context (`kSecUseAuthenticationContext`). The item's `.biometryCurrentSet` access control makes the read itself need the match, so a patched check in Swift does not skip it.
- Android: `BiometricPrompt` with `setAllowedAuthenticators(BIOMETRIC_STRONG)` (no `DEVICE_CREDENTIAL`), `setConfirmationRequired(true)`, negative button "Cancel", and a `CryptoObject` on `sealctl.gate`.
- The reason text names the action: "Confirm handing back dev@mbp.example.com." / "Confirm pairing dev@mbp.example.com." / "Confirm leaving sealctl." / "Confirm showing your words."

**When biometrics don't work.**

| Case | Level 2 | Level 3 |
| --- | --- | --- |
| No biometric hardware, none enrolled, or (Android) only weak (class 2) biometrics | Two words from the card, by position, with the keypad of 11.16; never the passcode | Refused: `no_biometrics` to a machine; on the phone, "This needs Face ID (Android: a fingerprint or face unlock of the strong class), and this phone has none set up." On a computer, `sealctl unseal --all --words` works with the card |
| Locked out after failed tries | Same as above | Refused until biometrics work again: "Face ID is locked after too many tries. Lock and unlock your iPhone with its passcode, then try again." |
| A face or fingerprint was added or removed (the gate item or key is invalidated) | First two words from the card, then the app makes a new gate and continues | The same, then the level 3 flow |
| No gate yet: the first biometric confirmation on this phone (pairing in onboarding, the first level 2 or 3 action, [Release now], "Trust where I am now"), also after a restore, an erase or a reinstall | The same as after an enrolment change: two words from the card, then the prompt makes the first gate | The same, then the level 3 flow |

The card is the fallback because the passcode is what a thief watching over a shoulder gets; the card is somewhere else. A thief who knows the passcode and enrols their own face meets the card check.

**The gate is made only after the card.** The gate (`com.sealctl.gate`, `sealctl.gate`) trusts the faces and fingerprints enrolled when it is made. So the app never makes one on its own: the first one, like a new one after an enrolment change, comes right after two words from the card, in the same screen flow ("Use your card"), with the same tries and messages as the level 2 card fallback. Passing the card allows one new gate, for the one prompt that follows it, within two minutes and in that run of the app only: that prompt makes it, and later confirmations read it with no card. A prompt that is cancelled or fails, or a card left for longer, means the card again. Without the card, a face enrolled by someone holding the unlocked phone, before the owner's first sensitive action, would be trusted from then on. A phone without biometrics keeps the card fallback of the table above and never makes a gate.

- The card screen says why. First gate: "Before Face ID can confirm sensitive actions on this phone, type two words from your card." (Touch ID, Optic ID; Android: "Before your fingerprint or face can confirm sensitive actions on this phone, type two words from your card."). After an enrolment change: "A face or fingerprint was added or removed on this phone. Type two words from your card first."
- Then the confirmation goes on by itself: the prompt asks again, makes the gate, and the action continues.

**Proximity** (level 2 and 3) means the person approving can see the machine:

1. the relay's `near` on the request, trusted only on Wi-Fi or Ethernet (9.3); or
2. the number match, when the request has `match` (`has_match`); or
3. for pairing, the app's own camera scanning the code.

Near: no number is asked at level 2. Not near with `match`: the number screen comes first. Neither: the phone answers `not_near`, and the notification says "dev@box.example.com isn't near this phone. Run the command at its terminal; this phone then asks for the number on its screen." Level 3 requests always need the number (protocol).

**Number match.** The core picks the three numbers and checks the pick; the right one never reaches Swift or Kotlin (19.1). The number screen shows nothing the machine wrote (11.23). A wrong pick answers `no_match` and records a Hold: for one hour every level 2 or 3 request from that machine is answered `held` with no notification. A hold only grows: another wrong pick recorded with an earlier end (a clock set back, two cards answered at once) keeps the later end; only [Release now] ends it early. A hold never reaches more than an hour past the phone's clock: one recorded while the clock ran ahead is cut to an hour from now at the next change of the local records, so it still holds a full hour once the clock is right. The machine's detail shows "Sensitive requests from this machine are held until 11:42 after a wrong number." [Release now] (biometrics).

**Plan.** An `unseal` request carries the plan; parts are collected by `PlanAssembler` and answered at once (protocol). The phone shows every item, signs the plan hash (`Plan` decision) and hands out keys only for items in it. Later `unseal` requests for the same plan are answered without showing anything, up to 30 minutes after the not-before time, and only for keys the plan names.

**Delay.** A level 3 approval when the phone is not inside a trusted place (place kind `other` or `none`) takes effect two hours later; inside a trusted place, at once. A newly trusted place, learned or added by hand, lifts the delay only after the same two hours, announced to every paired computer and install, and only once the relay confirms that nobody cancelled the announcement (11.9 Trusting a place); it needs no clock. A place trusted before announcements: a learned one at once; one added by hand two hours after it was added, counted on the corrected clock (8.1), and never while that clock is stale; one added while the clock was stale counts its two hours from when the clock is next fresh (`place_settled`, `place_settles_at`). The delay, the plan's window and holds are all counted on the corrected clock. For a request, the delay is decided when the person confirms, from the place the phone is in then: leaving the place, or the place being removed, while the card is open brings back the two hours, and a confirm never waits less than the verdict said when the request arrived. The plan screen's line (11.23) and the screen after the confirm follow the same rule. The reply's not-before time is then two hours on and the reply is posted with `"delay": 7200`. For an action on the phone, the app registers a delayed action (`POST .../delayed`) and finishes it after the two hours, with biometrics again and only after the relay answers `finish` with `200`. The relay announces it on every paired machine and every install; the app also sends each paired machine a sealed `notice` (`seal_machine_message`). Either side can cancel until it finishes.

**Report.** After a level 3 action the phone shows what happened and tells every other paired machine (`notice` with `state: "done"`): for `unseal`, from the machine's `report` with `handback`; for actions on the phone, the app's own record.

**Never at the lock screen.** Level 2 and 3 requests use the `REQUEST_APP` notification category (10.1): no buttons, a tap opens the app, the app asks for biometrics. A notification action can only ask for the device unlock, which accepts the passcode.

## 10. Notifications and background work

### 10.1 iPhone

**Push.** The relay sends an alert push with this `aps` dictionary, defined by the relay:

| Key | Value |
| --- | --- |
| `aps.alert.title-loc-key` | `REQUEST_TITLE` |
| `aps.alert.loc-key` | `REQUEST_BODY` |
| `aps.mutable-content` | `1` |
| `aps.category` | `SEALCTL_REQUEST` |
| `aps.thread-id` | `requests` |
| `aps.interruption-level` | `time-sensitive` |
| top-level `type`, `id`, `expires` | the push type (`request`), the request id, the request's expiry |

The app's string catalog defines the two keys, so iOS shows them in the phone's language even when the extension cannot run:

| Key | English |
| --- | --- |
| `REQUEST_TITLE` | "Waiting for your phone" |
| `REQUEST_BODY` | "A machine is asking for a key. Open to see the request." |
| `DELAYED_TITLE` | "Approved on your phone" |
| `DELAYED_BODY` | "Something sensitive was approved on your phone and starts in two hours. Open sealctl to see it or cancel it." |
| `CANCELLED_TITLE` | "Cancelled" |
| `CANCELLED_BODY` | "A pending sensitive action was cancelled." |

Nothing about the machine, the agent, the key or the sealed request goes through Apple.

**Notification Service Extension** (`NotifyExtension`), about 30 seconds and 24 MB:

1. Read the phone keys from the keychain. Before the first unlock since boot they cannot be read: deliver the push unchanged.
2. List pending requests (`GET /v1/phones/{phone}/requests`); open the one named by `id`.
3. If `decide` says Automatic and the root can be read: seal and post the reply, write the result to `inbox/`, then:
   - **with** the `com.apple.developer.usernotifications.filtering` entitlement: suppress the notification by delivering an empty `UNNotificationContent`; nothing shows;
   - **without** it: deliver a passive notification, "Opened dev@mbp.example.com at Desk." (`interruptionLevel = .passive`, no sound, no badge), which goes to Notification Center without lighting the screen. The app removes it the next time it runs.
4. If One tap: rewrite the title and body (11.7), replace the category `SEALCTL_REQUEST` with the kind's category below, set `threadIdentifier` to the machine key, `userInfo` with the request id and `expires`, keep `interruptionLevel = .timeSensitive`, `relevanceScore = 1`.
5. If the request is already gone (answered on another install, or expired), at the list or when its own reply gets `404 gone`: deliver a passive "dev@mbp.example.com stopped waiting." or, with the filtering entitlement, nothing.
6. A `delayed` push for a phone-only record this install did not start (its id is not among the snapshot's delayed actions of known kind, which include one the app is still starting, and the relay's list has it waiting with no machine): rewrite it to "A protected action started on another of your devices" / "It goes ahead at 11:00. Open sealctl to see it or cancel it.", which opens its delay screen (11.23). Any other `delayed` push is delivered unchanged.
7. On any failure or timeout (`serviceExtensionTimeWillExpire`): deliver the push unchanged.

**Categories and actions.**

| Category | Actions, in order | Options |
| --- | --- | --- |
| `SEALCTL_REQUEST` | none; tapping opens the app, which fetches the request | Set by the relay; left only when the extension could not open the request |
| `REQUEST_OPEN` | `ALLOW_SESSION` "Allow for this session"; `ALLOW_ONCE` "Allow once"; `DENY` "Deny" | Allow actions: `.authenticationRequired`. Deny: `.destructive` |
| `REQUEST_AGENT` | `ALLOW_REMEMBER` "Allow"; `ALLOW_ONCE` "Allow once"; `DENY` "Deny" | Same |
| `REQUEST_OWN` | `ALLOW_ONCE` "Allow once"; `DENY` "Deny" | Same |
| `REQUEST_APP` | none; tapping opens the app | Every level 2 and 3 request (9.6), `old_words`, and `delayed` and `cancelled` pushes |

- `.authenticationRequired` makes a locked iPhone ask for Face ID, Touch ID or the passcode before the action runs. The action runs in the background (no `.foreground`). After the unlock the root can be read. The app handles it in `userNotificationCenter(_:didReceive:)` inside `beginBackgroundTask`.
- Deny needs no unlock: it reveals nothing and gives nothing.
- If the root still cannot be read when an Allow action runs (for example an action tapped on a paired Apple Watch while the iPhone is locked), the app delivers "Unlock your iPhone to answer dev@mbp.example.com." and leaves the request pending.
- `hiddenPreviewsBodyPlaceholder`: "A machine is waiting for your phone."

**If APNs goes through FCM.** The relay may not be able to reach APNs directly (APNs needs HTTP/2 from the Worker; unconfirmed). Then iOS pushes go through FCM with the same APNs key, and the payload Apple delivers is the same. The app is built for both from M4:

- A build setting `PUSH_TRANSPORT` = `apns` (default) or `fcm`.
- `apns`: the app registers `{"platform": "apns", "token": <hex APNs token>}`; no Firebase code is linked.
- `fcm`: the app links `FirebaseMessaging` (Swift Package, no Analytics), sets `FirebaseAppDelegateProxyEnabled` to `NO`, hands the APNs token to Firebase, and registers `{"platform": "fcm", "token": <FCM token>}`. The extension needs no Firebase code: the delivered payload is the same. The privacy answers then add the Firebase installation id (14.2), and Firebase's own privacy manifest ships with it.
- Release builds pick one transport once the relay confirms which one it uses.

**Foreground.** `willPresent` returns no presentation for `REQUEST_*` notifications, because the approval card is already on screen.

**Expiry.** iOS cannot remove a notification at a set time. On every launch, foreground, push and answer, the app removes delivered notifications whose `expires` has passed, and those it answered by other means. A tap on a stale notification opens the card in its "stopped waiting" form.

**Other notifications** (local, scheduled by the app):

| Event | Text | Level |
| --- | --- | --- |
| Left a place | "You left Desk. Locked dev@mbp.example.com." | `.passive` |
| Place learned | "Trust this place? You opened your machines here on 3 mornings." | `.active` |
| Yearly check due | "Time for the yearly card check. Have your card nearby; it takes a minute." | `.active`, 10:00 local, repeated weekly until done |
| Words 2 years old | "Your words are 2 years old. Changing them takes about 10 minutes and a new blank card." | `.active`, repeated monthly until done |
| Machine unseen 90 days | "dev@mbp.example.com hasn't been seen for 90 days. Unpair it?" | `.passive` |
| Old words requested | "dev@mbp.example.com has an object sealed with seed 7Hq3. Open sealctl to move it." | `.active` |
| Delay over, action on the phone | "Ready: open sealctl to finish leaving." (or "…to finish showing your words.", "…to finish deleting your relay data."), body "Open it by 12:37, or it has to start again." (`expires`) | `.timeSensitive`, at `releaseAt`: a `UNTimeIntervalNotificationTrigger` added at the start, which iOS delivers on time; removed with a cancel, a finish, or a record the relay no longer has (11.23) |
| Hand-back report | "dev@mbp.example.com handed back 9 objects. 0 failed." | `.active` |

**Entitlements and capabilities:** Push Notifications; Time Sensitive Notifications; App Groups; Keychain Sharing; `com.apple.developer.usernotifications.filtering` (requested from Apple; the app works without it). Background Modes: none needed. Region monitoring wakes the app without the location background mode.

**Badge:** the number of requests waiting for a tap.

### 10.2 Android

**Push.** FCM data-only message, `HIGH` priority, `data: {"type", "id", "expires"}` with `expires` as a string of Unix milliseconds. Data-only, so the app always builds the notification itself. A `type` the app doesn't know is ignored.

**`SealctlMessagingService.onMessageReceived`:** the same steps as the iOS extension. The phone is unlocked when `KeyguardManager.isDeviceLocked` is false and the root key can be used. For long work it hands off to an expedited `WorkManager` job.

**Channels:**

| Channel id | Name | Importance | Used for |
| --- | --- | --- | --- |
| `requests` | Requests | `IMPORTANCE_HIGH` (heads-up) | One-tap requests |
| `answered` | Answered by itself | `IMPORTANCE_MIN` | "Opened dev@mbp.example.com at Desk.", auto-dismissed after 60 s |
| `places` | Places | `IMPORTANCE_LOW` | Leaving a place, "Trust this place?" |
| `card` | Card and words | `IMPORTANCE_DEFAULT` | Yearly check, 2-year change, old words |
| `machines` | Machines | `IMPORTANCE_LOW` | Unseen for 90 days |
| `sensitive` | Sensitive and leaving | `IMPORTANCE_HIGH` | Level 2 and 3 requests (no action buttons), delayed actions, cancels, hand-back reports |

The `answered` notification exists because Android may lower the priority of an app whose high-priority messages show nothing. The user can turn that channel off.

**Request notification.** Built with `NotificationCompat`:

- `setTimeoutAfter(expires - now)`, so it disappears when the machine gives up;
- `setOnlyAlertOnce(true)`, tag = request id;
- `VISIBILITY_PRIVATE` with a public version "A machine is waiting for your phone.";
- a `contentIntent` that opens the approval card.

The `contentIntent` targets a small activity that is not exported: it hands the request or screen to the main activity in memory and finishes. The main activity is exported (the launcher and the pairing link), so it reads no extras; another app that starts it only opens the app, and a `VIEW` intent opens the scanner only for `https://sealctl.com/p`.

Actions are the same as on iOS, with the same titles. On Android 12 and later each Allow action uses `setAuthenticationRequired(true)`, so a locked phone asks for its unlock first. On Android 9 to 11 the notification has no action buttons; tapping it opens the card, and the keyguard asks for the unlock before the activity shows (`setShowWhenLocked(false)`).

**Action receiver.** `ApprovalActionReceiver` uses `goAsync()` and finishes within 9 seconds. If the reply is not done by then, it hands the reply to an expedited `WorkManager` job.

**Permissions:** `POST_NOTIFICATIONS` (asked in onboarding, Android 13+); `SCHEDULE_EXACT_ALARM` for the "Ready" alarm below, which the person grants in Alarms & reminders (never asked for at the start; not `USE_EXACT_ALARM`, which Google Play keeps for alarm and calendar apps). No full-screen intent, no `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.

**"Ready" at the end of a delay.** The note of 10.1 ("Ready: open sealctl to finish …", in the `sensitive` channel, timing out at `expires`) comes from an `AlarmManager` alarm at `releaseAt`, set when the action starts; a `WorkManager` job is not used, because Doze and app standby can hold one back far past `releaseAt` and the window to finish is an hour. The alarm is `setExactAndAllowWhileIdle` (`RTC_WAKEUP`) when `canScheduleExactAlarms()` is true (always below Android 12), else `setAndAllowWhileIdle`, which needs no permission and still fires in Doze, though Android may deliver it later than asked; `setAlarmClock` and `setWindow` are not used (the first needs the same permission, the second does not fire in Doze). While such an action waits and exact alarms are not allowed, its delay screen says "Android may tell you late when this is ready. To be told on time, allow alarms for sealctl." [Allow alarms], which opens Alarms & reminders for the app. The alarm wakes a receiver that is not exported; it asks the relay's list first (at most 8 seconds; without an answer the note is posted anyway, since `finish` asks the relay again) and posts the note unless the action was cancelled, finished or is gone. A cancel, a finish, or a record the relay no longer has takes back the alarm and the note. Alarms do not survive a reboot or a force stop: they are set again at boot, after an update, when exact alarms are allowed or taken away (`SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED`), and when the app starts; after a reboot the note of an action already ready is posted again. Taking the permission away ends the app (Android does so); its next start sets the alarms again, inexact.

**Background restriction.** If `ActivityManager.isBackgroundRestricted()` is true, Settings and the Machines tab show: "Android is limiting sealctl in the background. Requests may arrive late." [Open settings]

**Boot and update.** `RECEIVE_BOOT_COMPLETED` and `MY_PACKAGE_REPLACED` re-register geofences and the "Ready" alarms; so does every start of the app's process and the first foreground after location "Allow all the time" is given (11.9). The app is not direct-boot aware: before the first unlock after a reboot it does nothing, and requests expire on the machine.

### 10.3 Battery

| Activity | iPhone | Android |
| --- | --- | --- |
| Waiting for requests | None: alert pushes only | None: high-priority FCM only |
| WebSocket | Foreground only | Foreground only |
| Places | `CLMonitor` circular conditions (system region monitoring) | Geofences with `setNotificationResponsiveness(120000)` |
| Location samples | One fix at the first approval of the day, at most 10 seconds | Same, `getCurrentLocation` with balanced power first, high accuracy if accuracy is above 100 m |
| Periodic work | None; reminders are scheduled local notifications. `prune` runs when the app comes to the foreground, at most once a day | One daily `WorkManager` job: prune, sync if due, refresh the FCM token |

### 10.4 Notification check

Settings has "Send a test request". It calls `POST /v1/phones/{phone}/push/{device}/test` for this install. The phone shows "Test from the relay. Requests reach this phone." If nothing arrives within 30 seconds, Settings says: "No test notification arrived. Check that notifications for sealctl are on." [Open settings]

- `502 push_failed` with `removed: true`: the push service rejected the token. The app gets a fresh token, registers it again and says "This phone's notification address was out of date. It has been renewed. Try again."
- `502 push_failed` otherwise: "The push service refused the test (reason)."
- `503 push_not_configured`: "The relay can't send notifications right now."

## 11. Screens and flows

Wording in this section is exact. Text in quotes is shown as written. `dev@mbp.example.com`, `OPENAI_API_KEY`, `7Hq3`, `Desk` and similar are examples of values filled in. Button labels are in square brackets.

### 11.1 Visual style

- Colours from the brand tokens (cool neutrals, one crimson accent): paper `#ffffff` / `#0e121a`, surface `#f6f7f9` / `#151a24`, surface-2 `#eef0f4` / `#1b2130`, ink `#1a2133` / `#eef0f5`, muted `#5f6677` / `#949bad`, border `#e3e6ec` / `#242b3a`, accent sealing wax `#b4232c` / `#ff5c63`, accent soft `#f8e3e5` / `#3b2327`, text on accent `#ffffff` / `#12151c`. Light and dark follow the system. Android's launch window is paper.
- Status colours are separate from the accent: Open uses green `#157f3c` / `#4cc47c`; Waiting uses amber `#b45309` / `#f0a54a`; Locked uses muted ink. Every status also has its word; colour is never the only signal.
- Text in the system sans (SF Pro, Roboto). Machine names, key names, commands, paths, tags, the words fingerprint and the wordmark in the system monospace (SF Mono, `FontFamily.Monospace`). No bundled fonts.
- The words fingerprint is labelled "seed" on screen ("seed 7Hq3", "Seed fingerprint", "Seed 7Hq3 (retired)"); "words" stays for the 24 words themselves ("Show words", "your 24 words", the words backup).
- Cards have 12-point corners and soft shadows. The primary button is filled with the accent; secondary buttons are outlined; Deny is a plain text button.
- The wordmark `sealctl` (lower case, monospace, weight 600) sits at the top of Welcome and About.
- App icon from `brand/app-icon.svg`: the shield and prompt in white on sealing wax, full bleed. iOS 18+ dark variant: shield `#ff5c63` (the dark accent) on `#0e121a`. Tinted variant: the glyph alone. Android adaptive icon: the glyph as foreground, `#b4232c` as background, the glyph as the monochrome layer.
- Animation: the Waiting dot pulses; nothing else moves. Reduce Motion stops the pulse.

### 11.2 Main screens at a glance

| Tab | Shows |
| --- | --- |
| Machines | Waiting banner, machine list with state, [Pair a machine], [Lock all] |
| Activity | Monthly summary, usage log by day |
| Inventory | Every key handed out, by machine |
| Settings | Words, backups, places, answers, notifications, relay, this phone, about |

### 11.3 Onboarding: create words

The steps cannot be skipped. If the app is closed, it resumes at the last step not done. Words exist only on the phone until step 6 passes; nothing is uploaded and no machine can be paired.

**Step 0. Screen lock check.** If there is no passcode or screen lock, show `NeedsScreenLock` (11.20).

**Step 1. Welcome.**

> `sealctl`
> **Your phone holds the keys.**
> When an agent on your computer needs a key, your computer asks this phone. You tap Allow, and the key goes into that one command.
> [Create new words]
> [Restore]
> No account. Privacy · Terms

"Privacy" opens `https://sealctl.com/privacy`; "Terms" opens `https://sealctl.com/terms`. If a backup was found, Welcome shows 11.4 instead.

**Step 2. About the words.**

> **24 words open everything**
> Every key sealctl hands out comes from 24 words. You write them by hand on a paper card. With the card, you can get everything back on a new phone or open your files with no phone at all.
> The app never shows the words for printing, copying or photos.
> [Next]

**Step 3. Print a blank card.**

> **Print a blank card**
> The card has 24 numbered lines with four boxes each: the first four letters are enough to know each word. It folds to wallet size.
> [Print]  [Share PDF]
> Paper size: A4 · Letter
> [I have a blank card]
> No printer? Any paper works. Number 24 lines.

The paper size defaults to Letter for regions that use it (US, CA, MX, PH, CL, CO, VE) and A4 elsewhere. [Print] opens `UIPrintInteractionController` or `PrintManager`. [Share PDF] opens the share sheet with `sealctl-card-a4.pdf` or `sealctl-card-letter.pdf`. Both PDFs are blank: no words, no fingerprint, no date.

**Step 4. Get ready.**

> **Write where no camera can see**
> Screenshots and screen recordings hide the words. Write each word in full, in the boxes and on the line.
> [Show my words]

[Show my words] asks for Face ID, Touch ID or the passcode on iOS ("Face ID protects showing and changing your 24 words."), or `BiometricPrompt` on Android (title "Show your words", subtitle "Use your fingerprint, face or screen lock", allowed authenticators `BIOMETRIC_STRONG | DEVICE_CREDENTIAL`).

**Step 5. The words.** Four pages of six words. Each row shows the number and the word in large monospace, the first four letters bold.

> **Words 1 to 6**
> 1 **ocea**n
> 2 **brid**ge
> …
> [Next]

The last page adds:

> **Now fill in the card**
> Seed fingerprint: `7Hq3`
> Written on: 2026-11-21
> [I've written all 24]

The fingerprint and date are shown so the user copies them onto the card. The date is always ISO.

**Step 6. Check the card.** Three positions are chosen at random, at least one from each half. For each:

> **Check your card · 1 of 3**
> Which is word 7?
> [harvest] [hamster] [harbor] [happy]

Wrong choices are drawn from BIP39 words with the same first letter.

- Wrong answer: "That's not word 7. Look at your card again." The same position is asked again with new choices.
- After two wrong answers on one position: [Show the words again] appears, which goes back to step 5 (Face ID again).
- After three right answers: the words are checked. The app stores "written on" and moves to `Ready`.

**Step 7. Backups.**

> **Backups**
> **Paper card** · Written and checked
> **iCloud Keychain** [on]
> A new iPhone on the same Apple Account restores without the words. End-to-end encrypted by Apple.
> **Encrypted backup on the relay** [on]
> Your machines, places, answers and inventory, encrypted with a key only your words can make. It does not hold your words.
> [Continue]

Android replaces the second row:

> **Google backup** [on]
> A new Android phone on the same Google account restores without the words. End-to-end encrypted because this phone has a screen lock.

When Block Store end-to-end encryption is not available, that toggle is off and disabled: "Off: Google can't end-to-end encrypt it on this phone." When the iCloud Keychain item cannot be saved, the row reads "Couldn't save to iCloud Keychain. Is iCloud Keychain on in Settings?" [Try again]

**Step 8. Notifications.**

> **Requests arrive as notifications**
> When a machine needs a key, this phone shows a notification. You answer with one tap. A locked phone asks for its unlock first.
> [Allow notifications]
> [Not now]

iOS asks for `.alert`, `.sound`, `.badge`. Android 13+ asks for `POST_NOTIFICATIONS`.

**Step 9. Places.**

> **Learn your places?**
> sealctl can learn where you work. At a trusted place, reopening your machine needs no tap while your phone is unlocked and near it, and leaving locks the machines you opened there. Locations stay on this phone.
> Without places, a session stays open up to 1 hour and reopening always takes a tap.
> [Allow location]
> [Not now]

iOS: When In Use first, then Always (`requestAlwaysAuthorization`) at the first approval of the day after the user's first trusted place, with its own explanation (11.9). Android: `ACCESS_FINE_LOCATION`, then `ACCESS_BACKGROUND_LOCATION` from a second screen that explains why. [Open settings] requests `ACCESS_BACKGROUND_LOCATION`, which on Android 11 and later opens the app's location page in the system settings (the only way to "Allow all the time" there); on Android 10 the system asks in a dialog. When the system shows nothing (the person declined before), the app's settings page opens instead:

> **Allow location all the time**
> sealctl needs it to notice when you leave a trusted place and lock your machines. It checks only when you cross the edge of a place. Locations stay on this phone.
> In the settings, choose Permissions, Location, then "Allow all the time".
> Without it, a session stays open up to 1 hour and reopening always takes a tap.
> [Open settings]  [Not now]

**Step 10. Pair your first machine.**

> **Pair a machine**
> On your computer, run:
> `sealctl pair`
> Then scan the code it shows.
> [Scan code]
> [Later]

### 11.4 Restore

**Backup found.** On first launch the app looks for `com.sealctl.words.sync` (iOS) or `com.sealctl.words.v1` (Block Store).

> `sealctl`
> **Your words are in iCloud Keychain**
> Seed `7Hq3`, saved on 2026-11-02.
> [Restore 7Hq3]
> [Restore from paper]
> [Create new words]

Android says "in your Google backup". If more than one set is found, the newest is first and the others are listed by fingerprint and date. On iOS, iCloud Keychain may still be syncing on a new phone, so Welcome also shows [Check iCloud Keychain again] for 10 minutes after first launch.

[Restore 7Hq3] asks for Face ID or the passcode, writes the device-only items and continues at "Restoring your data" below.

**Restore from paper.**

> **Type your 24 words**
> Four letters are enough. Each word completes itself.

There are 24 numbered fields. Entry uses an in-app keypad with the letters a to z and delete, so no system keyboard sees the words. A hardware keyboard also works. After the four letters that identify a BIP39 word, the word fills in and focus moves on. Letters that cannot start any valid word are disabled on the keypad.

- When all 24 are filled, the core checks them. Wrong checksum: "These words don't fit together. Check the order and spelling against your card." The field with the first unknown word is marked: "No word starts with 'qzab'."
- Right: "This is seed `7Hq3`. Does your card say 7Hq3?" [Yes] [No, check again]. A card without a fingerprint (written by hand without the box) can still answer [Yes].

**Restoring your data.** The app derives the phone keys and downloads the state.

> **Found your backup**
> 3 machines · 2 places · 14 answers · 52 inventory items
> [Continue]

If the state is empty: "No relay backup for these words. Your machines will need sealctl pair again, unless they are still paired: they reconnect by themselves." The app then lists machines from `GET /machines`. Those remain paired, because pairings are kept under the phone key.

**Was the old phone lost?** After any restore:

> **Where is your old phone?**
> [I still have it, or it was reset]
> [It was lost or stolen]

"Lost or stolen" leads to:

> **Change your words now**
> Your old phone holds these words behind its passcode. Changing them makes sure it can't open anything new. It takes about 10 minutes and a new blank card.
> [Change words now]
> [Remind me tomorrow]

Then the backups screen (step 7) and the notification step (step 8), then `Ready`. This install registers its own push device, so it gets requests alongside any other install with the same words (8.7).

### 11.5 Pairing

Entry points: onboarding step 10, [Pair a machine] on the Machines tab, and opening a pairing link from the system camera (19.1 asks for the QR code to be a `https://` link the app claims, so the system camera opens it).

**Scan.**

> **Scan the code**
> Run `sealctl pair` on your computer and point the camera at the code.

The camera fills the screen with a square guide. Camera permission text (iOS `NSCameraUsageDescription`, Android rationale): "The camera scans the pairing code that sealctl pair shows on your computer." Denied: "The camera is needed to scan the pairing code. Allow it in Settings." [Open settings]

**Confirm.** After a valid code:

> **Pair this machine?**
> `dev@mbp.example.com`
> macOS 26 · MacBook Pro · `#k7m2`
> It will be able to ask this phone for keys. You still approve every request.
> [Pair]
> [Cancel]

[Pair] asks for biometrics (level 2, 9.6: "Confirm pairing dev@mbp.example.com."; the first pairing on a phone asks two words from the card before that, 9.6), reads the phone keys (the root is not needed), computes the proof, and posts the machine. If the name matches a paired machine, the duplicate card (11.6) comes first.

The app's own camera is the proof of proximity for pairing. A pairing link opened any other way (tapped in a message, opened by the system camera) leads to the scanner with: "Scan the code with sealctl. On a computer without a terminal, open the link in its browser to see the code." The website's `/p` page draws the code from the link's fragment (19.3).

- Success: "Paired. dev@mbp.example.com can now ask this phone for keys." The machine appears Locked.
- Errors are in 11.20.

### 11.6 Duplicate-machine card

Shown when a scanned machine has the same `user@host` as a paired one. Exact wording from the design:

**Same name, same hardware hint:**

> **Already paired**
> dev@mbp.example.com is already paired (same hardware, last seen 2 days ago). Replace it?
> [Replace]
> [Pair as new]
> [Cancel]

**Same name, different hint:**

> **Same machine?**
> Another machine is already called dev@mbp.example.com (MacBook Air, paired 2027-03-02). Same machine?
> [Yes, replace it]
> [No, another machine]
> [Cancel]

- **Replace / Yes:** the new machine is paired, then the old pairing key is deleted (`DELETE .../machines/{old}`). Answers, inventory items, usage entries and the day record move from the old key to the new one.
- **Pair as new / No:** both stay paired and both show their tag: `dev@mbp.example.com #k7m2`. "Pair as new" covers cloned virtual machines that share `/etc/machine-id`.

### 11.7 The approval card and notifications

The card is a sheet over any screen. In the foreground it appears as soon as the request arrives. A notification tap opens it. It stays until the request is answered, closed or gone: it can't be swiped down or tapped away. On Android, back leaves the app with the card still waiting, and closes a card whose request stopped waiting (Close).

**Layout:**

```text
WAITING · 0:12                         (amber, pulsing dot; time since created)
Allow OPENAI_API_KEY?                  (title; the subject in monospace, accent colour)
For    npm test                        (facts: label muted, value monospace)
In     ~/dev/shop
From   dev@mbp.example.com · claude
[ Allow for this session ]             (primary)
[ Allow once ]                         (secondary)
  Deny                                 (text button)
At Desk, this answers by itself.       (muted, only when the phone is inside a trusted place)
```

**Titles by subject:**

| Subject | Title |
| --- | --- |
| A secret | "Allow OPENAI_API_KEY?" |
| A volume | "Mount volume clients?" |
| A backup | "Back up to r2:acme-backups?" |
| An SSH key | "Use SSH key github?" |
| No single subject (session open with `sealctl open`) | "Open dev@mbp.example.com?" |
| `keys` for a new object | "Allow volume clients?" (or the backup or key name) |

**Facts:** "For" is the command, cut in the middle with an ellipsis after 80 characters (the full command on tap). "In" is the working directory with `~` for home. "From" is the machine's display name (nickname, or `user@host` and the tag when shown) and the agent: `claude`, `codex`, `gemini`, `qwen`, `copilot`, `cursor`, or nothing when a person typed the command. Facts the request lacks are left out.

**Text from the machine.** Every string the machine controls (subject, names, agent, command, working directory, repository, object paths, plan items, report lines, the machine's name) passes `display_text` in the shared core before it is shown on the card, the plan, a report or a notification: line breaks and tabs become spaces; other control characters, bidi embeddings, overrides, isolates and marks (U+202A to U+202E, U+2066 to U+2069, U+200E, U+200F, U+061C) and invisible format characters become U+FFFD, so an attempt to reorder or hide text shows instead of working. The subject, names and repository are cut in the middle after 60 characters, the agent after 40, the command, working directory and paths after 80, the machine's name after 64 (its tag always shows). A tap on the title or the facts shows the values in full, still sanitised.

**By kind:**

| Kind | Buttons | Note under the facts |
| --- | --- | --- |
| `open` | [Allow for this session] [Allow once] Deny | When the request comes from an agent's first use: "First use of this key by claude in shop. Allow is remembered." |
| `agent` | [Allow] [Allow once] Deny | "First use of this key by claude in shop. Allow is remembered; remove it in Answers." |
| `own` | [Allow once] Deny | "This key asks every time. It stays in memory only until the command exits." |
| `keys` | [Allow] Deny | "sealctl seal of a new object on this machine." when the command is `sealctl seal` (taking over an existing object is level 2, 11.23) |

**After an answer**, the sheet closes with a short confirmation for 1.5 seconds: "Allowed for this session", "Allowed once", "Remembered for claude in shop", "Denied". Success haptic on Allow.

**Several waiting:** the card shows the oldest; under the buttons: "2 more waiting". Answering moves to the next.

**Expired while open:** the state line turns muted, the buttons go, and the card says "dev@mbp.example.com stopped waiting." [Close]

**Notification text** (One tap):

| Kind | Title | Body |
| --- | --- | --- |
| `open` | "Allow OPENAI_API_KEY?" | "npm test in ~/dev/shop · dev@mbp.example.com · claude" |
| `agent` | "Let claude use OPENAI_API_KEY?" | "First use in shop · npm test · dev@mbp.example.com" |
| `own` | "Allow DEPLOY_TOKEN once?" | "./deploy.sh in ~/dev/shop · dev@mbp.example.com" |
| `keys` | "Allow volume clients?" | "dev@mbp.example.com" |
| `rewrap` (level 2) | "Move dev@mbp.example.com to new words?" | "Open sealctl to confirm with Face ID." |
| `keys` for `seal` (level 2) | "sealctl seal on dev@mbp.example.com" | "Open sealctl to see what it takes over." |
| `unseal`, level 2 | "Hand back from dev@mbp.example.com?" | "Open sealctl to see what." |
| `unseal`, level 3 | "Leave sealctl on dev@mbp.example.com?" | "Open sealctl to confirm. You'll need the number on its screen." |
| generic (the extension could not open it) | "Waiting for your phone" (`REQUEST_TITLE`) | "A machine is asking for a key. Open to see the request." (`REQUEST_BODY`) |

Notification actions are listed in 10.1. Level 2 and 3 texts use only the machine's name from the phone's own records, never text the machine sent, and the requests open the screens of 11.23 instead of this card.

### 11.8 Machine states

Each machine row shows one state, from the machine's last status (`GET .../status`, 8.2) and the pending requests.

| State | Row text | Detail text |
| --- | --- | --- |
| Locked | "Locked" | "No keys in memory. Volumes unmounted." |
| Open | "Open · 2 h 10 min left" | "Opened at 09:02 at Desk. Hard stop at 02:00." |
| Waiting | "Waiting · 0:12" | "A request is on this phone." [Show] |
| Unknown | "Seen 2 h ago" | "This machine hasn't reported its state yet." |

"Time left" counts down locally from the reported idle allowance and is corrected at each report. A machine that has not reported for longer than its allowance shows "Locked · last report 3 h ago".

### 11.9 Places

**Learning.** At each first approval of the day with location permission, the app takes one location sample (10.3) and passes it to `place_sample`. A sample joins a candidate when it is within 100 m of the candidate's centre and its accuracy is 100 m or better. When a candidate has samples on 3 different days, the app asks once (a sample's day is the local date it was taken on, by the UTC offset at that time; a later change of daylight saving time or time zone does not date it again):

> **Trust this place?**
> You opened your machines here on 3 mornings: Nov 18, 19 and 21.
> At a trusted place, reopening needs no tap while your phone is unlocked and near the machine, sessions can stay open up to 4 hours, and leaving locks the machines you opened here. The location stays on this phone.
> Name: [Place 1]
> [Trust]
> [Not this place]

- [Trust] creates a place with a 150 m radius, starts monitoring it, and announces it (Trusting a place, below). On iOS, if only When In Use was given, it then asks for Always with "To lock your machines when you leave Desk, sealctl needs location access Always. It wakes only when you cross the edge of a place." The system shows that prompt once; later the banner below sends the person to the settings. On Android, if location is not allowed all the time, the "Allow location all the time" screen of 11.3 step 9 follows. "Trust where I am now" does the same.
- [Not this place] marks the spot so the app never asks about it again.
- There is no map. Places are named by the user, never by an address lookup.
- At most 10 places.

**Trusting a place.** A place's comforts (no tap to reopen nearby, longer sessions, locking on leaving) start as soon as it is trusted. Skipping the two-hour level 3 wait (9.6) does not: someone holding the unlocked phone could otherwise trust "here" and show the words at once. So trusting a place, learned or with "Trust where I am now", is announced the way a delayed action is:

- The app registers a phone-only delayed record of two hours (`POST .../delayed`, the same as an action on the phone, 9.6) and keeps its id with the place (`trust_id`, `trust_from` = its `releaseAt`). The relay announces it on every paired machine (the CLI says "a sensitive action was approved on your phone. It takes effect at 12:04. Not you? Run: sealctl cancel") and every install. Its kind on this install is `place`; another install shows it as "Started on another of your devices".
- Any of them can cancel it until it ends. A cancel, wherever it comes from, removes the place. Removing the place within the two hours cancels the record.
- When the two hours are over, the next time the app reads the relay's list (the foreground, a note, a push; on Android also the alarm at `releaseAt` of 10.2, which posts nothing for it) it calls `finish`; only on `200` is the place confirmed (`trusted_at`), and only a confirmed place lifts the wait (`place_settled`). `finish` goes out only while the record is still waiting or released on the phone and the place is not confirmed yet, and one at a time per record, so a read of the list made before the confirmation, or two reads at once (the alarm and the app), never send it again; a later `404 gone` never replaces "finished" (11.23). `409 cancelled` removes the place. A record that ended unconfirmed (the relay keeps it an hour after `releaseAt`) leaves the place trusted for its comforts but not for the wait, and its row offers [Confirm again], a new two hours.
- If the relay can't be reached when the place is trusted, the place is kept unconfirmed in the same way, with [Confirm again].
- The machines' own `notice` naming the place is not sent yet: the `notice` kinds (`unseal_all`, `leave`, `words`, `delete`) have none for a place, and the CLI shows an unknown kind as raw text under "approved … away from a trusted place". Needed from sealctl/sealctl (19.1): a `notice` `what: "place"` with the place's name, which the CLI shows as "sealctl: your phone trusted the place Home. It skips the two-hour wait from 12:04. Not you? Run: sealctl cancel", and as "cancelled from your phone: trusting Home" for `state: "cancelled"`. Until then the relay's own note above is the announcement.

Each place's row says where it stands: "Skips the two-hour wait from 12:04, unless one of your computers cancels it." while announced; "Not confirmed with the relay yet, so it doesn't skip the two-hour wait." [Confirm again] when it ended unconfirmed; nothing once confirmed. "Trust where I am now" says before [Trust]: "Showing your words and leaving sealctl skip the two-hour wait here from 12:04, two hours from now. Every paired computer is told and can cancel it until then, so someone holding your unlocked phone can't trust a place unseen." The Machines banner while it is announced: "Home skips the two-hour wait from 12:04, unless one of your computers cancels it." [Show] [Cancel]; its delay screen, "Trusting Home", adds "Every paired computer has been told, and can cancel it with sealctl cancel. Cancel here and the place is not trusted."

**Monitoring.** iOS: one `CLMonitor` named `places`, one `CLMonitor.CircularGeographicCondition` per place, added assuming unsatisfied. Android: one geofence per place with `GEOFENCE_TRANSITION_ENTER | GEOFENCE_TRANSITION_EXIT`, `NEVER_EXPIRE`, registered with `INITIAL_TRIGGER_ENTER`, so a phone already inside gets its enter as soon as the geofences are registered. The current inside or outside state is stored and copied to the extension snapshot, with whether location access is Always.

**The current place after a restart.** The system ends the app's process for memory and starts it again for a push; the place the phone is inside must not be lost, nor kept after the phone left.

- iOS: at launch the monitor sends only what changed while the app was not running, so the app first reads each condition's record (`CLMonitor.record(for:)`, last event satisfied), as `requestState(for:)` did for region monitoring. With Always only: with When In Use the system watches the edges only while the app is in use.
- Android: the place the phone entered is kept on the phone (its id and the boot count, never a location) and comes back at a start of the process only while every exit from it would have been seen: location all the time, the same boot, the geofences still registered (their `PendingIntent` still exists: a reboot, a force stop or an update cancels it) and the place still trusted. Otherwise no place counts until the geofences' initial enter. The geofences are then registered again, and an exit clears the kept place.
- Location turned off (`GEOFENCE_NOT_AVAILABLE` on Android; an unknown state on iOS): the place stops counting, which is not an exit, so nothing is locked. On Android the geofences are registered again at the next foreground.

**Without location access Always.** Places count for nothing (9.4: `none`). While a trusted place exists and location is not allowed all the time, the Machines tab, Settings and the Places screen show a banner, with [Open settings] (Android: the request of 11.3 step 9; iOS: the app's settings):

> Places need location set to "Allow all the time". Until then, a session stays open up to 1 hour and reopening always takes a tap.

iOS says "Places need location access Always." The permission is read again each time the app comes back to the foreground, as from the settings.

**Leaving.** On exit from a place, the app sends a lock message to every machine whose day began at that place and that is Open or was Open at its last report. The lock uses the phone keys only, so it works on a locked phone. Then it posts "You left Desk. Locked dev@mbp.example.com." (passive). The machine keeps the day's credit; that is the machine's job. An allow decided at the place that is still on its way when the phone leaves is followed, once posted, by a lock to its machine, so the lock never reaches the machine before that answer; its day is not recorded as begun at the place. The app checks for an exit again once that answer's day record is in place: an exit from then on finds the day and locks the machine itself, and one before it is covered by the answer's own lock.

**Places screen** (Settings, Places):

> **Places**
> Desk · trusted since 2026-11-21 · You're here
> Home office · trusted since 2026-12-02
> [Rename] [Remove] per place (swipe or menu)
> Places are learned: after three mornings of approving at the same spot, sealctl asks whether to trust it.

Remove: "Remove Desk? Machines opened here stay Open until their allowance ends." [Remove] [Cancel]

Without permission:

> Places need location access. Without it, a session stays open up to 1 hour and reopening always takes a tap.
> [Allow location]

### 11.10 Answers

Settings, Answers. One row per answer:

> **Claude Code** may use `OPENAI_API_KEY` in **shop**
> Last used 2 days ago

Agent display names: `claude` "Claude Code", `codex` "Codex", `gemini` "Gemini CLI", `qwen` "Qwen Code", `copilot` "Copilot", `cursor` "Cursor"; anything else is shown as sent.

- Swipe or menu: [Remove]. Removing takes effect at the agent's next use, which asks again.
- An answer unused for 80 days shows "Unused for 80 days. Removed in 10 days."
- An answer unused for 90 days answers nothing from that moment, whether or not the daily prune has removed it yet, and whatever copy a merge brought back. A use allowed once does not renew it; "Allow for this session" (which remembers) does, and so does every use it answered by itself, the iOS extension's too (recorded at the time it was answered, 6.4).
- Footer: "Agents ask once per key and repository. You at the keyboard are never asked inside an Open session. A file in a repository never grants anything."
- Empty: "No answers yet. When you tap Allow on an agent's first use of a key, it's remembered here."

### 11.11 Agent first use

When the first `agent` card ever appears, the card shows one extra line under the note, once per install:

> Agents ask once for each key in each repository. Your answer is kept on this phone, not in the repository.

### 11.12 Activity and monthly summary

**Summary** at the top of Activity, for the current month, with the previous months behind a chevron. A month's name stands alone, so it takes the language's standalone form with its first letter capitalised ("Listopad" in Polish, not "listopada", the form inside a date), here and behind the chevron:

> **November**
> 312 keys used on 3 machines
> 4 requests declined
> No key was written to disk.

Each figure takes the singular for one: "1 key used on 1 machine", "1 request declined". "Keys used" counts uses from replies and from machine reports. "Requests declined" counts Deny answers. Both count in the month by the phone's local time when the answer was given or the report reached the phone (the app passes its UTC offset to `answered`, `apply_status` and `apply_report`; an answer the iOS extension gave counts in the month it was given, 6.4), so a use near midnight on the last day of a month counts in the same month whichever way it arrived. The third line is a fixed statement of how sealctl works. No other figures, no price, no comparison.

Hand-back reports follow the summary as cards.

**Log** grouped by day, newest first. The newest day with entries (normally today) is open, two lines per use. Each of the ten calendar days before today that has entries is one closed row: the date (the locale's medium style), its figures and a chevron. A tap opens or closes a day; which days are open is kept in memory only, and the newest day starts open each time the screen is built. Days with no entries are not listed, nor days before those ten (the newest day with entries is listed even when it is older). A day's figures count its entries: "37 uses" for every entry that was allowed, and "2 declined" for Deny answers when there are any; "Expired" counts as neither (`activity_counts`). Activity for one machine (from its detail screen) lists that machine's days the same way.

```
24 Nov 2026                       37 uses · 2 declined  ˄
09:18  STRIPE_KEY                     In session
       shop · claude · webapp · sealctl run -- npm test · mbp.example.com
08:54  Volume safe                  Allowed once
       Work laptop
08:26  Seal volume safe                Confirmed
       mbp.example.com
23 Nov 2026                                  12 uses  ˅
22 Nov 2026                        8 uses · 1 declined  ˅
```

Each day header is one accessibility element: a button whose label reads the date and the figures and whose value says "Expanded" or "Collapsed".

The time sits in a narrow column with tabular figures. The rows use the text font throughout, not the monospace of 11.1. The top line, in ink, says what was used; the outcome is on its right ("Denied" in the accent colour, "Expired" muted, the others in the secondary ink). The second line is muted and smaller. One accessibility label reads the row in order: time, what, outcome, details. The rows come from `activity_row` in the shared crate (`shared/src/activity.rs`), so both apps show the same text:

- **What was used.** A secret `project/name` shows its name, and the project leads the second line. A volume reads "Volume safe", a backup "Backup r2:acme-backups", an SSH key "SSH key github"; an object asked for by id (an unseal plan, the store key) reads like Inventory, "Secret store a7c3…42". `sealctl seal` reads as the action, "Seal volume safe" (its command is not repeated). The usage entry records the request's subject kind (`kind`) for this; entries from before it, and uses a machine reports from its session (always secret names), are read from the key and the command. An SSH signature a machine reports from its session names the stored key `ssh/<name>` (the prefix sealctl keeps SSH keys under, `docs/protocol.md`) with the command "ssh signature with <name>": it reads "SSH key ed25519", as when the card asked, not as a secret `ed25519` in a project `ssh`. A key under `ssh/` used by any other command stays a secret.
- **The second line,** without empty parts: project · agent · repository · command · machine. The command reads as typed: the CLI sends its arguments without the program name, so "scan" shows as "sealctl scan". A repository equal to the machine's user name is left out: outside a git repository the CLI sends the folder, and the home folder says nothing.
- **The machine** is its nickname, else its host without `user@` and `.local` (and the tag when two machines share a name); a machine that is not paired shows "unpaired (Zq7Lr2Xa)", the first 8 characters of its key.
- Every value passes `display_text` (11.7), and UUIDs anywhere in the row are shortened to their first four and last two characters ("5D1E…71").

Outcomes: "One tap", "Answered by itself", "In session" (reported by the machine), "Allowed once", "Denied", "Expired", "Confirmed". Filters: machine, key. Empty: "Nothing yet. Every use of your keys shows here."

**Heatmap** at the bottom of the Activity tab, as GitHub's contribution graph: 53 weeks by 7 days ending today, one column a week starting on the locale's first day of the week, from the daily counts (6.4):

```
1,204 key uses in the last year
     Dec      Jan      Feb   …   Oct      Nov
Mon  ░ ░ ▒ ░ ░ ▓ ░ ░ █ ▒ …
Wed  ░ ▒ ░ ░ ▓ ░ ░ ▒ ░ ░ …
Fri  ░ ░ ░ ▒ ░ ░ █ ░ ░ ▒ …
24 Nov 2026: 37 key uses, 2 declined     Less ░ ▒ ▓ █ More
```

- The title counts the keys used in the 53 weeks shown ("1 key use", "1,204 key uses", in the locale's digits). Month labels (standalone, short) sit above the week where a month begins; Mon, Wed and Fri label their rows.
- Each cell is coloured by its keys used: empty for none, then four steps from the soft accent to the accent (`heat` in the design tokens: light `#DD969B`, `#CF7076`, `#C24951`, `#B4232C` on the border grey `#E3E6EC`; dark `#893A3F`, `#B1454B`, `#D85157`, `#FF5C63` on `#242B3A`). The steps are the quartiles of the days that have uses, interpolated, as GitHub does (`heat_levels`): up to the first quartile is the lightest, above the third the darkest. The legend "Less … More" shows the five.
- The grid scrolls sideways and opens scrolled to today at the right edge. A tap on a day shows its date and figures under the grid ("24 Nov 2026: 37 key uses, 2 declined"); a second tap clears it.
- Accessibility: the grid is one element. Its label is the title and the busiest day; its value is the chosen day. VoiceOver swipes up and down (adjustable) and TalkBack's actions move a day, and "Previous week" and "Next week" move a week, so every day is reachable without 371 stops. Labels and the legend are hidden from the screen reader.
- The counts are the phone's, not a machine's, so Activity for one machine has no heatmap.

### 11.13 Inventory

One row per derived key, grouped by machine:

> **Secret store** `3f9k…a1` · seed `7Hq3`
> `~/.sealctl/store` · 14 KB
> First used 2026-11-21 · last used today

Purpose names: `secrets` "Secret store", `secret` "Own-approval secret", `volume` "Volume", `backup` "Backup". A detail view adds the full id, the key check, the machine, the full path or URL.

- Items unseen for a year: "Not seen since 2025-11-02" in amber.
- Items on retired words: "Seed 7Hq3 (retired)".
- Filters: machine, words (current or retired).
- Empty: "No keys handed out yet."
- After a restore from paper with no relay backup: "This list was empty after restoring from paper. Machines add what they hold the next time they ask."

### 11.14 Changing the words

Entry: Settings, Words, [Change words]; or the reminders. Face ID or the passcode first.

**Why.**

> **Why are you changing words?**
> [Routine change]
> [My words may have been seen]
> [A phone or machine was lost]

"A phone or machine was lost" asks which: [My phone] continues the change; [A machine] opens the lost-machine flow (11.17), then offers [Change words too] [Done].

**New card.** Steps 3 to 6 of onboarding, with the title "Your new words". The new fingerprint is shown; the old words stay on the phone as `old` items.

**Switch.** After the check, the app runs these steps in this order, which the relay defines:

1. Derive the new phone keys.
2. New key: `PUT /v1/phones/{new}/state` with `rev` 0, holding the full state and the change record.
3. Old key: `POST /v1/phones/{old}/licence/move` with `{"to": <new>, "proof": <new key's signature over "sealctl-licence-move-v1\n<old>\n<new>">}`. Unpaid phones move too. Nothing is shown, whatever the answer.
4. New key: register every paired machine with `POST /v1/phones/{new}/machines`, with `proof` = `key_change_proof(old_keys, new_keys, machine_key)`, the 96-byte move proof signed by the old key, so the machine trusts the new phone key (19.1). The relay drops each machine from the old key and closes its waits there with `moved`.
5. New key: register this install's push device.
6. Old key: `DELETE /v1/phones/{old}`.
7. Write the new synced backup item, keeping the old one until finish.

Each step is retried until done and the progress is saved, so a closed app resumes at the next step. The screen shows "Moving your machines to the new words… step 3 of 7". Other installs with the old words stop getting pushes at step 6; when they next open, they find their phone key gone and show "Your words were changed on another phone. Restore the new words from iCloud Keychain (Android: Google backup) or your new card." [Restore]

The old words stay on this phone (the `old` items) until Finish, for rewrap and old-words requests.

**Plan.**

> **Moving to seed 4kPz**
> **dev@mbp.example.com** · Rewrapped 12 of 12
> Volume `clients` · 240 GB · Re-encrypt: about 3 h · Run `sealctl migrate` on this machine
> **ci-runner@build.example.com** · Waiting to hear from this machine
> **Not seen** (2)
> Backup `r2:acme-backups` · dev@old-laptop · last used 2026-03-01
> [Finish]

- Each machine sends a `rewrap` request when it next talks to the phone. Rewrap is level 2 (9.6): the screen of 11.23 lists its objects and asks for biometrics, one machine at a time. A machine that is not near this phone gets `not_near` and tries again at its next start; the plan row says "Not near this phone. On it, run `sealctl migrate --depth rewrap`, or bring the phone to it."
- "Words may have been seen" adds, under each volume and backup: "Re-encryption recommended: run `sealctl migrate` on this machine." The estimate comes from the machine's report.
- The phone cannot start re-encryption. Commands shown can be copied; the words never can.
- A banner on the Machines tab while the change runs: "Moving to new words · 2 of 3 machines done" [Show]

**Finish.**

If items are not seen:

> **Finish anyway?**
> 2 items haven't been reported by any machine. After you finish, only your old card opens them.
> [Finish anyway] [Keep waiting]

Then:

> **Done. Mark your old card.**
> Write "retired on 2028-03-02" on the card of seed 7Hq3. Keep it with your new card until your next change, then destroy it.
> [Done]

Finishing deletes the old words from the phone and from iCloud Keychain or Block Store. The old phone key's relay data is already gone (step 6). The retired card is recorded under Words.

### 11.15 Old words

A machine sends `old_words` for an object sealed with retired words. The notification says "dev@mbp.example.com has an object sealed with seed 7Hq3. Open sealctl to move it." The screen:

> **Type the words of seed 7Hq3**
> Sealed with seed 7Hq3, retired 2028-03-02. Type its words to move this object to your current words. The phone forgets them afterwards.
> Object: Volume `clients` on dev@mbp.example.com
> [Type the words]

Face ID or the passcode first, then the same 24-field entry as restore. If the fingerprint differs: "This is seed 4kPz, not 7Hq3. Check that you have the right card." On a match, the core derives only that object's keys, seals the reply, and the old root is released at once.

If the request expires while the user types: "dev@mbp.example.com stopped waiting. Run the command again on the machine, then type the words." The typed words are not kept.

### 11.16 Yearly check and reminders

Due 365 days after "written on" or the last check.

> **Yearly card check**
> Have your card ready. Type two words from it.
> Word 5: [____]
> Word 19: [____]
> [Check]

Same keypad and completion as restore. Positions are random, one from each half.

- Right: "Your card is good. Next check: 2027-11-21."
- Wrong: "That's not word 19 on these words." [Show the words again] [Try again]. "Show the words again" is Show words, level 3 (11.23), and shows the words as in onboarding, with "Correct your card, then check again."
- [I lost my card] at the bottom: "Write a new card" (show the words, 3-of-4 check) and then "If someone may have found it, change your words." [Change words] [Not now]

The 2-year reminder (10.1) opens 11.14.

### 11.17 Machines list, detail, nicknames, unpairing

**List.** Sorted Waiting, then Open, then Locked, then by last seen.

Each machine is a card of three lines:

> **Devs-MacBook-Pro**
> ● Open · 2 h 10 min left
> MacBook Pro · seen 2 min ago

> **Work laptop**
> ● Locked · last report 1 h ago
> Mac mini · seen 1 h ago

- The name, in the normal font, semibold, on one line (cut with "…" when too long): the nickname, else the host without `user@` and a trailing `.local` (`dev@Devs-MacBook-Pro.local` → `Devs-MacBook-Pro`). It is the same short name the Activity rows show (11.12), made by `machine_short_name` in the shared crate.
- The state: its dot and its row text (11.8), in the state's colour.
- Muted: the model, then when it was last seen. A Mac's model identifier is shown as its family (`Mac16,10` → "Mac mini"; MacBook Air, MacBook Pro, iMac, Mac Studio, Mac Pro) by `machine_model_name` in the shared crate; an identifier it does not know, and a Linux machine's product name, are shown as reported. No model reported: "seen 2 min ago" alone.

When two machines share a name, both show their tag after the name: `Devs-MacBook-Pro #k7m2`. A machine unseen for 90 days shows "Not seen for 94 days" in amber under the card's lines.

The card is one element for screen readers: "Work laptop, Locked · last report 1 h ago, Mac mini, seen 1 h ago" (on iPhone the Open state is read in words: "Open, 2 hours, 10 minutes left").

The full `user@host` and the model as reported are in the detail.

Toolbar: [Pair a machine], [Lock all]. Lock all sends a lock to every Open machine: "Locked 2 machines."

Empty: "No machines yet. On your computer, run `sealctl pair` and scan the code." [Scan code]

**Detail.**

> **dev@mbp.example.com** `#k7m2`
> Open · 2 h 10 min left. Opened at 09:02 at Desk. Hard stop at 02:00.
> [Lock now]
> Nickname: [Work laptop]  (1 to 40 characters; empty removes it)
> macOS 26 · Mac15,6 · paired 2026-11-21 · seen 2 min ago
> Keys it used → (Activity filtered to this machine)
> What it holds → (Inventory filtered to this machine)
> [Unpair]
> [This machine was lost or stolen]

The tag is always shown in the detail, so it can be matched to `sealctl status`.

**Unpair.**

> **Unpair dev@mbp.example.com?**
> It can no longer ask this phone for keys. If it is Open, it locks the next time it reaches the relay. Its history and inventory stay on this phone.
> [Unpair] [Cancel]

The app sends a lock, then `DELETE .../machines/{machine}`.

**Lost or stolen.**

> **dev@mbp.example.com was lost or stolen**
> 1. Unpair it now. [Unpair]
> 2. Change these secrets at their providers. It used them in the last 90 days:
>    `OPENAI_API_KEY` · last used 2026-11-20
>    `AWS_SECRET_ACCESS_KEY` · last used 2026-11-18
> 3. Re-encrypt what it had open. On another machine that has them, run `sealctl migrate`:
>    Volume `clients`
> Your words were never on that machine, so they don't need to change.
> [Done]

### 11.18 Settings

> **Words**
> Seed `7Hq3` · written on 2026-11-21 · next check 2027-11-21
> [Show words] [Check my card now] [Change words]
> **Backups**
> iCloud Keychain (Android: Google backup) [toggle]
> Encrypted backup on the relay [toggle] · Saved 2 min ago
> **Places** · 2 →
> **Answers** · 14 →
> **Notifications**
> On · Time Sensitive on (iOS) · [Send a test request]
> Phones getting requests →  (8.7: "This phone", "iPhone · updated today", "Android · not updated since 2026-10-02" [Remove])
> **Relay**
> `relay.sealctl.com` · Connected
> [Delete my relay data]
> **This phone**
> [Erase sealctl from this phone]
> [Leave sealctl]
> **About**
> Version 1.0.0 (412) · core 0.7.0 · protocol 1
> Source code · Licences · Privacy policy · Terms · Report a security issue

- [Show words] is level 3 (11.23): biometrics, and away from a trusted place a two-hour delay announced on every machine. It then shows the 24 words in the protected view (11.21) and tells every machine it did.
- Turning iCloud Keychain off: "Turn off the iCloud Keychain copy? A new iPhone will need your card to restore." It deletes the synced item, which iCloud also deletes from your other devices.
- Turning the relay backup off: "Turn off the relay backup? A new phone will restore your words but not your machines' names, places, answers or inventory." Machines stay paired.
- "Source code" opens `https://github.com/sealctl/app`. "Licences" lists AGPL-3.0 for the app, MIT for `sealctl-core`, and every third-party licence: the Rust crates with their licence texts (`notices/rust-crates.txt`, from `scripts/notices.sh` with cargo-about 0.9.3; rerun it when `Cargo.lock` changes, `--check` tells whether it is stale), and on Android every library in the release build with its licence, the NOTICE and non-Apache licence files the libraries ship, and the Apache-2.0 text (Gradle task `androidNotices`, run on every build). iOS bundles `notices/rust-crates.txt` and has no third-party Swift packages. "Report a security issue" opens mail to `security@sealctl.com`.

### 11.19 Delete relay data and erase this phone

**Delete my relay data.** Level 3 (11.23): biometrics at [Delete], then, away from a trusted place, the two-hour delay before the call is made.

> **Delete your data on the relay?**
> This unpairs your 3 machines and deletes what the relay keeps for these words: your encrypted phone backup, your machines' records and every phone's notification address. It can't be undone. The privacy policy lists what stays.
> Your words, what this phone keeps, and your sealed files are not touched. To use a machine again, run `sealctl pair` on it.
> [Delete] [Cancel]

When it runs, the app sends every machine a `notice` and a lock to every Open machine, then calls `DELETE /v1/phones/{phone}`. On `{"deleted": true, "machines": n}`: machines are removed from the phone, the relay backup turns off, and the screen says "Deleted. The relay has nothing for these words." Answers, places, the inventory and the log stay on the phone. Pairing a machine again works as before; the relay backup stays off until the user turns it on.

The relay keeps a licence record, if there is one, so a restore from the words is still paid (Relay API, Deleting a phone). Rule 3 forbids the app from saying so; "The privacy policy lists what stays" is the whole of what it says.

**Erase sealctl from this phone.** Face ID or the passcode first.

> **Erase sealctl from this phone?**
> This removes your words, machines, places and history from this phone. Your machines stay paired; your card restores everything on any phone.
> [ ] Also remove the copy in iCloud Keychain (Android: Google backup)
> [Erase] [Cancel]

Erase removes this install's push device (`DELETE /v1/phones/{phone}/push/{device}`), then deletes every keychain item or Keystore key and file, the database and the snapshot, then returns to Welcome. Erasing does not delete relay data; the screen offers [Delete my relay data first] above [Erase].

### 11.20 Empty and error states

| Where | Condition | Text | Action |
| --- | --- | --- | --- |
| Any | No passcode or screen lock | "Set a passcode first. sealctl keeps your words behind this phone's passcode." (Android: "Set a screen lock first…") | [Open settings] |
| Any | Root item gone (passcode removed) | "Your words were removed from this phone because its passcode was turned off. Restore them from iCloud Keychain or your card." | [Restore] |
| Any | Android key invalidated | "This phone's screen lock changed and Android removed sealctl's keys. Restore your words from your Google backup or your card." | [Restore] |
| Machines | Offline | "Offline. Requests reach this phone when it is back online." | |
| Machines | Notifications off | "Notifications are off. Requests can't reach you while sealctl is closed." | [Open settings] |
| Machines | Abuse limit | "This phone has used its relay limit for today. It resets at 01:00." (local time of next UTC midnight) | |
| Machines | Relay unreachable or 5xx | "The relay isn't answering. Trying again." | |
| Any | `401 clock_skew` after the retry | "This phone's clock is more than 5 minutes off. Turn on automatic date and time." | [Open settings] |
| Pairing | Not a sealctl code | "This isn't a sealctl pairing code." | |
| Pairing | Code expired | "This code has expired. Run `sealctl pair` again." | |
| Pairing | Newer protocol | "This machine runs a newer sealctl. Update the app." | [App Store] / [Play Store] |
| Pairing | Different relay | "This machine uses another relay (relay.example.org). This phone uses relay.sealctl.com." | |
| Pairing | `409 too_many_machines` | "This phone has 100 machines paired, the most it can have. Unpair one first." | |
| Pairing | `402 licence_required` | "The relay didn't accept this machine. Run `sealctl status` on it to see why." | |
| Pairing | Card not checked | Not reachable: pairing is hidden until the check passes | |
| Card | Request gone | "dev@mbp.example.com stopped waiting." | [Close] |
| Card | Unknown kind | "dev@mbp.example.com sent a request this app doesn't understand. Update the app." | Deny |
| Card | Root unreadable at answer | "Unlock your phone to answer." | |
| Card or level 2 and 3 screens | The reply did not go (8.5) | "Couldn't send your answer — try again." | The buttons stay |
| Level 2 or 3 | No biometrics, or locked out | The texts of 9.6 | [Use my card] for level 2 |
| Level 2 | Not near, no number | "dev@box.example.com isn't near this phone. Run the command at its terminal; this phone then asks for the number on its screen." | [Close] |
| Level 2 or 3 | Held | "Sensitive requests from dev@mbp.example.com are held until 11:42 after a wrong number." | [Release now] |
| Level 3 | Delay: relay unreachable at Finish | "The relay isn't answering, and sealctl can't finish until it confirms nothing was cancelled." | [Try again] |
| Activity | Empty | "Nothing yet. Every use of your keys shows here." | |
| Inventory | Empty | "No keys handed out yet." | |
| Answers | Empty | "No answers yet. When you tap Allow on an agent's first use of a key, it's remembered here." | |
| Places | Empty, permission given | "No places yet. After three mornings of approving at the same spot, sealctl asks whether to trust it." | |
| Settings | Relay backup full | "The relay backup is full. Old inventory entries were shortened." | |
| Settings | Background restricted (Android) | "Android is limiting sealctl in the background. Requests may arrive late." | [Open settings] |

### 11.21 Protecting the words on screen

Applies to onboarding step 5, Show words, and every typed-words screen.

- iOS: the words are drawn inside the layer of a `UITextField` with `isSecureTextEntry = true`, which the system leaves out of screenshots and recordings.
- iOS: when `sceneCaptureState` is `.active` (recording or mirroring), the words are replaced by "Hidden while the screen is recorded or mirrored."
- iOS: when the scene becomes inactive, a full cover with the mark hides the app switcher snapshot.
- iOS: after `userDidTakeScreenshotNotification`, show "The screenshot doesn't show your words."
- Android: `FLAG_SECURE` on the activity while any of these screens is shown; `setRecentsScreenshotEnabled(false)` on Android 13+.
- Android: the same while the approval card (11.7, whose sheet window also sets `SecureFlagPolicy.SecureOn`) or the level 2 and 3 screens (11.23: the number match and the plan) are shown, so the match number and the names and paths being approved stay out of screenshots and recents.
- No copy, share, look-up or text selection on the words. Accessibility can read them (12).
- The words view clears from memory when the screen closes; the `Words` object is released.

### 11.22 Leave sealctl

For someone who stops using sealctl. The phone walks through `sealctl unseal --all` on each computer, then deletes the relay data and the words backup. Entry: Settings, This phone, [Leave sealctl]. Leaving is level 3 (9.6, 11.23): biometrics at [Start] and again at step 3, the delay away from a trusted place before anything is deleted, the card check before the last copy of the words goes, and a report.

**1. What happens.**

> **Leave sealctl**
> sealctl hands everything back to you before you go. On each computer, `sealctl unseal --all` moves your volumes, backups, SSH keys and secrets to passwords of your own. Your files stay encrypted.
> Then this phone deletes your data on the relay and the copy of your words in iCloud Keychain.
> [Start]
> [Cancel]

Android says "in your Google backup".

**2. Each computer.** One row per paired machine, live from the relay's machine list:

> **Hand back each computer**
> On each computer, run:
> `sealctl unseal --all`
> It shows a plan and asks before it changes anything. When it asks this phone, tap Allow.
> `dev@mbp.example.com` · Waiting for `sealctl unseal --all`
> `ci-runner@build.example.com` · Handed back
> [Skip a computer]
> [Continue]

- `sealctl unseal --all` asks with an `unseal` request at level 3 (11.23): the number on its screen, its plan, biometrics, and away from a trusted place a two-hour delay. The row follows it: "Waiting for `sealctl unseal --all`", "Starts at 11:00", "Handing back", "Handed back · 9 objects" [Report].
- A machine shows "Handed back" once it has unpaired itself, which `unseal --all` does as its last relay step, so it disappears from `GET /v1/phones/{phone}/machines`. The phone does not unpair a machine in this flow.
- [Skip a computer] lists the machines still waiting: "Skip dev@mbp.example.com? Use it when the computer is lost or already wiped. Anything it holds then opens only with your card." [Skip] [Cancel]. A skipped machine is unpaired by the phone at step 3.
- [Continue] is enabled when every machine is handed back or skipped. With none paired, this step is skipped.

**3. Confirm.**

> **Delete your data and the last copy of your words?**
> Next, this phone deletes your data on the relay and removes your words from iCloud Keychain.
> At Desk: this happens as soon as you confirm. (Away from your trusted places: "This starts two hours after you confirm. Your phone and your computers can cancel it until then.")
> [Confirm with Face ID]
> [Cancel]

Away from a trusted place the app registers the delayed action `leave` and shows the countdown of 11.23. Every machine still paired (the skipped ones) and every install hears of it. Steps 4 to 6 run only after the relay answers `finish`, with biometrics again.

**4. Card check.** The card check of 11.23, three words, before the words backup goes.

**5. Relay data and words backup.**

The app unpairs the skipped machines, sends every machine a `notice`, calls `DELETE /v1/phones/{phone}` (as 11.19, without the lock messages: no machine is left Open), then removes `com.sealctl.words.sync` (iOS) or `com.sealctl.words.v1` (Block Store). On a network error it shows "The relay isn't answering. Try again." [Try again]; nothing further happens until it succeeds. Android says "from your Google backup" and "Your other Android phones lose this copy too."

**6. What happened.** The report of 11.23 for leaving: each computer, handed back (with its report) or skipped; relay data deleted; words backup removed.

**7. The card.**

> **Keep your card for now**
> Keep your paper card until no old copies of your backups or volumes remain: older disk images, old backup snapshots in another place, or copies of the store. Those still open only with these words. Then destroy it.
> [Done]

[Done] runs Erase (11.19) without its question: this install's push device, every keychain item or Keystore key and file, the database and the snapshot. The app returns to Welcome with one line above it: "sealctl is gone from this phone. You can delete the app."

- Each step is saved, so a closed app resumes at the step it left. [Done] leaves the step at 7 until Erase has removed the database, so an app closed during Erase opens at step 7 again.
- From step 5 on, the app does not register its push device again, and coming to the foreground opens no socket and lists no requests: that would put this phone back on the relay after its data was deleted, or show banners for a relay that no longer knows it. Erase closes the socket without ending the app's foreground, so onboarding again opens it.
- Without biometrics, step 3 is refused (9.6): leave from the card on each computer with `sealctl unseal --all --words`, then [Erase sealctl from this phone] (11.19). The relay data then expires after 730 days (6.5).
- Another install with the same words finds its phone key gone after step 5 and shows "Your words were removed on another phone." [Erase this phone] [Restore].
- Without a phone (lost), leaving works from the card alone: `sealctl unseal --all --words` on each computer. The website's "Leaving sealctl" page says so.

### 11.23 Sensitive and leaving confirmations

The screens for levels 2 and 3 (9.6). They are full-screen, never a sheet, and never reachable from a notification button. Each step is one screen; Deny or Cancel is on every one.

**Order.**

| Step | Level 2 request | Level 3 request (`unseal --all`) | Level 3 on the phone |
| --- | --- | --- | --- |
| Number match | Only when not near and the request has `match` | Always | |
| Plan or object list | Yes | Yes | What will happen |
| Biometrics | Yes | Yes | Yes |
| Delay | | Away from a trusted place | Away from a trusted place |
| Card check | | | Leave sealctl only |
| Report | | Yes | Yes |

**Number match.**

> **Which number does dev@mbp.example.com show?**
> Look at the terminal where you ran the command.
> [ 23 ]   [ 59 ]   [ 81 ]
> I don't see a number

- Three equal buttons in large monospace, in the order the core gives. The title uses the machine's name from this phone's records (nickname, or `user@host` and tag). Nothing else on this screen comes from the machine.
- "I don't see a number" denies the request.
- Wrong pick:

  > **That's not the number on dev@mbp.example.com**
  > The request was refused. For the next hour this phone ignores sensitive requests from that computer.
  > Didn't run anything there? Someone else may be using it. [What to do]
  > [Close]

  [What to do] opens "This machine was lost or stolen" (11.17).

**Plan.** Shown after a right pick (or at once when no number is needed):

> **Hand back everything on dev@mbp.example.com?**
> `sealctl unseal --all` moves these to passwords of your own. Your files stay encrypted. Then the computer is unpaired.
> 1  secrets · store (7 secrets)
> 2  volume · safe
> 3  ssh · ed25519
> 4  git · signing
> 5  AI tools · Claude Code
> 6  services · daemon
> 7  local files · ~/.config/sealctl
> 8  pairing · dev@mbp.example.com
> At Desk: this starts as soon as you confirm.
> [Confirm with Face ID]
> Deny

- Away from a trusted place the line reads: "Away from your trusted places: this starts two hours after you confirm. Your phone and your computers can cancel it until then." Without location access Always (place kind `none`) it says the same without "trusted places": "This starts two hours after you confirm…"
- Level 2 titles: "Hand back volume safe from dev@mbp.example.com?", "Let sealctl seal take over volume safe on dev@mbp.example.com?", "Move dev@mbp.example.com to seed 4kPz?" (rewrap: "12 objects. Each takes seconds."). Level 2 has no delay line.
- Item names come from the machine and are shown in monospace, one per line, never joined into a sentence.
- [Confirm with Face ID] reads "Confirm with Touch ID" or, on Android, "Confirm with fingerprint or face". It runs the prompt of 9.6.

**Delay.**

> **Leaving sealctl on dev@mbp.example.com**
> Starts at 11:00 · 59 min left
> You approved this away from your trusted places, so it waits two hours. Every paired computer has been told. If this wasn't you, cancel it.
> [Cancel]

- The same screen serves the actions on the phone: "Showing your words", "Deleting your relay data", "Leaving sealctl". Under the title, the time left in large type, "Started at 09:00 · goes ahead at 11:00", why it waits, what happens next, and what Cancel does, in whole sentences:

  > **Showing your words**
  > 59 min left
  > Started at 09:00 · goes ahead at 11:00
  > You started this away from your trusted places, so it waits two hours. Every paired computer has been told, and can cancel it.
  > At 11:00 sealctl will notify you. Open it then and confirm with your fingerprint or face to see your words. You'll have until 12:00.
  > Cancel stops it: nothing happens, and your computers are told.
  > [Cancel]

  Why it waits is the real reason, recorded when the action starts (`delay_reason`; kept with the record as `reason`, `reason_place`, `reason_until`), never a guess made later:

  | Reason | Text |
  | --- | --- |
  | `away`: location Always, not inside a trusted place | "You started this away from your trusted places, so it waits two hours." |
  | `unsettled`: inside a trusted place that does not lift the wait yet (announced under two hours ago, not confirmed, or a hand-added place on a stale clock) | "You're at Home, which was trusted less than two hours ago, so this still waits two hours. Home skips the wait from 12:04." (the last sentence only when the time is known) |
  | `no_always`: trusted places exist, location not "Allow all the time" (iOS: "Always") | "Location isn't set to "Allow all the time" for sealctl, so it can't tell when you're at a trusted place. This waits two hours." |
  | `places_off`: no trusted places | "You have no trusted places, so this waits two hours." |

  A record kept before reasons were recorded says "You approved this away from your trusted places, so it waits two hours." The next-step sentence names the action ("to see your words", "to delete your relay data", "to finish leaving") and, on iPhone, Face ID or Touch ID.
- The start screens (Show words, Delete my relay data, Leave sealctl step 3) say the same before the person confirms, from where the phone is now: at a trusted place that lifts the wait, "At Home: this happens as soon as you confirm."; otherwise the reason in the present tense ("You're away from your trusted places, so this waits two hours.", the others as above) and "If you confirm now, sealctl will notify you at 12:04. Open it then and confirm with your fingerprint or face to see your words. Every paired computer is told, and can cancel it until then."

- One action of each kind at a time on an install. While an action on the phone of a kind is waiting or ready (`releaseAt` passed, `expires` not yet), its start (Show words, Delete my relay data, Leave sealctl step 3) opens that delay screen instead of starting another, from Settings, a banner or a notification alike. Starts of one kind are taken one at a time (another kind does not wait for them; a start waits at most as long as its relay call, which the client times out), and a start first looks for a running action of its kind, so a double tap, or a second screen starting the same kind while the first start is still on its way to the relay, returns the first one and never registers a second two-hour delay. The start button is off while a start or a finish is on its way. Where an action stands is worked out from its state and the time (`delay_phase` in the shared crate, with `running_phone_action`), so the screens of both apps agree and a record whose window closed while the app was away reads as expired before the relay's list is fetched again.
- An action another install started is not one this install can finish (its kind is unknown here, 8.7). While one is waiting or ready, the start screen of every action on the phone says so before anything is started: "A protected action started on another of your devices goes ahead at 11:00. If that was you, finish it there; starting here waits two hours of its own." [Show it]. Starting here then is a choice, and makes a record of its own.
- The relay holds at most a few delayed records per phone, cancelled ones included, until each expires; `429 too_many_delayed` at a start says "The relay is holding as many protected actions as it can for these words. Try again when one of them has ended."
- A phone-only delay started on another install with the same words is shown as "Started on another of your devices", because the relay's record carries no kind (the phone's `notice` naming it goes to machines only). Under the countdown: "Showing your words, deleting your relay data or leaving sealctl was started on another phone or tablet with your words. It goes ahead at 11:00. Not you? Cancel it." Its banner: "A protected action started on another of your devices goes ahead at 11:00." Its `delayed` push: "A protected action started on another of your devices" / "It goes ahead at 11:00. Open sealctl to see it or cancel it." (the Android app builds it; on iPhone the extension rewrites it, 10.1). Once the wait is over: "The wait is over. The phone or tablet that started it can go ahead."; once the relay no longer has it: "This is no longer waiting: the phone or tablet that started it finished it, or it expired." A record from another install that names a machine is that machine's `unseal --all` and keeps its "Leaving sealctl on …" title. The install that starts an action never names it so: the relay lists the record and sends its `delayed` push before its answer to `POST delayed` reaches the app, so the app keeps the id aside until it has stored the record. A refresh of the relay's list leaves that id alone, and on iPhone the snapshot counts it among the delayed actions of known kind before the call goes out.
- A banner on the Machines tab while any delay runs: "dev@mbp.example.com hands everything back at 11:00." [Show] [Cancel] ("Your words can be shown at 11:00.", "Your relay data is deleted at 11:00.", "This phone leaves sealctl at 11:00."). Cancel needs no biometrics: stopping is always allowed. Once an action on the phone is ready, until it expires: "Showing your words: ready until 12:00." [Show my words] [Cancel] ([Finish] for deleting the relay data and leaving).
- Cancelled here: "Cancelled. Nothing was handed back." (an action on the phone: "Cancelled. Nothing happened."). Cancelled from a computer: "Cancelled from dev@box.example.com." The app then sends every machine a `notice` with `state: "cancelled"`.
- A cancel here is recorded on the phone before the relay is asked, so its plan hands out no more keys whatever the relay answers: `404 gone` (the machine already fetched the approval, or the record expired) or no answer at all. The `notice` goes to every machine either way. A cancel the relay did not get is sent again whenever the phone reads the relay's list and finds that record still `waiting` or `released`. A cancel sent again keeps what the relay answered: once the relay takes it, or gives an answer that will not change (`404 gone`, `403`, any other `4xx`), it is not sent again; a `429` waits out its window, and no answer or a `5xx` waits 15 seconds, twice as long after each further failure, up to 15 minutes.
- For an action on the phone, at `releaseAt` a local notification says "Ready: open sealctl to finish …" (10.1; on Android an alarm, 10.2). A cancel removes it, however the phone hears of it (socket, push, the relay's list, `finish`); on Android the alarm that posts it asks the relay first. The screen does not wait for the note: open at `releaseAt` (or opened later from Settings, the banner, the note, or a cold start), the delay screen reads:

  > **Showing your words**
  > Ready until 12:00
  > The wait is over. Finish before then, or this has to start again.
  > [Show my words]
  > Cancel

  [Show my words] ([Finish] for the others) asks for biometrics, then calls `finish`; only on `200` does the action run (the words then show in the protected view, 11.21). `409 cancelled`: "Cancelled from dev@box.example.com." (or "Cancelled. Nothing happened."). `425 too_early` (the phone's clock ahead of the relay's): "Not yet." The finish is offered until the relay record expires, an hour after `releaseAt` (the app takes `expires` from the relay); after that, or when the relay answers `404 gone` or no longer lists it: "This waited too long. Start again." [Start again] [Close]; [Start again] is a new start (biometrics, and away from a trusted place a new delay).
- For `unseal --all`, nothing is needed from the phone when the hour ends: the computer fetches the approval from the relay.
- Other installs with the same words show the delay too (from the relay's note) and can cancel it.
- Notes, pushes and the relay's list can arrive in any order. Once the phone has recorded a delayed action as cancelled, finished, gone or expired, a later write from an older read (the list fetched just before a cancel note) never makes it wait again; only a known end (cancelled, with who cancelled, or finished) replaces "gone" or "expired". A cancelled plan approval stays cancelled, and a plan approval whose delayed action is cancelled is cancelled too, whichever of the two the phone recorded first (a cancel can arrive while the approval is still being posted); approving the same plan again is a new request with its own record.

**Card check** (Leave sealctl, before the words backup is removed):

> **Check your card first**
> After this, your paper card is the only copy of your words. Type three words from it.
> Word 4: [____]
> Word 13: [____]
> Word 22: [____]
> [Check]

- Positions at random, one from each third of the card. The keypad and completion of 11.4. The words are checked inside the core; nothing typed is kept.
- Wrong: "That's not word 13 on these words. Find your card before the last other copy goes." [Try again]. No limit on tries; nothing is removed until all three are right.
- [I can't find my card] stops leaving at this step: "Keep the copy in iCloud Keychain until you find it, or write a new card first (Show words)."

**Report.** After a level 3 action:

> **dev@mbp.example.com handed everything back**
> 8 of 8 done · 10:14
> secrets · store → macOS Keychain, service sealctl-unsealed
> volume · safe → macOS Keychain
> ssh · ed25519 → ~/.ssh/ed25519
> …
> Run folder on that computer: `~/.sealctl-unseal/2026-11-21T10-12-03`
> Your other computers were told.
> [Done]

- Failed items in amber with "Run `sealctl unseal --resume` on that computer." Skipped items muted.
- The report stays in Activity under that day, also after the machine is unpaired.
- For actions on the phone the report is one line on the same screen, and the `notice` to every machine says the same: "Your phone showed its 24 words at 11:02.", "Your phone deleted its relay data. This computer is unpaired.", and for leaving, the summary of 11.22 step 6.

## 12. Accessibility

- Every screen works with VoiceOver and TalkBack. The approval card reads in this order: state, title, facts, buttons. The machine state reads as words: "Open, 2 hours 10 minutes left."
- Notification actions are reachable by VoiceOver and TalkBack.
- Dynamic Type up to the largest accessibility size; Android font scale up to 200%. The approval card scrolls while its buttons stay pinned at the bottom.
- Touch targets at least 44 points (iOS) and 48 dp (Android), text links and inline buttons (Remove, Cancel, Show) included: they keep their look and grow their hit area. The word keypad keys are at least that size.
- Contrast: the brand tokens pass WCAG AA for text and buttons in both themes; status colours are paired with words.
- Reduce Motion stops the Waiting pulse. No other animation carries meaning.
- The words screen reads "Word 7: ocean". A rotor action (iOS) or custom action (Android) spells the word letter by letter.
- The QR scanner has a text alternative: "Can't scan? Type the pairing code" opens a field for the code text that `sealctl pair` also prints (19.1).
- Haptics confirm Allow and Deny; nothing depends on them.
- Snapshot tests cover the largest text size in both themes (16.2).

## 13. Localisation

- English first. All user-facing text lives in `Localizable.xcstrings` and `InfoPlist.xcstrings` (iOS) and `strings.xml` (Android), with plural rules. No string concatenation for sentences; placeholders only.
- The push uses `title-loc-key` `REQUEST_TITLE` and `loc-key` `REQUEST_BODY`, so iOS shows them in the phone's language even when the extension cannot run.
- Dates in the UI use the locale's medium style; dates the user copies onto the card are always ISO (`2026-11-21`). Durations use the platform formatters ("2 h 10 min").
- Machine names, key names, commands, paths and the words are never translated. They are wrapped in Unicode isolation marks and shown left-to-right.
- The 24 words are always the BIP39 English list, whatever the app language.
- Layouts use leading and trailing, not left and right. CI runs the Android pseudo-locales `en-XA` and `ar-XB` and the iOS double-length and right-to-left pseudolanguages on the main flows.
- Translations are added later, one language at a time, after the English text is frozen at milestone M7.

## 14. Privacy: data, manifest, store forms, permissions

### 14.1 What leaves the phone

| Data | Sent to | Readable by the relay operator | Why |
| --- | --- | --- | --- |
| Phone public key | Relay | Yes | Identifies the phone; signs every call |
| Machine name, OS, model | Relay, at pairing | Yes | Pairing records the relay keeps. The hardware hint is not sent; it lives only in the encrypted state |
| Lock and answers messages to machines | Relay, then the machine | No (sealed to the machine) | Locking, answers. Held up to 24 hours for an offline machine |
| Push device id, platform, token, sandbox flag | Relay | Yes | Waking each install |
| Replies to requests | Relay, then the machine | No (sealed) | Carrying keys |
| State blob (machines, places, answers, inventory, summaries) | Relay | No (sealed with `derive(root, "state")`) | Restoring a phone |
| IP address | Relay, with every call | Seen while serving the call; used to compute `near`; not stored by the app's request | Transport |
| Days with a delivered reply | Counted by the relay from replies | Yes | Counted by the relay, not sent by the app |
| Firebase installation id | Google (Android; iOS only with `PUSH_TRANSPORT = fcm`) | No | FCM |

Nothing else leaves the phone. No analytics, no crash SDK, no advertising id.

### 14.2 `PrivacyInfo.xcprivacy`

The app and the extension each carry one.

- `NSPrivacyTracking`: `false`. `NSPrivacyTrackingDomains`: empty.
- `NSPrivacyCollectedDataTypes`:

| Type | Linked | Tracking | Purpose |
| --- | --- | --- | --- |
| `NSPrivacyCollectedDataTypeUserID` (phone public key) | true | false | `NSPrivacyCollectedDataTypePurposeAppFunctionality` |
| `NSPrivacyCollectedDataTypeDeviceID` (push device id and APNs or FCM token; with FCM also the Firebase installation id) | true | false | App functionality |
| `NSPrivacyCollectedDataTypeProductInteraction` (days with use, counted by the relay) | true | false | App functionality |
| `NSPrivacyCollectedDataTypeOtherDataTypes` (machine name, OS, model) | true | false | App functionality |

- `NSPrivacyAccessedAPITypes`:

| API category | Reason |
| --- | --- |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` (app's own defaults), `1C8F.1` (app group, app and extension) |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` (files in the app's container) |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` (elapsed time for timeouts; also used by the Rust runtime) |

Location is not declared as collected: it never leaves the phone except inside the end-to-end encrypted state blob, which the developer cannot read. This follows Apple's definition of collection (transmitted off the device in a form the developer can access). See open question 20.3.

### 14.3 App Store privacy answers

The answers match the manifest:

- Data used to track you: none.
- Data linked to you: Identifiers (User ID, Device ID), Usage Data (Product Interaction), Other Data. All for App Functionality.
- Data not linked to you: none.

### 14.4 Play Data safety

| Question | Answer |
| --- | --- |
| Does the app collect or share user data? | Yes, collects. Shares: no (Cloudflare and Google act as service providers) |
| Encrypted in transit | Yes |
| Users can request deletion | Yes, in the app: Settings, Delete my relay data |
| Personal info, User IDs | Collected (phone public key); required; App functionality |
| Personal info, Other info | Collected (machine name with user and host name, OS, model); required; App functionality |
| App activity, Other actions | Collected (days with use, counted by the relay); required; App functionality |
| Device or other IDs | Collected (push device id, FCM token, Firebase installation id); required; App functionality |
| Location | Not collected (stays on the phone; leaves only end-to-end encrypted) |
| Financial info, contacts, messages, photos, audio, files, calendar, health, web history | Not collected |
| Independent security review | No |

### 14.5 Permissions and usage strings

| Permission | iOS key and text | Android |
| --- | --- | --- |
| Camera | `NSCameraUsageDescription`: "The camera scans the pairing code that sealctl pair shows on your computer." | `CAMERA`, asked at the first scan |
| Location when in use | `NSLocationWhenInUseUsageDescription`: "sealctl learns the places where you approve, so it can answer by itself at your desk. Locations stay on this phone." | `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` |
| Location always | `NSLocationAlwaysAndWhenInUseUsageDescription`: "sealctl notices when you leave a trusted place and locks the machines you opened there. Locations stay on this phone." | `ACCESS_BACKGROUND_LOCATION` (Play declaration, 15.3) |
| Face ID | `NSFaceIDUsageDescription`: "Face ID protects showing and changing your 24 words." | `USE_BIOMETRIC` |
| Notifications | System prompt | `POST_NOTIFICATIONS` |
| Network | | `INTERNET`, `ACCESS_NETWORK_STATE` |
| Boot | | `RECEIVE_BOOT_COMPLETED` (geofences, "Ready" alarms) |
| Alarms | | `SCHEDULE_EXACT_ALARM` (the "Ready" alarm on time, 10.2; granted in Alarms & reminders, not asked for) |

### 14.6 Cryptography and libraries

The app writes no cryptography of its own. For the store forms, export questions and the website's security page:

| Where | What | From |
| --- | --- | --- |
| Words, root, derivation | BIP39 (English list), HKDF-SHA256 | `sealctl-core` |
| Phone keys, relay signing, reply signatures | Ed25519 | `sealctl-core` |
| Requests and replies | HPKE (RFC 9180) with X25519 | `sealctl-core` |
| State blob | AEAD under `derive(root, "state")` | `sealctl-core` |
| Licence move and key-change proofs | Ed25519 | `sealctl-core` |
| Root, words and phone keys at rest, iPhone | Keychain data protection (Secure Enclave) | iOS |
| Root, words and phone keys at rest, Android | AES-256-GCM with Android Keystore keys (StrongBox when present), `javax.crypto` | Android |
| Transport | TLS | iOS `URLSession`, OkHttp with the Android trust store |
| Root backups | iCloud Keychain end-to-end encryption; Block Store end-to-end encryption | Apple, Google |

The exact Rust crates and versions are those in `sealctl-core`'s `Cargo.lock` at the pinned tag; the About screen's licence list names them. The app's own `sealctl-app` crate uses no crypto crate directly.

## 15. Store listings and review notes

### 15.1 Shared facts

- Name: **sealctl**.
- Seller: on the App Store, the developer enrolled as an individual, so the seller name is the developer's legal name. On Google Play, a personal developer account in the same name.
- Privacy policy: `https://sealctl.com/privacy` (both stores, and linked in the app). Support: `https://sealctl.com/support`. Website: `https://sealctl.com`.
- Price: free, no in-app purchases, no ads.
- The listings never mention price, payment, purchases or the licence.

### 15.2 App Store

| Field | Content |
| --- | --- |
| Subtitle (30) | "Approve keys for your agents" |
| Category | Developer Tools; secondary Utilities |
| Age rating | 4+ |
| Keywords (100) | `secrets,api keys,approval,agent,developer,terminal,ssh,cli,encryption,recovery,keys,vault` |
| Promotional text | "Your AI coding agents use your keys without seeing them. Every use shows on your phone, and one tap opens your machine for the day." |
| Copyright | "© 2026" and the developer's legal name |

Description:

> sealctl keeps your API keys, SSH keys and backup passwords off your computer's disk. When an agent or a command needs a key, your computer asks this phone. You tap Allow, and the key goes into that one command. The agent never sees it.
>
> • One tap in the morning opens your machine. At a place sealctl has learned, like your desk, reopening answers by itself while your phone is unlocked.
> • Leave the place and your machines lock.
> • An agent's first use of a key in a repository asks once; your answer is remembered.
> • Every use shows on your phone, and the inventory lists every key your phone handed out.
> • Everything comes from 24 words you write by hand on a paper card. A new phone gets everything back from them.
>
> sealctl needs the sealctl command line tool on your computer (macOS or Linux). No account. Locations stay on this phone. The app, the command line tool and the protocol are open source.

Screenshots (6.9-inch and 6.5-inch): the approval card; the Machines tab with Open, Locked and Waiting; Trust this place; the Inventory; the card check; Activity with the monthly summary. Made from UI tests against the fake relay (16.3), never with real data.

App Review information:

- Sign-in required: no.
- Notes:

> sealctl approves key requests from the sealctl command line tool on a computer. To try it without a computer, use our review machine:
> 1. Open the app, tap Create new words, print or skip the blank card (any paper works), write the words and pass the check.
> 2. On another device, open the review page given in the "Attachment / URL" field. It shows a pairing code from a test machine.
> 3. In the app, tap Pair a machine and scan the code.
> 4. The review machine sends a request every minute. Answer it from the notification or in the app. Locking, unpairing and Delete my relay data also work against it.
>
> There are no purchases of any kind in the app. Every feature is available to everyone, and nothing in the app changes based on payment. The app does not link to or mention any payment.
>
> Location is optional. With permission, the app learns places where the user approves and uses region monitoring to lock the user's computers when they leave. Locations never leave the phone in readable form.
>
> Time Sensitive notifications are used only for approval requests, which expire after 5 minutes.

- Export compliance: see open question 20.2. `ITSAppUsesNonExemptEncryption` is set once that is settled.

### 15.3 Google Play

| Field | Content |
| --- | --- |
| Title (30) | "sealctl" |
| Short description (80) | "Approve key use for AI coding agents. Your phone holds the keys." |
| Category | Tools |
| Content rating | IARC questionnaire: no objectionable content |
| Target audience | 18 and over (keeps the app outside the Families policy) |
| Ads | No |
| App access | Instructions as in the App Store notes, with the review page URL |
| Full description | Same as the App Store description |

Declarations:

- **Background location:** feature "Locks your computers when you leave a trusted place". Includes a 30-second video: trust a place, walk out, the machine shows Locked. The prominent disclosure is the "Allow location all the time" screen (11.3 step 9).
- **Data safety:** as in 14.4.
- **Financial features:** none. **Health:** none. **Government:** no.

New personal developer accounts must run a closed test with at least 12 testers for 14 days before production access. Milestone M8 includes it.

## 16. Testing

### 16.1 Rust

- `sealctl-app`: unit tests for `decide` covering every row of 9.3 and 9.6 (a machine's `lvl` raises and never lowers; unknown kinds are level 3; proximity by `near` on Wi-Fi only, by number, by camera; holds; delay by place kind), day boundaries (02:00 local, 24 h, time zones, daylight saving), place clustering, pruning, merge with tombstones, summaries; the daily counts (a resent log counted once, an entry reported after 90 days counted nowhere, the one backfill, usage entries kept 90 days and counts 400, a use near local midnight on the right day).
- The corrected clock (8.1), with a fake system clock and since-boot clock: a clock set forward ends no hold, no hand-added place's two hours and no level 3 wait early; a clock set back shortens none of them; after a reboot, after 24 hours, or after a signed call that disagrees, the clock is stale and a hand-added place does not lift the delay; a place added by hand on a stale clock set back starts its 24 hours only once the relay's time is learned.
- Property tests for `merge_state`: the result does not depend on the merge order; deleted records stay deleted.
- The protocol's test vectors, run through the generated Swift and Kotlin bindings on simulator and emulator, so the bindings and both platforms give the same bytes.

### 16.2 Platform unit and snapshot tests

- iOS: Swift Testing for `Engine`, `Vault` (against a test keychain access group), `Relay` (against the fake relay), notification content building. Snapshot tests (swift-snapshot-testing) for every screen in light, dark and the largest text size.
- Android: JUnit and Robolectric for ViewModels, `vault` (Robolectric Keystore shadow for logic; real Keystore in instrumented tests), `relay`, notification building. Paparazzi snapshots for every screen in the same three variants.

### 16.3 Fake relay and fake machine

- `tools/fake-relay`: Rust (axum). It implements the Relay API from the protocol: signing checks, machines, the wait and phone sockets, requests and replies, state with compare-and-swap, the error codes, plus the push and machine-channel additions once specified. It keeps everything in memory.
- It adds test-only routes under `/test/` (unsigned, bound to localhost): set `near`, force an error code on the next call, advance the clock, read what the phone replied.
- `tools/fake-machine`: Rust, using `sealctl-core`. It prints a pairing QR code, waits for pairing, sends any request kind with given context, checks replies decrypt to the expected derived keys, and reports status and uses.
- `fake-machine --review` is the review machine (15.2): against the production relay, it serves a fresh pairing code as an image on one page, and once paired sends an `open` request every minute, using made-up key names (`DEMO_API_KEY`) and no real secrets. Operations runs it during reviews.
- Push in tests: iOS simulator gets the alert payload with `xcrun simctl push`, which runs the NSE. Android tests call the messaging service's handler directly through a debug-only entry point: a receiver guarded by `android.permission.DUMP`, which the adb shell holds and installed apps do not.
- The same fake relay serves screenshots for the store listings.

### 16.4 UI tests

XCUITest and Compose UI tests, each against a fresh fake relay:

1. Create words, check the card (right and wrong answers), backups, notifications.
2. Restore from typed words; wrong checksum; fingerprint confirmation.
3. Pair; duplicate name with the same and a different hint; Pair as new; tags shown.
4. Each request kind: allow, allow once, deny, remember; expired while open; several waiting.
5. Notification actions on a locked simulator or emulator, where the platform allows.
6. Answers removal; Places screen without permission.
7. Change words end to end with two fake machines, one never reporting; Finish anyway.
8. Yearly check right and wrong.
9. Delete relay data; erase this phone; Leave sealctl with two fake machines, one handed back by unpairing itself and one skipped, resumed after the app is killed at each step.
10. Offline, clock skew, rate limit banners.
11. Levels 2 and 3 against the fake machine and fake relay: `unseal` of one object near and not near (number asked, right and wrong, hold and release); `unseal --all` at a trusted place and away (delay, countdown, cancel here, cancel from a second fake machine, release fetched by the machine); a plan in parts; keys outside the plan refused; Show words and Delete my relay data with the delay and `finish`; the card check right and wrong; the report screen. Biometrics simulated: matched, failed, not enrolled (level 2 asks the card, level 3 refuses), locked out, enrolment changed (card first, then a new gate), and the first gate (the first pairing and the first Show words ask the card, then Face ID).
12. Activity: today open, an earlier day closed until tapped and closed again, days before the ten not listed; the heatmap's title and a tapped day's figures.

### 16.5 Real-device matrix

| Device | OS | Why |
| --- | --- | --- |
| iPhone SE (3rd generation) | iOS 17 | Minimum OS, Touch ID, small screen |
| iPhone 13 | iOS 18 | Face ID, mid-range |
| iPhone 16 or later | Current iOS | Current OS, Apple Watch paired |
| Pixel 4a or similar | Android 13 | No StrongBox on some units, mid-range |
| Pixel 8 or later | Current Android | StrongBox, current OS |
| Samsung Galaxy A-series | Android 14 or later | One UI battery management |
| Xiaomi or Redmi | HyperOS | Aggressive background limits |
| Any Android 9 or 10 device | Android 9 or 10 | Minimum OS, no notification unlock |

Manual checks on each device before each release:

- What the keychain and Keystore return after a Face ID unlock, a passcode unlock and while locked (the design's research step).
- Notification actions from the lock screen; the Apple Watch case.
- Leaving a place on foot and by car, and how long the lock takes.
- Restore from iCloud Keychain and Block Store on a reset device.
- Push delivery after 12 hours idle and in Low Power or battery saver.
- Levels 2 and 3 with real biometrics: the prompt offers no passcode; after five failed matches level 3 is refused and works again after a passcode unlock; adding a fingerprint or a second Face ID appearance invalidates the gate and the card is asked once; Android devices with only class 2 face unlock fall back to the card for level 2.

## 17. CI and release

### 17.1 Workflows (GitHub Actions)

| Workflow | Runs on | Does |
| --- | --- | --- |
| `core.yml` | Every push; Ubuntu and macOS | `cargo fmt --check`, `clippy`, `cargo test`, `cargo deny`, builds both bindings, `check-core.sh` |
| `ios.yml` | Every push; macOS runner, pinned Xcode | Builds the XCFramework, generates the project, unit and snapshot tests on the iPhone 16 (current iOS) and iPhone SE (iOS 17) simulators, UI tests with the fake relay |
| `android.yml` | Every push; Ubuntu with KVM | Builds the `.so` files, `./gradlew lint test`, Paparazzi, instrumented and UI tests on API 28 and API 36 emulators with the fake relay |
| `devices.yml` | Main branch, nightly | Firebase Test Lab real devices: XCTest on physical iPhones and instrumented tests on the Android devices available there |
| `bench.yml` | Nightly and every release tag; self-hosted Mac with one iPhone and one Android phone attached | End to end with real APNs and FCM against the staging relay and the real `sealctl` CLI at the pinned tag |
| `release.yml` | Tags `v*` | fastlane lanes below |

Builds are reproducible from the tag: pinned Xcode, pinned Rust toolchain, Gradle version catalog, committed lock files.

CI today (the table above is the target): `checks.yml`, `ios.yml` and `supply-chain.yml`. Shape:
- One run per pull request; a new push cancels the old run. Runs on `main`, schedules and manual runs each get a concurrency group of their own, so they are never cancelled or replaced. Every job has `timeout-minutes`.
- `supply-chain.yml` (jobs `gradle-wrapper`, `gradle-verification`, `cargo`, required on `main` once merged) has no workflow path filter, so its checks always report; a `changes` job reads the pull request's file list and skips the Gradle or Cargo jobs when their files are untouched (a skipped job counts as passed).
- `checks.yml` (Linux only, no path filter, so its checks always report): jobs `rust-fmt` (`cargo fmt --check`), `rust-clippy` (`clippy --all-targets -D warnings`), `rust-test` (`cargo test` for the workspace), `android-test` (`testDebugUnitTest`, against the host build of `libsealctl_app` through JNA) and `android-lint` (`lintDebug`).
- `ios.yml` (macOS, about 75 minutes, not required: the free plan runs 5 macOS jobs at a time) keeps its path filter. On Dependabot's pull requests that only change `Cargo.toml`/`Cargo.lock` it builds the core and runs the package and unit tests but skips the UI tests. Other pull requests run the UI tests when `ios/`, `shared/`, `tools/`, `scripts/`, the workflow or the Cargo files change (a `sealctl-core` pin bump changes only the Cargo files but swaps the whole core). They always run on `main` and manual runs.

### 17.2 Release

- fastlane in `ios/fastlane` and `android/fastlane`.
- `ios beta`: build with the App Store Connect API key and cloud-managed signing, upload to TestFlight, internal group first.
- `ios release`: submit the TestFlight build with the metadata in `store/ios`.
- `android internal`: build an AAB, sign with the upload key, upload to the internal testing track (Play App Signing holds the app key).
- `android promote`: move a build to closed testing and then to production with staged rollout (10%, 50%, 100%).
- Secrets are GitHub Actions secrets, never in the repository: the App Store Connect API key, the Play service account, the Android upload keystore and its password, and the Firebase app configuration (`google-services.json`, written at build time). Debug builds use a separate Firebase project and the APNs development environment.
- Release order: TestFlight internal and Play internal on every tag. External TestFlight and Play closed testing for minor versions. Production after 3 days without new crashes in either console.

## 18. Milestones

Each milestone ends with its acceptance criteria passing in CI and on the real-device bench.

| # | Milestone | Acceptance criteria |
| --- | --- | --- |
| M0 | Skeleton and bindings | Both apps build from a clean checkout in CI. `core_version()` shows in About. The protocol test vectors pass through Swift and Kotlin bindings on simulator, emulator and one real device each |
| M1 | Words and key storage | Onboarding steps 1 to 7 work with the exact wording. On a real device: the root item cannot be read while locked, the words item asks for Face ID or the credential each time, the phone keys can be read while locked after the first unlock. Restore from words gives the same fingerprint and phone key as the vectors. Restore from iCloud Keychain and Block Store works on a reset device. Screenshots and recordings never show the words |
| M2 | Relay client and pairing | Pairing by QR against the fake relay and the staging relay; duplicate card both cases; tags; nicknames; unpair; state upload and download with a forced conflict; clock skew and rate-limit handling |
| M3 | Approvals in the foreground | Every request kind through the WebSocket; the card; the level 2 and 3 screens of 11.23 with the core's number match and plan signature checked on the fake machine; replies decrypt on the fake machine to the right derived keys; answers remembered and removed; usage log; inventory from requests; monthly summary |
| M4 | Push and background | Push devices registered, listed and removed; the test push works. Alert push with NSE and FCM data messages show the full card text within 3 seconds on the bench, with both `PUSH_TRANSPORT` values on iOS. Actions answer from the lock screen after the unlock on iOS and Android 12+. Automatic answers send no visible alert. Expired notifications disappear. A request answered from a locked phone in under 5 seconds end to end |
| M5 | Places | Learning after 3 days (with a clock-advancing test), Trust this place, region exit locks the machines opened there within 3 minutes on foot on the bench phones, `near` respected, the place kind reaches the machine, no-permission path caps at 1 hour |
| M6 | Changing words | The full change with two machines, in the relay's step order, resumed correctly after the app is killed at each step; licence move called with a valid proof; old phone key's relay data deleted; not-seen list; retired card recorded; old words request moves one object; yearly check right and wrong |
| M7 | Settings, privacy, accessibility | Delete relay data and erase this phone; Leave sealctl end to end on the bench with the real CLI running `sealctl unseal --all`, once at a trusted place and once away with a shortened test delay and a cancel from a second computer; monthly summary; VoiceOver and TalkBack pass on every screen; the largest text size works; privacy manifest validated by Xcode's privacy report; Data safety form filled; the English text frozen |
| M8 | Store readiness | Listings, screenshots and review notes in `store/`; the review machine works; Play closed test with 12 testers for 14 days; TestFlight external beta; both stores approve version 1.0.0 |

## 19. Needs from the protocol, core and relay

### 19.1 From `sealctl-core` and the protocol sections

A crate `sealctl-core` in the `sealctl` repository with a `uniffi` feature using proc macros only (library mode). The app uses these exports, as the `sealctl` spec (section 2.2) defines them. Errors are the core's one enum `CoreError`:

| Function or type | Returns | Notes |
| --- | --- | --- |
| `Words::generate()` | `Words` | 24 words from the OS random source |
| `Words::from_entropy(bytes)` / `Words::parse(list)` | `Words`, or `CoreError::UnknownWord(index)`, `Checksum`, `Count` | |
| `Words.entropy()`, `Words.list()` | bytes, 24 strings | `list()` only for the protected view |
| `complete_word(prefix)` | matching BIP39 words | Drives the keypad: valid next letters and completion after four |
| `Root::from_words(words)`, `Root::from_bytes`, `Root.to_bytes()` | `Root` | Zeroed on drop |
| `fingerprint(root)` | 4 characters | As printed in `.id` files and `sealctl status` |
| `PhoneKeys::from_root(root)`, `PhoneKeys::from_bytes`, `.to_bytes()`, `.public_id()` | keys; 43-character id | The identity seed and the `phone:box` X25519 key together (64 bytes), storable without the root. Requests and machine status are encrypted to the box key |
| `relay_headers(keys, method, path_and_query, unix_time, body)` | the three header values | Implements the Relay API's Signing |
| `PairingOffer::parse(text)` | machine key, machine box key, code, name, OS, model, hint, relay origin, protocol version, expiry | Accepts the link and the part after `#` |
| `pairing_proof(keys, offer)` | proof string (up to 128 base64url characters) | |
| `machine_tag(machine_key)` | 4 characters | The duplicate-name tag |
| `open_request(keys, relay_machine_key, id, sealed)` | `Request` | Verifies the machine's signature, time, version and the replay window; derives the number match from the HPKE context when the body has `match` |
| `Request` | `kind` (`open`, `keys`, `agent`, `own`, `rewrap`, `old_words`, `unseal`, `report`), `ctx` (agent, repository id and name, command, cwd, user, subject, names), `items` (purpose, id, path or URL, size, words fingerprint, key check), `uses`, `old` (retired fingerprint, for `old_words`), `status` and `handback` (for `report`), `plan` (items, `all`, hash, part), `level()`, `has_match`, `rq`, `version` | Fields the card, the level 2 and 3 screens and inventory need |
| `Request.match_choices()`, `Request.check_match(pick)` | three numbers; bool | The right number stays inside Rust |
| `PlanAssembler::new()`, `.add(request)` | the whole plan or nothing yet | Collects a plan sent in parts and checks its hash |
| `seal_reply(root_or_none, keys, request, decision)` | sealed string | `decision`: `Deny`, `Refuse { err }` (`no_match`, `not_near`, `no_biometrics`, `held`, `outside_plan`, `plan_expired`), `Once { place }`, `Session { place }`, `Remember { place }`, `Plan { place, not_before }`; `place` is `Trusted`, `Other` or `NoLocation`. Needs the root only when the request asks for keys |
| `seal_plan_keys_reply(root, keys, request, approval)` | sealed string | Later keys of an approved plan, inside its 30 minutes |
| `seal_rewrap_reply(old_root, new_root, keys, request)` | sealed string | |
| `seal_old_words_reply(old_root, root, keys, request)` | sealed string | Derives only that object's keys |
| `seal_report_reply(keys, request, ack, messages)` | sealed string | Answers a `report`: the status `seq` stored and the machine messages waiting |
| `key_change_proof(old_keys, new_keys, machine_key)` | 128-character move proof | Signed by the old identity over the new identity and box keys and the machine key, so machines accept the new phone key |
| `licence_move_proof(new_keys, old_public_id)` | base64url signature | Ed25519 by the new key over `sealctl-licence-move-v1\n<old>\n<new>`, as the relay defines |
| `state_seal(root, plaintext)` / `state_open(root, blob)` | blob / bytes | Uses `derive(root, "state")` and an AEAD, specified in the protocol |
| `seal_machine_message(keys, machine_key, machine_box_key, message)` / `open_machine_status(keys, machine_key, sealed)` | sealed / `MachineStatus` | Messages `lock`, `answers`, `ack`, sealed to the machine box key from the pairing offer; status with state, allowance left, hard stop, uses, inventory, migration progress and estimates |
| `backup_item_encode(words, fingerprint, date)` / `decode` | bytes | The iCloud Keychain and Block Store item format, shared by both apps |
| `core_version()`, `protocol_version()` | strings | |

Protocol content the app depends on:

1. **Pairing QR code:** a `https://sealctl.com/p#<payload>` link (the fragment is never sent to the website), so the system camera opens the app through universal links and App Links. It should carry the relay URL, the protocol version and an expiry. `sealctl pair` should also print the payload as text for typing.
2. **Request kinds** `open`, `keys`, `agent`, `own`, `rewrap`, `old_words`, `unseal`, `report`, with the fields above, and the confirmation levels, number match, plan signature and delayed approvals of the protocol (done in the protocol; 9.6 follows it). A `repository` id that is stable (for example the normalised git remote, or the path when there is none) for answers.
3. **Reply** carrying `place` (`trusted`, `other`, `none`) and `cap`, `base`, `rate`, so the machine sets its allowance, and `grant` (`once` or `session`).
4. **Key change proof** and how a machine moves to the new phone key.
5. **Machine status and lock messages**: sealed formats, and how uses inside an Open session reach the phone.
6. The test vectors as a JSON file the app's tests can load.
7. CLI: a `SEALCTL_RELAY` environment variable or `--relay` flag so the bench can point the real CLI at the fake or staging relay.
8. **In review (sealctl/sealctl#76):** a `notice` kind for trusting a place (11.9): `{"what": "place", "state": "pending" | "cancelled" | "done", "machine": null, "place": <the place's name>, "delay": <its delayed id>, "at": <releaseAt>}` (`place` is `Notice.place` in `sealctl-core`, left out of other kinds), which the CLI shows as "Your phone trusted the place Home. It skips the two-hour wait from 12:04. Not you? Run: sealctl cancel" (pending; `sealctl cancel` cancels that delayed id), "Cancelled from your phone: trusting the place Home" (cancelled) and nothing for `done`; the CLI cleans the name (control and direction-changing characters, 60 characters at most). The app sends it from `announceTrust` (pending), a cancel of the place's record (cancelled) and its confirmation (done) only once a released core and CLI know it: the core pin moves to that release in the same pull request. An older CLI would show the kind as an approval away from a trusted place. Until then, the relay's own `delayed` note announces it.

### 19.2 From the relay

Already specified by the relay (planned in the Relay API) and used as written in this spec: push devices (`PUT`, `DELETE`, `GET /v1/phones/{phone}/push...`, the test push with `"type": "test"`), the APNs and FCM payloads, `near` on requests, the phone socket's `ping`/`pong`, `DELETE /v1/phones/{phone}` (which keeps only a licence record), the licence move with `proof` and no `409 not_paid`, the words-change order, the error bodies (`clock_skew` with `time`, `rate_limited` with `retryAfter` and `scope`), that the relay no longer stores the hardware hint, the machine channel (status, messages, machine socket), `lastSeen` per machine, the `moved` close error, and the hostnames `relay.sealctl.com` and `relay-staging.sealctl.com`.

Still needed:

| Need | Proposed shape |
| --- | --- |
| APNs transport | Confirm direct APNs from the Worker, or FCM for iOS too (10.1). The app needs to know before M4 ends |
| Machine channel shipped | Specified and agreed; until the relay deploys it the app uses `report` (8.2), which shows Open with time left only as often as reports arrive |
| Delayed approvals | Specified in the relay spec (3.15) and the protocol: reply with `delay`, the `delayed` routes, `delayed` and `cancelled` notes and pushes. The pushes use `title-loc-key` `DELAYED_TITLE` / `CANCELLED_TITLE` and `loc-key` `DELAYED_BODY` / `CANCELLED_BODY` (10.1) |

### 19.3 Between this repository and the website and operations

This repository provides:

| Item | Where |
| --- | --- |
| Bundle and application ids | `com.sealctl.app` on both stores (section 4) |
| Demo path for App Review and Play review | `tools/fake-machine --review` (16.3) and the review notes (15.2) |
| Approval-card copy | 11.7 |
| Screenshots of the approval card and main screens, light and dark | Generated by UI tests against the fake relay into `store/ios/screenshots` and `store/android/images` |
| Blank card PDFs `card-a4.pdf`, `card-letter.pdf` | Built by `tools/card`, attached to each app release on GitHub |
| Crypto library list | 14.6 |
| App Privacy and Play Data safety inputs | 14.1 to 14.4 |
| `CODEOWNERS` | `.github/CODEOWNERS` |

This repository needs:

- `https://sealctl.com/privacy` covering the app's data as in 14.1, plus `/terms` and `/support`.
- Someone running the review machine during each review, and the unlisted page it serves.
- The homepage's approval scene using the app's button order: "Allow for this session", "Allow once", "Deny".
- Apple's filtering entitlement requested on the developer account (10.1).
- Play's background location declaration and video (15.3).
- The website's `/p` page, opened on a computer, draws the pairing QR code from the link's fragment in the browser, so a machine without a terminal can still be paired with the app's camera (11.5).

## 20. Open questions

1. **AGPL and the app stores.** Store terms add restrictions that AGPL-3.0 forbids for third parties distributing the app. The developer can publish their own code, but outside contributions need a grant. Proposal: `CONTRIBUTING.md` requires contributors to license their contributions to the maintainer also under terms that allow store distribution, or an additional permission under AGPL section 7. Needs a decision before the first outside pull request.
2. **Export compliance.** The app ships its own HPKE and AEAD code (in Rust), not only Apple's. It is open source and uses standard algorithms. Settle the App Store Connect encryption answers and whether a French declaration is needed.
3. **Location in the encrypted state.** The design says locations never leave the phone, and also keeps places in the encrypted state backup. The forms in 14.2 and 14.4 treat the encrypted blob as not collected. Confirm both stores accept this, or keep places out of the relay state (a new phone would then learn places again).
4. **Self-hosted relays.** Should the app accept a relay URL from a pairing QR code other than `relay.sealctl.com`? Version 1 uses one relay per phone, taken from the first pairing.
5. **Notification filtering entitlement.** Without it, automatic answers on iOS leave a passive notification. Request it from Apple at M4; decide whether the passive note is acceptable if refused.
6. **Phones without Google Play services.** No FCM, Block Store or geofencing. Options: a foreground-only mode with the WebSocket, or UnifiedPush. Not in version 1.
7. **Answers per machine?** The design keys answers by agent, key and repository, not machine. A repository cloned on two machines shares the answer. Confirm.
8. **Lock latency.** iOS and Android exit events can arrive minutes after leaving. Is a lock within about 3 minutes acceptable, or should the machine also lock when the phone stops being `near`?
9. **Rewrap without a tap.** Settled by the confirmation levels: rewrap is level 2, with biometrics for each machine (9.6).
10. **Several installs with the same words.** The relay allows 4 push devices per phone key and pushes to all, so version 1 lets any of them answer (8.7). Confirm that two phones answering the same machines is wanted, rather than one active phone.
11. **Delete relay data and the licence.** Settled: the relay keeps the licence record under the phone key and nothing else (Relay API, Deleting a phone); the app says only that the privacy policy lists what stays.
12. **iOS pushes through FCM.** If the relay cannot reach APNs, the iOS app links Firebase Messaging (10.1). That adds a Google SDK and an identifier to the iOS privacy answers. Decide before M4 ends.
13. **Machine gate.** If it is ever switched on, the design brings back one in-app purchase. The current pairing error text (11.20) avoids any mention of payment; revisit then.
14. **Translations.** Which languages after English, and whether to accept community translations.
15. **Level 2 without biometrics.** Proposed and specified: two words from the card instead of biometrics, never the passcode (9.6). Level 3 is refused until biometrics work, except through the card on the CLI. Confirm, and confirm that a phone without strong biometrics may still pair machines this way.
16. **Releasing a hold.** After a wrong number, [Release now] with biometrics lifts the one-hour hold. Keep it, or make the hour fixed?
