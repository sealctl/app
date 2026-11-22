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

    public static func facts(_ w: Waiting, machineName: String) -> Facts {
        let ctx = w.request.ctx()
        let first = w.request.items().first
        return Facts(
            kind: w.verdict.kind,
            level: Int(w.verdict.level),
            subjectKind: ctx?.subject?.kind,
            subjectName: ctx?.subject?.name.nonEmpty,
            names: ctx?.names ?? [],
            agent: ctx?.agent,
            command: ctx?.command.nonEmpty,
            cwd: ctx?.cwd.nonEmpty,
            repoName: ctx?.repo?.name.nonEmpty,
            machineName: machineName,
            firstItem: first.map { $0.object?.path.nonEmpty ?? $0.id },
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
        let cmdIn = [f.command.map(cut), f.cwd.map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
        switch f.kind {
        case .rewrap: return ("Move \(name) to new words?", "Open sealctl to confirm with \(biometry).")
        case .keys where f.level >= 2: return ("sealctl seal on \(name)", "Open sealctl to see what it takes over.")
        case .unseal where f.level >= 3: return ("Unseal everything on \(name)?", "Open sealctl to confirm. You'll need the number on its screen.")
        case .unseal: return ("Hand back from \(name)?", "Open sealctl to see what.")
        case .oldWords: return ("\(name) has an object sealed with old words.", "Open sealctl to move it.")
        case .unknown: return (title(f), "")
        case .agent:
            return (title(f), [f.repoName.map { "First use in \($0)" }, f.command.map(cut), name].compactMap { $0 }.joined(separator: " · "))
        case .own: return (title(f), [cmdIn.nonEmpty, name].compactMap { $0 }.joined(separator: " · "))
        case .keys: return (title(f), name)
        default: return (title(f), [cmdIn.nonEmpty, name, f.agent].compactMap { $0 }.joined(separator: " · "))
        }
    }

    /// "For" is cut in the middle after 80 characters.
    public static func cut(_ command: String) -> String {
        command.count <= 80 ? command : String(command.prefix(39)) + "…" + String(command.suffix(40))
    }

    /// The note under the facts (11.7 "By kind").
    public static func note(_ w: Waiting) -> String? {
        let ctx = w.request.ctx()
        let use = w.request.uses().first
        let agent = ctx?.agent ?? use?.agent
        let repo = ctx?.repo?.name ?? use.map { $0.repository.components(separatedBy: "/").last ?? $0.repository }
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
        let repo = w.request.ctx()?.repo?.name ?? u.map { $0.repository.components(separatedBy: "/").last ?? "" } ?? ""
        return "Remembered for \(u?.agent ?? w.request.ctx()?.agent ?? "the agent") in \(repo)"
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
    public static let away = "Away from your trusted places: this starts one hour after you confirm. Your phone and your computers can cancel it until then."
    public static let awayNoLocation = "This starts one hour after you confirm. Your phone and your computers can cancel it until then."
    public static func confirm(_ biometry: String = "Face ID") -> String { "Confirm with \(biometry)" }
    public static func leaving(_ name: String) -> String { "Leaving sealctl on \(name)" }
    public static func startsAt(_ at: Int64, now: Int64) -> String {
        let mins = (max(0, at - now) + 59_999) / 60_000
        return "Starts at \(time(at)) · \(mins) min left"
    }
    public static let delayBody = "You approved this away from your trusted places, so it waits an hour. Every paired computer has been told. If this wasn't you, cancel it."
    public static let cancelledHere = "Cancelled. Nothing was handed back."
    public static func cancelledFrom(_ name: String) -> String { "Cancelled from \(name)." }
    public static func handsBackAt(_ name: String, at: Int64) -> String { "\(name) hands everything back at \(time(at))." }
    /// The banner of a waiting level 3 action, by its kind.
    public static func delayedAt(_ what: String, name: String, at: Int64) -> String {
        switch what {
        case "words": return "Your words can be shown at \(time(at))."
        case "delete": return "Your relay data is deleted at \(time(at))."
        default: return handsBackAt(name, at: at)
        }
    }
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
    public static func relayError(_ code: String) -> String { "The relay refused this (\(code))." }
    public static func paired(_ name: String) -> String { "Paired. \(name) can now ask this phone for keys." }
    public static let offline = "Offline. Requests reach this phone when it is back online."
    public static let notificationsOff = "Notifications are off. Requests can't reach you while sealctl is closed."
    public static func rateLimited(_ until: Int64) -> String { "This phone has used its relay limit for today. It resets at \(time(until))." }
    public static let clock = "This phone's clock is more than 5 minutes off. Turn on automatic date and time."
    public static let signature = "The relay refused this phone's signature. Update the app."
    public static let fromLink = "Scan the code with sealctl. On a computer without a terminal, open the link in its browser to see the code."

    // MARK: pushes and notices (10.1, 10.4)

    public static let testPush = "Test from the relay. Requests reach this phone."
    public static let requestTitle = "Waiting for your phone"
    public static let requestBody = "A machine is asking for a key. Open to see the request."
    public static let delayedTitle = "Approved on your phone"
    public static let delayedBody = "Something sensitive was approved on your phone and starts in an hour. Open sealctl to see it or cancel it."
    public static let cancelledTitle = "Cancelled"
    public static let cancelledBody = "A pending sensitive action was cancelled."
    public static let placeLearned = "Trust this place? You opened your machines here on 3 mornings."
    public static func leftPlace(_ place: String, names: String) -> String { "You left \(place). Locked \(names)." }
    public static func ready(_ what: String) -> String {
        switch what {
        case "words": return "Ready: open sealctl to finish showing your words."
        case "delete": return "Ready: open sealctl to finish deleting your relay data."
        default: return "Ready: open sealctl to finish leaving."
        }
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

    /// "Open, 2 hours 10 minutes left" for VoiceOver.
    public static func spokenDuration(_ seconds: Int64) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .full
        return f.string(from: TimeInterval(max(seconds, 60))) ?? duration(seconds)
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
