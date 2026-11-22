# Changelog

## Unreleased (0.1.0)

Built on `sealctl-core` 0.7.0 from the `sealctl` `phone` branch, commit
`ac3f1e92151ee62ce91617244df5ca1f6d2287a0` (pre-release exception to SPEC.md 5.2: no release tag
holds the core yet). UniFFI 0.32.2.

- `sealctl-app` Rust crate: state model and encoding, merge with tombstones, `decide()` for the
  levels of asking and confirmation levels, day records, place learning, lifetimes, monthly
  summaries, card checks, SQLite store.
- `fake-relay` and `fake-machine` test tools.
- Android app: onboarding (words behind the prompt, FLAG_SECURE, card check), restore from typed
  words and Block Store, pairing by QR code or typed code with the biometric gate, the approval
  card and notifications with unlock-first actions, levels 2 and 3 (number match, plan, strong
  biometrics, one-hour delay with cancel, hand-back report), machines, activity, inventory,
  answers, places, settings, push registration and test push, relay state sync, Delete my relay
  data, Erase, Leave sealctl.
- iPhone app (Swift 6, SwiftUI, Observation; XcodeGen): the same flows as Android, with the
  keychain items of SPEC.md 7.2, Face ID or the passcode for the words, the `.biometryCurrentSet`
  gate for levels 2 and 3, words drawn in a secure layer and hidden while recorded, the
  Notification Service Extension, the app group snapshot and inbox, notification categories
  with unlock-first actions, CLMonitor places. Packages SealCore, Vault, Relay, Places, Engine,
  DesignSystem; `scripts/build-core-ios.sh`. Simulator only for now (no Apple developer account):
  no APNs, iCloud Keychain sync or universal links yet.
