# How Claude reviews pull requests here

The automated review (`.github/workflows/claude-code-review.yml`) and "@claude review this"
both follow this file, together with `CLAUDE.md`. The review is advice: it never approves,
blocks, pushes or merges.

## What to report

Report only real, specific problems you can point to in this pull request's diff, in this
order of priority (skip the areas the change does not touch):

1. **Correctness.** Wrong results, missed cases the code claims to handle, broken error paths,
   off-by-one, wrong units, state left half-changed after a failure, resume or retry that
   repeats a step that already took effect.
2. **Security.** Secrets or key material reaching logs, errors, arguments, the environment of
   other processes, files or the network; checks done after use instead of before; signatures,
   proofs, sizes or times not checked; anything weakening the approval model.
3. **Privacy.** Personal names, emails, home addresses, phone numbers, Cloudflare Workers
   development hostnames (the "workers dot dev" domain) or the staging relay's hostname in code,
   docs, tests, fixtures or commit text; locations, IP addresses or request contents leaving
   where the SPEC keeps them.
4. **Protocol and SPEC consistency.** Behaviour that differs from `SPEC.md` or
   `docs/protocol.md` without changing them in the same pull request; any change to the test
   vectors (a protocol break); words the product does not use (Locked, Open, Waiting, One tap,
   Places, words, phone, machine).
5. **Concurrency and timing.** Locks or guards held across an `await`; races between a timer
   and a request; wall clock where a monotonic clock is needed (or the reverse: sleep and clock
   changes); retry or reconnect loops without a pause, backoff or `429` handling.
6. **Test quality.** A fix without a test that fails without it; tests that sleep to order
   events instead of using a fake clock, a gate or an explicit signal; tests that talk to a
   live relay; assertions that cannot fail.
7. **Supply chain and CI shape.** Actions not pinned to a full commit SHA; broader
   `permissions` than the job needs; secrets on `pull_request` jobs; `pull_request_target`;
   jobs without `timeout-minutes`; required checks behind a workflow-level `paths:` filter;
   new dependencies without a reason; `cargo vet` exemptions without the note "reviewed by an
   AI agent, not a human audit"; npm installs that run scripts.

Do not report:

- style, naming, formatting, comment wording or "could be cleaner" (formatters and linters run
  in CI);
- "consider adding tests" or "consider handling errors" without naming the concrete case that
  is not covered and what goes wrong;
- problems that were there before this pull request, unless the change makes them worse;
- guesses. Read the code around a change before you claim a bug, check `SPEC.md` when
  behaviour changes, and when you cannot settle a point, say "I could not verify X" in the
  summary instead of filing it as a finding.

## Generated files

Do not review these line by line; review the source change that produced them instead:

- UniFFI bindings `android/core/src/main/java/com/sealctl/core/sealctl_core.kt`,
  `.../app/sealctl_app.kt`, `ios/Packages/SealCore/Sources/SealCore/sealctl_core.swift` and
  `sealctl_app.swift`: review the Rust in `shared/` (or the `sealctl-core` pin) that changed
  them;
- `Cargo.lock`: review `Cargo.toml` (the `sealctl-core` tag, new crates and why);
- `android/gradle/verification-metadata.xml`: review the Gradle dependency change
  (`gradle/libs.versions.toml`, build files);
- `notices/`: review `scripts/notices.sh` and the dependency change;
- `supply-chain/imports.lock`: review `supply-chain/config.toml` and `audits.toml`.

When the Rust surface changes but the bindings do not (or the reverse), say so: both
`scripts/build-core-ios.sh` and `scripts/build-core-android.sh` must have been run, and
`scripts/check-core.sh` fails otherwise.

## Checklist for this repository

- **Both platforms in parity.** A behaviour change on iPhone has the same change on Android
  (and the reverse), or the pull request says why not. Rules that decide when the phone asks
  live in Rust (`shared/`, `decide`), not in Swift or Kotlin. Say which side is missing.
- **The rules the app never breaks** (SPEC 2): the words never leave the phone readable; the
  paper card check comes first; no price, payment or licence in the app; derived keys stay in
  Rust; locations stay on the phone; no analytics, trackers or crash SDK; no logs of names,
  paths, commands or machines without private redaction; no asking rule becomes a setting.
- **Screens that show words or approvals** (SPEC 11.21, 11.7, 11.23): iOS draws the words in
  a secure text field layer, hides them while the screen is recorded or mirrored and covers the
  app switcher snapshot; Android sets `FLAG_SECURE` (and `setRecentsScreenshotEnabled(false)` on
  13+) on words, approval card, number match and plan screens; no copy, share or selection on
  the words; the `Words` object is released when the screen closes.
- **FFI.** Secrets cross the boundary only as UniFFI objects that zeroise; Swift and Kotlin
  never hold a derived key; the UniFFI version matches the one `sealctl-core` pins; the core is
  pinned to a release tag, never a branch.
- **Relay client and fake relay.** Clients pause after every failed call, back off, honour
  `429` and treat terminal answers as final. Tests use `tools/fake-relay` and
  `tools/fake-machine`, never a live relay; the fake relay keeps real signature checks.
- **Concurrency.** Swift 6 strict concurrency (no `@unchecked Sendable` or
  `nonisolated(unsafe)` without a reason); no main-thread blocking on the relay; Kotlin
  coroutines cancelled with their scope; notification handlers that finish within the
  platform's time limit.
- **Tests.** Engine timing tests use the fake relay's clock and failure controls, not sleeps;
  UI tests match biometrics through the simulator, never a bypass in the app.

## How to write each comment

- One inline comment per distinct problem, on the line that causes it. At most about 8 inline
  comments; if there are more, keep the most severe and list the rest in one line each in the
  summary.
- Start with the severity in bold: **blocker** (wrong behaviour, security or privacy problem,
  protocol break: must not merge as is), **should fix** (a real problem with limited impact, or
  a missing test for a concrete case), **nit** (small but real, such as a misleading error
  message; at most 2 per review, and never for style).
- Then: what is wrong, why it matters here (the input or sequence that triggers it), and a
  concrete fix. Use a suggestion block only when committing it fixes the problem entirely.
- Quote the rule when the finding is a `CLAUDE.md` or `SPEC.md` rule, with its section.

## The summary comment

One comment, rewritten on every push, in this shape:

```markdown
### Claude review: <verdict>

<one or two sentences: what the change does, as you understood it>

**Checked:** <the areas you actually checked, e.g. correctness of the resume path, SPEC 18.6,
the new test, workflow permissions>
**Findings:** <n> blocker, <n> should fix, <n> nit (inline). <one line per finding that did not
fit inline>
**Could not verify:** <what you could not settle and why, or "nothing">
```

Verdicts: **no issues found**, **minor issues** (nits or should-fix only), **changes
suggested** (at least one should-fix that matters), **blocking issues** (at least one blocker).
Saying "no issues found" is a good outcome; do not invent findings to fill the review.
