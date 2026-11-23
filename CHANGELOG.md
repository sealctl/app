# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## 0.1.0

The sealctl phone app for iPhone and Android: it holds the root made from your 24 words and
approves your computers' requests for keys. API keys, SSH and git signing keys, encrypted volumes
and backups, opened only when your phone approves: one tap opens a work session, or approves
every use for the keys you choose. Your AI agents never see the key. Built on `sealctl-core` 0.7.0
(the commit pinned in `Cargo.toml`) with UniFFI 0.32.2.

### Added

- Onboarding: 24 words shown behind the device lock and hidden from screenshots and screen
  recording, then a card check; restore from typed words, or on Android from Block Store.
- Pairing a computer by scanning its QR code or typing its code, behind biometrics.
- The approval card and notifications with unlock-first actions; remembered answers per agent
  and repository; places that set how long a session stays open.
- Confirmation levels 2 and 3 for sensitive requests: number match, the signed plan, strong
  biometrics, a two-hour delay away from a trusted place with cancel from the phone or any paired
  computer, and the hand-back report.
- Machines, activity, inventory, answers, places and settings screens; push registration and a
  test push; relay state sync; Delete my relay data, Erase and Leave sealctl.
- iPhone: SwiftUI app with the keychain items of SPEC.md 7.2, Face ID or the passcode for the
  words, a `.biometryCurrentSet` gate for levels 2 and 3, a Notification Service Extension and
  CLMonitor places.
- Android: Jetpack Compose app with Android Keystore keys, `FLAG_SECURE` on the words and FCM
  push.
- `sealctl-app` Rust crate shared by both apps: state model and merge, `decide()` for the levels
  of asking, day records, place learning, lifetimes, monthly summaries, card checks, SQLite store.
- `fake-relay` and `fake-machine` test tools.
