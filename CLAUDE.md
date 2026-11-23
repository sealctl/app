# sealctl app: rules for AI agents

This file is read by Claude Code, including the GitHub review and "@claude" workflows. It holds
the rules for working in this repository; `SPEC.md` is the build spec. When a rule here and the
SPEC disagree, say so and fix one of them in the pull request; don't silently pick.

## What this is

- The sealctl phone app: it holds the root made from the user's 24 words and approves paired
  machines' requests for keys (API keys, SSH and git signing keys, encrypted volumes and
  backups), once per work session or on every use.
- This repository (AGPL-3.0): the iPhone app (`ios/`, Swift 6, SwiftUI), the Android app
  (`android/`, Kotlin, Compose), the Rust crate both share (`shared/`, `sealctl-app`), and test
  tools (`tools/fake-relay`, `tools/fake-machine`). The protocol core, `sealctl-core`, comes
  from the public `sealctl/sealctl` repository, pinned to a release tag.
- Specs: `SPEC.md` (sections 2, rules the app never breaks; 5, bindings; 9, levels of asking;
  11, screens; 16, testing; 17, CI). The wire contract is `docs/protocol.md` in
  `sealctl/sealctl`. Read the relevant section before changing behaviour and update it in the
  same pull request when behaviour changes.

## Product facts that must stay consistent

- Describe the current product only (0.7 and later): no Ledger, OpenPGP-on-Ledger, 0.5 or 0.6
  history.
- Approval is per work session or on every use. "One tap per use" is wrong.
- Level 3 (unseal everything, show the words, delete relay data) waits two hours away from a
  trusted place; a place added by hand lifts that wait only after 24 hours.
- Same words everywhere: Locked, Open, Waiting, One tap, Places, Answers, Inventory, words,
  card.
- The rules in SPEC 2 are never broken: words never leave the phone readable; the card check
  comes first; no price, payment or licence in the app; derived keys stay in Rust; locations
  stay on the phone; no analytics, trackers or crash SDK; no unredacted logs of names, paths,
  commands or machines; no asking rule is a setting.

## Both platforms

- A behaviour change lands on iPhone and Android in the same pull request, or the pull request
  says which side follows and why. Rules that decide when the phone asks live in Rust
  (`shared/`), so both platforms run the same tests.
- Screens that show the words, the approval card, the number match or the plan keep the
  screenshot and recording protections of SPEC 11.21 (secure text field layer and capture
  checks on iOS; `FLAG_SECURE` and no recents screenshot on Android).

## The protocol is a contract

- `docs/protocol.md` and its test vectors in `sealctl/sealctl` are the contract between the
  CLI, these apps and the relay. The apps run `v1.json` through the generated bindings; a vector
  change is a protocol break and starts in `sealctl/sealctl`, never here.
- No new cryptography: derivation, sealing and signing come from `sealctl-core`. Secrets cross
  the FFI boundary only as UniFFI objects that zeroise; Swift and Kotlin never hold a derived
  key.
- Updating the core is one pull request: bump the tag in `Cargo.toml`, run
  `scripts/build-core-ios.sh` and `scripts/build-core-android.sh`, commit the regenerated
  bindings (`sealctl_core.*`, `sealctl_app.*`); `scripts/check-core.sh` fails otherwise. Never
  edit the generated bindings by hand.

## Tests

- Tests run against `tools/fake-relay` and `tools/fake-machine` (or the in-memory fakes), never
  the staging or production relay; never put a live relay URL in a test, fixture or CI job.
- A bug fix comes with a test that fails without the fix (write it first and watch it fail).
- Flaky tests are fixed, not retried into green. Order events with the fake relay's clock and
  failure controls, a gate or an explicit signal, never with a sleep.
- Every relay client loop pauses after an error, backs off (doubling up to a cap, with jitter),
  waits out `429` and `Retry-After`, stops background work on the daily limit, and never repeats
  a call that got a final answer (`404 gone`, `403`, any `400`).
- No biometric bypass in any build; UI tests match Face ID through the simulator.
- Rust: `cargo fmt`, `cargo clippy --all-targets -- -D warnings`, `cargo test --workspace`.

## CI shape

- One run per pull request, cancelled by a newer push; runs on `main`, schedules and manual
  runs get a concurrency group of their own and are never cancelled. Every job has
  `timeout-minutes`.
- Required checks never sit behind a workflow-level `paths:` filter: a `changes` job reads the
  pull request's file list and jobs use a job-level `if` (a skipped job passes). macOS jobs
  (5 at a time on the free plan) run on pull requests only when their files change.
- No secrets on `pull_request` jobs (the Claude workflows' `CLAUDE_CODE_OAUTH_TOKEN` is the one
  documented exception), no `pull_request_target`, no `${{ }}` inside `run:`.

## Supply chain

- GitHub Actions pinned to full commit SHAs, least-privilege `permissions`,
  `persist-credentials: false`; a new third-party action needs a pull request that says why.
- Rust: `Cargo.lock` committed; `cargo deny` and `cargo vet` pass; the only git dependency is
  `sealctl-core`, pinned. A `cargo vet` exemption or audit written by an agent says so in its
  notes: "reviewed by an AI agent (Claude) on <date> ... not a human audit".
- Gradle: dependency verification metadata (`android/gradle/verification-metadata.xml`) and
  wrapper validation; repositories `google()` and `mavenCentral()` only.
- A new dependency needs a reason in the pull request: who maintains it, how widely it is used,
  what runs at build or install time.

## Privacy

- Never add personal names, personal email addresses, home addresses, phone numbers or any
  Cloudflare Workers development hostname (the "workers dot dev" domain) to code, docs, store
  text, tests, fixtures, commits or pull requests. The staging relay's hostname is private:
  write `https://<relay>`. Examples use `dev@mbp.example.com` style names. Public contact is
  `support@sealctl.com`.
- Never commit Firebase, App Store Connect or signing material; never read or print secrets or
  test identities' words.

## Security wording

Until a fix is released, commit messages, pull request titles and descriptions, CHANGELOG
lines and code comments describe a security fix neutrally (what changed, not how to exploit
the old behaviour), with no severity or attack details.

## Commits and pull requests (also for @claude)

- Work on a branch and open a pull request; `main` is protected. Squash merges only, done by a
  maintainer after CI is green and review comments are answered.
- Keep commits focused; stage files by path. Describe what was tested (platform, OS version).
- An agent never merges, approves, force-pushes, pushes to `main`, creates or moves tags,
  submits to a store, deploys, changes workflows, rulesets, repository settings or secrets.
  When asked to, it explains that a maintainer has to.
- The "@claude" workflow runs on Linux: it can run the Rust tests, not Xcode or the Android
  emulator. Say which tests could not run there.

## Reviewing

Reviews follow `.github/claude-review.md`: report only real, specific problems with a severity,
the reason and a concrete fix, and one summary of what was checked.
