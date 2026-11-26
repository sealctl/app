# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- Activity: a heatmap of the last year at the bottom of the tab, as GitHub's contribution graph:
  53 weeks of key uses by day, a tap shows a day's figures, one VoiceOver or TalkBack element
  that moves day by day or week by week. The phone keeps a small table of daily counts for it.

### Changed

- A newly trusted place (learned, or "Trust where I am now") skips the two-hour wait of Show
  words, Delete my relay data and Leave sealctl two hours after it is trusted, instead of from
  the same time the next day. Trusting it is announced to every paired computer and your other
  phones, which can cancel it in those two hours ("Run: sealctl cancel"); a cancel, or removing
  the place, means it is not trusted. Only once the relay confirms nobody cancelled does the place
  skip the wait. Its row says from when, or offers [Confirm again] when it could not be confirmed.
  The place's other comforts start at once, as before.
- Activity: the newest day is open and each of the ten days before today with uses is one row
  with its figures ("37 uses · 2 declined"); a tap opens or closes it. Older days are no longer
  listed. The same for one machine's Activity.
- Usage entries are kept 90 days (they were kept 13 months); "This machine was lost or stolen"
  still reads its 90 days. The heatmap's daily counts are kept 400 days and are filled once from
  the entries already on the phone. An entry a machine reports that is older than 90 days is no
  longer recorded or counted.
- iPhone: the lifetimes (and the usage log's trim) now apply when the app comes to the
  foreground, at most once a day.
- Android: Activity shows the previous months behind a chevron, as on iPhone.
- A machine's day ends at the next 02:00 local time or 24 hours after its first approval,
  whichever is first (it was 14 hours, which ended a day begun in the morning in the middle of
  the evening). The CLI's own hard stop changes to 24 hours in `sealctl/sealctl`.
- Without location access Always ("Allow all the time" on Android), approvals carry the place
  kind `none` (sessions up to 1 hour, growing), as without location: the phone can't notice
  leaving a place then. They carried `other` (10 minutes, no growth), so a phone at its trusted
  place asked all day. The Machines tab, Settings and Places show a banner with [Open settings]
  while a trusted place exists without it.
- Android: after the first trusted place, and from onboarding, "Allow location all the time"
  explains first and then opens the system's location page for sealctl.

### Fixed

- Show words, Delete my relay data and Leave sealctl after their two-hour wait: the delay screen
  now turns into "Ready until 12:37" with [Show my words] or [Finish] by itself at the end of the
  wait, from Settings, the Machines banner ("Showing your words: ready until 12:37.") or the
  "Ready" notification, also when the app was closed. Before, the notification and the banner
  opened a screen that only said "The hour is over." with no way to finish. Once the hour to
  finish has passed: "This waited too long. Start again." with [Start again].
- A second tap on Show words (or Delete, or Leave) while the first start was still on its way to
  the relay no longer starts a second two-hour wait: starts of one kind run one at a time (a slow
  start of Show words does not hold back Delete), and while one of a kind waits or is ready, its
  start opens that one. The waiting screen shows when it was started
  and when it goes ahead. An action another of your devices started is named on the start screen
  before anything starts.
- Android: the "Ready" notification comes from an alarm at the end of the wait instead of a
  WorkManager job, which Android could hold back past the time to finish. It is exact when
  sealctl may set alarms (Alarms & reminders; the delay screen offers [Allow alarms]), and is set
  again after a reboot, an update or a force stop.
- The waiting screen of Show words, Delete my relay data and Leave sealctl gives the real reason
  for the wait, recorded when it started (away from your trusted places; at a place trusted less
  than two hours ago, and when it will skip the wait; location not set to "Allow all the time";
  no trusted places) instead of always "You approved this away from your trusted places". It
  also says what happens next ("At 12:04 sealctl will notify you. Open it then and confirm with
  your fingerprint or face to see your words. You'll have until 13:04.") and what Cancel does.
  The start screens say the same before you confirm.
- Android: leaving a start screen while the relay was registering the delay could leave a record
  the phone never stored, which it then showed as started on another device.
- A record the relay no longer lists after it said "released" is shown as expired instead of
  offering a Finish that could only fail.
- The Machines banner of Leave sealctl says "This phone leaves sealctl at 11:00." instead of
  "This phone hands everything back at 11:00."
- The place the phone is inside is no longer lost when the system restarts the app: on Android
  it comes back while the geofences that would have reported leaving are still registered (same
  boot, no force stop or update since), and the geofences are registered again at every start;
  on iPhone it is read from the place monitor's own records at launch. Leaving still locks the
  machines opened there.
- Location turned off on Android: the place stops counting until the geofences are registered
  again, instead of staying current.
- iPhone: asking for location access Always a second time no longer waits for an answer the
  system never gives.

- Month names in Activity use the standalone form, capitalised ("Listopad", not "listopada" in
  Polish; also Ukrainian, Russian and other languages that inflect them).
- An SSH signature a machine reports from its session reads "SSH key ed25519", as when the
  phone asked, instead of "ed25519" with "ssh" repeated in its details.
- The month summary says "1 key used on 1 machine" and "1 request declined" for one, instead of
  "1 keys", "1 machines" and "1 requests".
- Android: the app no longer stops taking taps after the approval card was swiped down, tapped
  outside or closed with back. The card stays until it is answered or closed, as on iPhone; back
  leaves the app with the card still waiting, and closes a card whose request stopped waiting.
- Android: no more pauses when the app comes back or Activity opens. The Activity days, the
  heatmap and "This machine was lost or stolen" read the phone's store off the main thread;
  Activity draws only the uses on screen and redraws only what changed; the Machines tab
  redraws only the parts that count the seconds.
- Android: a screen left open in the background no longer keeps working there. Its countdowns
  and its relay checks (every 5 s while leaving sealctl, every 15 s on a delay) stop when the app
  leaves the screen and run again at once when it comes back.

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
