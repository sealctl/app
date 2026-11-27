import Foundation
import SealCore

/// The app's wording, exactly as SPEC.md 11 gives it, in one place so it can move to the
/// string catalog for translation (SPEC.md 13) without touching the screens.
public enum Texts {
    // MARK: approval card and notifications (11.7)

    /// Facts of a request that the card and the notification show.
    public struct Facts: Sendable, Equatable {
        public var kind: RequestKind
        public var level: Int
        public var subjectKind: String?
        public var subjectName: String?
        public var names: [String]
        public var agent: String?
        public var command: String?
        public var cwd: String?
        public var repoName: String?
        public var machineName: String
        public var firstItem: String?
        public var all: Bool

        public init(kind: RequestKind, level: Int, subjectKind: String? = nil, subjectName: String? = nil, names: [String] = [],
                    agent: String? = nil, command: String? = nil, cwd: String? = nil, repoName: String? = nil,
                    machineName: String, firstItem: String? = nil, all: Bool = false) {
            self.kind = kind; self.level = level; self.subjectKind = subjectKind; self.subjectName = subjectName
            self.names = names; self.agent = agent; self.command = command; self.cwd = cwd; self.repoName = repoName
            self.machineName = machineName; self.firstItem = firstItem; self.all = all
        }
    }

    /// Longest machine-controlled values on the card and in notifications (as Android).
    public static let maxName = 60
    public static let maxAgent = 40
    public static let maxLine = 80

    /// A machine-controlled string made safe to show (SPEC.md 11.7): no bidi or control
    /// characters, no line breaks, and, when `short`, cut in the middle to `max` characters.
    public static func shown(_ text: String, _ max: Int, short: Bool = true) -> String {
        displayText(text: text, maxChars: short ? UInt32(max) : 0)
    }

    /// The facts with every machine-controlled value sanitised; `short` also caps their length.
    public static func facts(_ w: Waiting, machineName: String, short: Bool = true) -> Facts {
        let ctx = w.request.ctx()
        let first = w.request.items().first
        func s(_ text: String?, _ max: Int) -> String? { text.flatMap { $0.isEmpty ? nil : shown($0, max, short: short) } }
        return Facts(
            kind: w.verdict.kind,
            level: Int(w.verdict.level),
            subjectKind: ctx?.subject.map { shown($0.kind, maxAgent, short: short) },
            subjectName: s(ctx?.subject?.name, maxName),
            names: (ctx?.names ?? []).compactMap { s($0, maxName) },
            agent: s(ctx?.agent, maxAgent),
            command: s(ctx?.command, maxLine),
            cwd: s(ctx?.cwd, maxLine),
            repoName: s(ctx?.repo?.name, maxName),
            machineName: machineName,
            firstItem: first.flatMap { s($0.object?.path, maxLine) ?? s($0.id, maxLine) },
            all: w.plan?.all ?? false
        )
    }

    private static func subject(_ f: Facts) -> String? { f.subjectName ?? f.names.first }

    /// The card's title by subject (11.7 "Titles by subject").
    public static func title(_ f: Facts) -> String {
        let s = subject(f)
        switch f.kind {
        case .agent: return "Let \(f.agent ?? "an agent") use \(s ?? "this key")?"
        case .own: return "Allow \(s ?? "this key") once?"
        case .keys:
            return f.level >= 2 ? "Let sealctl seal take over \(subjectPhrase(f)) on \(f.machineName)?" : "Allow \(subjectPhrase(f))?"
        case .unseal:
            return f.all || f.level >= 3 ? "Hand back everything on \(f.machineName)?" : "Hand back \(subjectPhrase(f)) from \(f.machineName)?"
        case .rewrap: return "Move \(f.machineName) to new words?"
        case .oldWords: return "Move an object sealed with old words?"
        case .unknown: return "\(f.machineName) sent a request this app doesn't understand. Update the app."
        default:
            switch f.subjectKind {
            case "volume": return "Mount volume \(s ?? "")?"
            case "backup": return "Back up to \(s ?? "")?"
            case "ssh": return "Use SSH key \(s ?? "")?"
            case "secret": return "Allow \(s ?? "")?"
            case nil, "", "machine":
                if let s, f.subjectKind == nil { return "Allow \(s)?" }
                return "Open \(f.machineName)?"
            default: return "Allow \(s ?? "")?"
            }
        }
    }

    private static func subjectPhrase(_ f: Facts) -> String {
        let s = subject(f) ?? f.firstItem ?? "this object"
        switch f.subjectKind {
        case "volume": return "volume \(s)"
        case "backup": return "backup \(s)"
        case "ssh": return "SSH key \(s)"
        default: return s
        }
    }

    /// The part of the title shown in monospace and the accent colour.
    public static func titleSubject(_ f: Facts) -> String? { subject(f) }

    /// Notification title and body (11.7 "Notification text"). Level 2 and 3 texts use only
    /// the machine's name from the phone's own records.
    public static func notification(_ f: Facts, biometry: String = "Face ID") -> (title: String, body: String) {
        let name = f.machineName
        let cmdIn = [f.command, f.cwd.map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
        switch f.kind {
        case .rewrap: return ("Move \(name) to new words?", "Open sealctl to confirm with \(biometry).")
        case .keys where f.level >= 2: return ("sealctl seal on \(name)", "Open sealctl to see what it takes over.")
        case .unseal where f.level >= 3: return ("Unseal everything on \(name)?", "Open sealctl to confirm. You'll need the number on its screen.")
        case .unseal: return ("Hand back from \(name)?", "Open sealctl to see what.")
        case .oldWords: return ("\(name) has an object sealed with old words.", "Open sealctl to move it.")
        case .unknown: return (title(f), "")
        case .agent:
            return (title(f), [f.repoName.map { "First use in \($0)" }, f.command, name].compactMap { $0 }.joined(separator: " · "))
        case .own: return (title(f), [cmdIn.nonEmpty, name].compactMap { $0 }.joined(separator: " · "))
        case .keys: return (title(f), name)
        default: return (title(f), [cmdIn.nonEmpty, name, f.agent].compactMap { $0 }.joined(separator: " · "))
        }
    }


    /// The note under the facts (11.7 "By kind").
    public static func note(_ w: Waiting) -> String? {
        let ctx = w.request.ctx()
        let use = w.request.uses().first
        let agent = (ctx?.agent ?? use?.agent).map { shown($0, maxAgent) }
        let repo = (ctx?.repo?.name ?? use.map { $0.repository.components(separatedBy: "/").last ?? $0.repository }).map { shown($0, maxName) }
        switch w.verdict.kind {
        case .open:
            if w.verdict.agentFirstUse, let agent { return "First use of this key by \(agent) in \(repo ?? ""). Allow is remembered." }
            return nil
        case .agent: return "First use of this key by \(agent ?? "an agent") in \(repo ?? ""). Allow is remembered; remove it in Answers."
        case .own: return "This key asks every time. It stays in memory only until the command exits."
        case .keys: return ctx?.command.hasPrefix("sealctl seal") == true ? "sealctl seal of a new object on this machine." : nil
        default: return nil
        }
    }

    public static let agentNote = "Agents ask once for each key in each repository. Your answer is kept on this phone, not in the repository."

    public static func button(_ o: ReplyOption, biometry: String = "Face ID") -> String {
        switch o {
        case .allowSession: return "Allow for this session"
        case .allow: return "Allow"
        case .allowOnce: return "Allow once"
        case .deny: return "Deny"
        case .confirm: return "Confirm with \(biometry)"
        }
    }

    /// The notification action identifiers of 10.1.
    public static func actionId(_ o: ReplyOption) -> String {
        switch o {
        case .allowSession: return "ALLOW_SESSION"
        case .allow: return "ALLOW_REMEMBER"
        case .allowOnce: return "ALLOW_ONCE"
        case .deny: return "DENY"
        case .confirm: return "CONFIRM"
        }
    }

    public static func option(actionId: String) -> ReplyOption? {
        switch actionId {
        case "ALLOW_SESSION": return .allowSession
        case "ALLOW_REMEMBER": return .allow
        case "ALLOW_ONCE": return .allowOnce
        case "DENY": return .deny
        default: return nil
        }
    }

    public static func afterAnswer(_ o: ReplyOption, _ w: Waiting) -> String {
        switch o {
        case .allowSession: return w.verdict.agentFirstUse ? remembered(w) : "Allowed for this session"
        case .allow: return w.verdict.kind == .agent ? remembered(w) : "Allowed for this session"
        case .allowOnce: return "Allowed once"
        case .deny: return "Denied"
        case .confirm: return "Confirmed"
        }
    }

    private static func remembered(_ w: Waiting) -> String {
        let u = w.request.uses().first
        let repo = shown(w.request.ctx()?.repo?.name ?? u.map { $0.repository.components(separatedBy: "/").last ?? "" } ?? "", maxName)
        return "Remembered for \((u?.agent ?? w.request.ctx()?.agent).map { shown($0, maxAgent) } ?? "the agent") in \(repo)"
    }

    public static func waitingFor(_ seconds: Int64) -> String { String(format: "WAITING · %d:%02d", seconds / 60, seconds % 60) }
    public static func moreWaiting(_ n: Int) -> String { "\(n) more waiting" }
    public static func stoppedWaiting(_ name: String) -> String { "\(name) stopped waiting." }
    public static func answersHere(_ place: String) -> String { "At \(place), this answers by itself." }
    public static func answeredByItself(_ name: String, place: String?) -> String {
        place.map { "Opened \(name) at \($0)." } ?? "Opened \(name)."
    }
    public static func unlockToAnswer(_ name: String) -> String { "Unlock your iPhone to answer \(name)." }
    public static let unlockToAnswerShort = "Unlock your phone to answer."
    /// A reply the relay did not take (SPEC.md 8.5, 11.20); the card keeps its buttons.
    public static let answerNotSent = "Couldn't send your answer — try again."
    public static let hiddenPreview = "A machine is waiting for your phone."

    public static func agentName(_ a: String?) -> String {
        switch a {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        case "qwen": return "Qwen Code"
        case "copilot": return "Copilot"
        case "cursor": return "Cursor"
        case nil: return "you"
        case let a?: return a
        }
    }

    // MARK: levels 2 and 3 (9.6, 11.23)

    public static func notNear(_ name: String) -> String {
        "\(name) isn't near this phone. Run the command at its terminal; this phone then asks for the number on its screen."
    }
    public static func noBiometrics(_ biometry: String = "Face ID") -> String {
        "This needs \(biometry), and this phone has none set up."
    }
    public static func lockedOut(_ biometry: String = "Face ID") -> String {
        "\(biometry) is locked after too many tries. Lock and unlock your iPhone with its passcode, then try again."
    }
    public static func whichNumber(_ name: String) -> String { "Which number does \(name) show?" }
    public static let lookAtTerminal = "Look at the terminal where you ran the command."
    public static let noNumber = "I don't see a number"
    public static func wrongNumber(_ name: String) -> String { "That's not the number on \(name)" }
    public static let wrongNumberBody = "The request was refused. For the next hour this phone ignores sensitive requests from that computer."
    public static let wrongNumberWhat = "Didn't run anything there? Someone else may be using it."
    public static func held(_ name: String, until: Int64) -> String {
        "Sensitive requests from \(name) are held until \(time(until)) after a wrong number."
    }
    public static func handBackAll(_ name: String) -> String { "Hand back everything on \(name)?" }
    public static let handBackAllBody = "sealctl unseal --all moves these to passwords of your own. Your files stay encrypted. Then the computer is unpaired."
    public static let atTrusted = "this starts as soon as you confirm."
    public static let away = "Away from your trusted places: this starts two hours after you confirm. Your phone and your computers can cancel it until then."
    public static let awayNoLocation = "This starts two hours after you confirm. Your phone and your computers can cancel it until then."
    public static func confirm(_ biometry: String = "Face ID") -> String { "Confirm with \(biometry)" }
    public static func leaving(_ name: String) -> String { "Leaving sealctl on \(name)" }
    public static func startsAt(_ at: Int64, now: Int64) -> String {
        let mins = (max(0, at - now) + 59_999) / 60_000
        return "Starts at \(time(at)) · \(mins) min left"
    }
    public static let delayBody = "You approved this away from your trusted places, so it waits two hours. Every paired computer has been told. If this wasn't you, cancel it."
    public static let cancelledHere = "Cancelled. Nothing was handed back."
    public static func cancelledFrom(_ name: String) -> String { "Cancelled from \(name)." }
    public static func handsBackAt(_ name: String, at: Int64) -> String { "\(name) hands everything back at \(time(at))." }
    /// The banner of a waiting level 3 action, by its kind.
    public static func delayedAt(_ what: String, name: String, at: Int64) -> String {
        switch what {
        case "words": return "Your words can be shown at \(time(at))."
        case "delete": return "Your relay data is deleted at \(time(at))."
        case "leave": return "This phone leaves sealctl at \(time(at))."
        case place: return "\(name) skips the two-hour wait from \(time(at)), unless one of your computers cancels it."
        case otherDevice: return "\(otherDeviceNote) goes ahead at \(time(at))."
        default: return handsBackAt(name, at: at)
        }
    }

    /// The kind of a phone-only delay another install with the same words started: the relay's
    /// record carries no kind, so it may be any of the actions on the phone (SPEC.md 11.23).
    public static let otherDevice = "unknown"
    public static let otherDeviceTitle = "Started on another of your devices"
    public static let otherDeviceNote = "A protected action started on another of your devices"
    public static func otherDeviceBody(_ at: Int64) -> String {
        "Showing your words, deleting your relay data or leaving sealctl was started on another phone or tablet "
            + "with your words. It goes ahead at \(time(at)). Not you? Cancel it."
    }

    /// The title of a delayed action's screen, by its kind; `name` is the machine's, for `unseal_all`.
    public static func delayScreenTitle(_ what: String?, name: String?) -> String {
        switch what {
        case "words": return "Showing your words"
        case "delete": return "Deleting your relay data"
        case "leave": return "Leaving sealctl"
        case place: return "Trusting \(name ?? "a place")"
        case otherDevice: return otherDeviceTitle
        default: return leaving(name ?? "this computer")
        }
    }

    /// The text under the countdown while a delayed action waits.
    public static func delayWaiting(_ what: String?, at: Int64) -> String {
        what == otherDevice ? otherDeviceBody(at) : delayBody
    }

    /// A delayed action cancelled on this phone.
    public static func delayCancelledHere(_ what: String?) -> String {
        what == "unseal_all" ? cancelledHere : "Cancelled. Nothing happened."
    }

    /// A delayed action whose wait is over.
    public static func delayOver(_ what: String?) -> String {
        switch what {
        case "unseal_all": return "The hour is over. The computer goes ahead."
        case place: return "Nobody cancelled it. The place now skips the two-hour wait."
        case otherDevice: return "The wait is over. The phone or tablet that started it can go ahead."
        default: return "The hour is over."
        }
    }

    /// A delayed action the relay no longer has, or none at all.
    public static func delayGone(_ what: String?) -> String {
        what == otherDevice
            ? "This is no longer waiting: the phone or tablet that started it finished it, or it expired."
            : "This waited too long. Start again."
    }

    // MARK: an action on the phone, by where its delay stands (11.23)

    /// The kind of the delayed record that announces trusting a place (11.9).
    public static let place = "place"

    /// Why an action on the phone waits two hours, from the reason kept when it started (or,
    /// with `started` false, the one that applies if it starts now). `place` and `until`: the
    /// trusted place the phone is in that doesn't lift the wait yet, and when it will.
    public static func waitReason(_ reason: String, place: String?, until: Int64, started: Bool = true) -> String {
        switch reason {
        case "away":
            return started ? "You started this away from your trusted places, so it waits two hours."
                : "You're away from your trusted places, so this waits two hours."
        case "unsettled":
            return "You're at \(place ?? "a place"), which was trusted less than two hours ago, so this "
                + (started ? "still waits" : "waits") + " two hours."
                + (until > 0 ? " \(place ?? "It") skips the wait from \(time(until))." : "")
        case "no_always":
            return "Location isn't set to \"Always\" for sealctl, so it can't tell when you're at a trusted place. This waits two hours."
        case "places_off": return "You have no trusted places, so this waits two hours."
        default: return "You approved this away from your trusted places, so it waits two hours."
        }
    }

    /// What the person does at the end of the wait, by kind.
    static func goal(_ what: String?) -> String {
        switch what {
        case "words": return "see your words"
        case "delete": return "delete your relay data"
        default: return "finish leaving"
        }
    }

    /// What happens next while it waits: the note at `at`, confirming, and until when (`until`, 0 unknown).
    public static func waitNext(_ what: String?, at: Int64, until: Int64, biometry: String = "Face ID") -> String {
        "At \(time(at)) sealctl will notify you. Open it then and confirm with \(biometry) to \(goal(what))."
            + (until > 0 ? " You'll have until \(time(until))." : "")
    }
    public static let waitTold = "Every paired computer has been told, and can cancel it."
    public static let waitCancel = "Cancel stops it: nothing happens, and your computers are told."

    /// The start screen, before confirming: the wait, why, and what comes after (11.23).
    public static func beforeStart(_ what: String?, reason: String, place: String?, until: Int64, at: Int64,
                                   biometry: String = "Face ID") -> String {
        waitReason(reason, place: place, until: until, started: false)
            + " If you confirm now, sealctl will notify you at \(time(at)). Open it then and confirm with \(biometry) to \(goal(what))."
            + " Every paired computer is told, and can cancel it until then."
    }

    /// A trusted place's row (11.9): when it starts to skip the wait, or why it doesn't.
    public static func placeSettles(_ at: Int64) -> String {
        "Skips the two-hour wait from \(time(at)), unless one of your computers cancels it."
    }
    public static let placeWaiting = "Every paired computer has been told, and can cancel it with sealctl cancel. Cancel here and the place is not trusted."
    public static let placeUnconfirmed = "Not confirmed with the relay yet, so it doesn't skip the two-hour wait."
    public static let placeConfirmAgain = "Confirm again"
    public static let placeStaleClock = "Skips the two-hour wait two hours after your phone next reaches sealctl."
    public static func trustHere(_ at: Int64) -> String {
        "Showing your words and leaving sealctl skip the two-hour wait here from \(time(at)), two hours from now. "
            + "Every paired computer is told and can cancel it until then, so someone holding your unlocked phone can't trust a place unseen."
    }

    /// Under the title while it waits: when it was started (unknown for an old record) and when it goes ahead.
    public static func goesAheadAt(started: Int64, at: Int64) -> String {
        started > 0 ? "Started at \(time(started)) · goes ahead at \(time(at))" : "Goes ahead at \(time(at))"
    }
    public static func minutesLeft(_ at: Int64, now: Int64) -> String { "\((max(0, at - now) + 59_999) / 60_000) min left" }
    public static func readyUntil(_ expires: Int64) -> String { "Ready until \(time(expires))" }
    public static let readyBody = "The wait is over. Finish before then, or this has to start again."
    public static func readyButton(_ what: String?) -> String { what == "words" ? "Show my words" : "Finish" }
    /// The Machines banner once it is ready.
    public static func readyBanner(_ what: String?, expires: Int64) -> String {
        "\(delayScreenTitle(what, name: nil)): ready until \(time(expires))."
    }
    public static let startAgain = "Start again"
    /// Another install's action is running when this one is about to start.
    public static func otherDeviceRunning(_ at: Int64) -> String {
        "\(otherDeviceNote) goes ahead at \(time(at)). If that was you, finish it there; starting here waits two hours of its own."
    }
    public static let tooManyDelayed = "The relay is holding as many protected actions as it can for these words. Try again when one of them has ended."
    /// The "Ready" notification's body: the window to finish.
    public static func readyNote(_ expires: Int64) -> String { "Open it by \(time(expires)), or it has to start again." }

    public static func handedBack(_ name: String, done: Int, failed: Int) -> String { "\(name) handed back \(done) objects. \(failed) failed." }

    // MARK: pairing and errors (11.5, 11.20)

    public static let notACode = "This isn't a sealctl pairing code."
    public static let codeExpired = "This code has expired. Run `sealctl pair` again."
    public static let newerVersion = "This machine runs a newer sealctl. Update the app."
    public static func otherRelay(_ theirs: String, ours: String) -> String {
        let t = theirs.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        return "This machine uses another relay (\(t)). This phone uses \(ours)."
    }
    public static let tooMany = "This phone has 100 machines paired, the most it can have. Unpair one first."
    public static let licenceRequired = "The relay didn't accept this machine. Run `sealctl status` on it to see why."
    public static let relayDown = "The relay isn't answering. Trying again."
    public static let relayBackupKept = "The relay didn't delete the backup, so it stays on. Try again."
    public static func relayError(_ code: String) -> String { "The relay refused this (\(code))." }
    public static func paired(_ name: String) -> String { "Paired. \(name) can now ask this phone for keys." }
    public static let offline = "Offline. Requests reach this phone when it is back online."
    public static let notificationsOff = "Notifications are off. Requests can't reach you while sealctl is closed."
    /// Places exist, but location access isn't Always (SPEC.md 11.9): they count for nothing.
    public static let placesAlways = "Places need location access Always. Until then, a session stays open up to 1 hour and reopening always takes a tap."
    public static func rateLimited(_ until: Int64) -> String { "This phone has used its relay limit for today. It resets at \(time(until))." }
    public static let clock = "This phone's clock is more than 5 minutes off. Turn on automatic date and time."
    public static let signature = "The relay refused this phone's signature. Update the app."
    public static let fromLink = "Scan the code with sealctl. On a computer without a terminal, open the link in its browser to see the code."

    // MARK: pushes and notices (10.1, 10.4)

    public static let testPush = "Test from the relay. Requests reach this phone."
    public static let requestTitle = "Waiting for your phone"
    public static let requestBody = "A machine is asking for a key. Open to see the request."
    public static let delayedTitle = "Approved on your phone"
    public static let delayedBody = "Something sensitive was approved on your phone and starts in two hours. Open sealctl to see it or cancel it."
    /// The note of a relay `delayed` push, by the kind of the record it announces.
    public static func delayedNote(_ what: String?, at: Int64) -> (title: String, body: String) {
        what == otherDevice
            ? (otherDeviceNote, "It goes ahead at \(time(at)). Open sealctl to see it or cancel it.")
            : (delayedTitle, delayedBody)
    }
    public static let cancelledTitle = "Cancelled"
    public static let cancelledBody = "A pending sensitive action was cancelled."
    public static let placeLearned = "Trust this place? You opened your machines here on 3 mornings."
    public static func leftPlace(_ place: String, names: String) -> String { "You left \(place). Locked \(names)." }
    public static func placesUnwatched(names: String) -> String { "sealctl can no longer notice you leaving a place. Locked \(names)." }
    public static func ready(_ what: String) -> String {
        switch what {
        case "words": return "Ready: open sealctl to finish showing your words."
        case "delete": return "Ready: open sealctl to finish deleting your relay data."
        default: return "Ready: open sealctl to finish leaving."
        }
    }

    // MARK: Activity (11.12)

    /// The second line of an Activity row (`activityRow` in the shared crate makes the parts).
    public static func activityDetails(_ row: ActivityRow) -> String { row.details.joined(separator: " · ") }

    /// One label for an Activity row, read in order: time, what was used, outcome, details.
    public static func activityLabel(_ time: String, _ row: ActivityRow) -> String {
        ([time, row.subject, row.outcome] + row.details).joined(separator: ", ")
    }

    /// A month on its own, as a title ("November", "Listopad"): the standalone form (`LLLL`),
    /// which differs from the form inside a date in Polish, Ukrainian, Russian and others
    /// ("listopada"), with its first letter capitalised for the locale.
    public static func monthName(_ month: Int, locale: Locale = .current, short: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = locale
        let names = (short ? f.shortStandaloneMonthSymbols : f.standaloneMonthSymbols) ?? []
        guard (1...names.count).contains(month) else { return "\(month)" }
        let name = names[month - 1]
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// The summary title of a month `YYYY-MM`.
    public static func monthTitle(_ ym: String, locale: Locale = .current) -> String {
        guard let m = Int(ym.split(separator: "-").last ?? "") else { return ym }
        return monthName(m, locale: locale)
    }

    /// The month summary's first figure: "312 keys used on 3 machines", "1 key used on 1 machine".
    public static func keysUsed(_ keys: UInt64, machines: Int) -> String {
        "\(count(keys, "key", "keys")) used on \(count(UInt64(machines), "machine", "machines"))"
    }

    /// The month summary's declines: "4 requests declined", "1 request declined".
    public static func requestsDeclined(_ n: UInt64) -> String { "\(count(n, "request", "requests")) declined" }

    /// `n` and the noun in the English singular for one, else the plural.
    static func count(_ n: UInt64, _ one: String, _ other: String) -> String { "\(n) \(n == 1 ? one : other)" }

    /// A day's header figures: "37 uses", "1 use · 2 declined".
    public static func dayCounts(_ c: ActivityCounts) -> String {
        [c.uses == 1 ? "1 use" : "\(c.uses) uses", c.declined > 0 ? "\(c.declined) declined" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The heatmap's title: "1,204 key uses in the last year".
    public static func heatTitle(_ total: UInt64, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        let n = f.string(from: NSNumber(value: total)) ?? "\(total)"
        return "\(n) key \(total == 1 ? "use" : "uses") in the last year"
    }

    /// A heatmap day: "Nov 24, 2026: 37 key uses, 2 declined".
    public static func heatDay(_ date: Date, used: UInt64, declined: UInt64, locale: Locale = .current) -> String {
        "\(mediumDate(date, locale: locale)): \(used) key \(used == 1 ? "use" : "uses")" + (declined > 0 ? ", \(declined) declined" : "")
    }

    public static func mediumDate(_ date: Date, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    // MARK: formatting

    public static func time(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// Dates the user copies onto the card are always ISO.
    public static func isoDate(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    public static func mediumDate(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// "2 h 10 min"
    public static func duration(_ seconds: Int64) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 && m > 0 { return "\(h) h \(m) min" }
        if h > 0 { return "\(h) h" }
        return "\(max(m, 1)) min"
    }

    /// The time to a lock in whole minutes, rounded down (SPEC.md 11.8): "3 h 47 min", "47 min",
    /// "under a minute".
    public static func countdown(_ ms: Int64) -> String {
        ms < 60_000 ? "under a minute" : duration(ms / 1000)
    }

    /// `countdown` in words for VoiceOver: "3 hours 47 minutes", "47 minutes", "under a minute".
    public static func spokenCountdown(_ ms: Int64) -> String {
        if ms < 60_000 { return "under a minute" }
        let s = ms / 1000
        func words(_ n: Int64, _ unit: String) -> String { n == 1 ? "1 \(unit)" : "\(n) \(unit)s" }
        var parts: [String] = []
        if s >= 3600 { parts.append(words(s / 3600, "hour")) }
        if s % 3600 >= 60 { parts.append(words((s % 3600) / 60, "minute")) }
        return parts.joined(separator: " ")
    }

    /// "just now", "2 min ago", "yesterday".
    public static func ago(_ ms: Int64?, now: Int64 = nowMs()) -> String {
        guard let ms, ms > 0 else { return "never seen" }
        let s = (now - ms) / 1000
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86_400 { return "\(s / 3600) h ago" }
        if s < 2 * 86_400 { return "yesterday" }
        return "\(s / 86_400) days ago"
    }
}

public func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

extension String {
    /// Nil when empty.
    public var nonEmpty: String? { isEmpty ? nil : self }
}
