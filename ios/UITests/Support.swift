import Darwin
import notify
import XCTest

/// Where the tests find the relay and the harness (`ios/scripts/harness.py`). `xcodebuild`
/// passes `TEST_RUNNER_<NAME>` from its environment to the test runner as `<NAME>`.
enum Env {
    static let env = ProcessInfo.processInfo.environment
    static let relay = env["SEALCTL_RELAY"] ?? "http://127.0.0.1:8787"
    static let harness = env["SEALCTL_HARNESS"] ?? "http://127.0.0.1:8790"
    /// The shortened level 3 delay in debug builds, seconds.
    static let delay = Int(env["SEALCTL_TEST_DELAY"] ?? "") ?? 20
    /// The fake relay has `/test/` controls; the staging relay does not.
    static var fakeRelay: Bool { relay.hasPrefix("http://127.0.0.1") || relay.hasPrefix("http://localhost") }
    /// Test output never names a private relay: its host is replaced (logs are public).
    static func scrub(_ s: String) -> String {
        guard !fakeRelay, let host = URL(string: relay)?.host, !host.isEmpty else { return s }
        return s.replacingOccurrences(of: host, with: "<relay>")
    }

    /// The protocol's vector B words (docs/vectors): a known phone for restore tests.
    static let vectorWords = "bulk search gospel radio edit key flip afford jaguar rapid mechanic power family category snap boss iron web various grow smoke next example lounge"
        .split(separator: " ").map(String.init)
}

/// Small blocking HTTP calls to the harness and the fake relay's test controls.
enum HTTP {
    @discardableResult
    static func call(_ method: String, _ url: String, _ body: [String: Any]? = nil) -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.timeoutInterval = 30
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        URLSession.shared.dataTask(with: req) { data, _, _ in
            box.data = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 35)
        guard let data = box.data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return o
    }

    final class ResultBox: @unchecked Sendable { var data: Data? }
}

/// The harness: jobs on the Mac, the simulator's URL opening and pushes.
enum Harness {
    struct Job {
        let id: String

        var state: [String: Any] { HTTP.call("GET", "\(Env.harness)/job/\(id)") }
        var rawOutput: String { state["out"] as? String ?? "" }
        /// The output for messages, with a private relay's host replaced.
        var output: String { Env.scrub(rawOutput) }
        var done: Bool { state["done"] as? Bool ?? false }

        /// Waits for the job to end; its exit code and output.
        @discardableResult
        func wait(_ timeout: TimeInterval = 120) -> (Int, String) {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                let s = state
                if s["done"] as? Bool == true { return (s["code"] as? Int ?? -1, Env.scrub(s["out"] as? String ?? "")) }
                Thread.sleep(forTimeInterval: 0.5)
            }
            return (-1, output)
        }

        /// Waits for a line in the output and returns the first match of `pattern` (group 1).
        func find(_ pattern: String, timeout: TimeInterval = 60) -> String? {
            let re = try! NSRegularExpression(pattern: pattern)
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                let out = rawOutput
                if let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
                   let r = Range(m.range(at: m.numberOfRanges > 1 ? 1 : 0), in: out) {
                    return String(out[r])
                }
                if done { return nil }
                Thread.sleep(forTimeInterval: 0.5)
            }
            return nil
        }

        func stop() { HTTP.call("POST", "\(Env.harness)/stop/\(id)") }
    }

    static var hasCLI: Bool { HTTP.call("GET", "\(Env.harness)/health")["cli"] as? Bool ?? false }
    static var up: Bool { HTTP.call("GET", "\(Env.harness)/health")["ok"] as? Bool ?? false }

    static func machine(_ home: String, _ args: [String], stdin: String? = nil) -> Job {
        var spec: [String: Any] = ["cmd": "machine", "home": home, "args": args]
        if let stdin { spec["stdin"] = stdin }
        return Job(id: HTTP.call("POST", "\(Env.harness)/job", spec)["id"] as? String ?? "")
    }

    static func cli(_ home: String, _ args: [String], stdin: String? = nil, env: [String: String] = [:], tty: Bool = false) -> Job {
        var spec: [String: Any] = ["cmd": "cli", "home": home, "args": args, "env": env, "tty": tty]
        if let stdin { spec["stdin"] = stdin }
        return Job(id: HTTP.call("POST", "\(Env.harness)/job", spec)["id"] as? String ?? "")
    }

    static func openURL(_ url: String) { HTTP.call("POST", "\(Env.harness)/openurl", ["url": url]) }

    /// Pushes with `xcrun simctl push`, which the harness runs as a job: it can take more than a
    /// minute on a busy simulator, so the call returns at once and the job says when it ended.
    @discardableResult
    static func push(_ payload: [String: Any]) -> Job {
        Job(id: HTTP.call("POST", "\(Env.harness)/push", ["payload": payload])["id"] as? String ?? "")
    }

    static func reset() { HTTP.call("POST", "\(Env.harness)/reset") }
}

/// The fake relay's test controls (unsigned, loopback only).
enum FakeRelay {
    static func reset() { HTTP.call("POST", "\(Env.relay)/test/reset") }
    static func near(_ near: Bool?) { HTTP.call("POST", "\(Env.relay)/test/near", ["near": near.map { $0 as Any } ?? NSNull()]) }
    static func fail(_ body: [String: Any]) { HTTP.call("POST", "\(Env.relay)/test/fail", body) }
    static func clock(_ offset: Int) { HTTP.call("POST", "\(Env.relay)/test/clock", ["offset": offset]) }

    /// Waits until the relay holds `n` phone sockets open; false if it does not within `timeout`.
    static func untilPhoneSockets(_ n: Int, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if HTTP.call("GET", "\(Env.relay)/test/sockets")["phoneSockets"] as? Int == n { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < end
        return false
    }
}

/// Simulated biometrics through the simulator's own notifications (the test runner runs
/// inside the simulator, so `notify_post` reaches its BiometricKit). The app has no bypass.
enum Bio {
    static func enroll(_ on: Bool = true) {
        var token: Int32 = 0
        notify_register_check("com.apple.BiometricKit.enrollmentChanged", &token)
        notify_set_state(token, on ? 1 : 0)
        notify_post("com.apple.BiometricKit.enrollmentChanged")
    }

    static func match() {
        notify_post("com.apple.BiometricKit_Sim.pearl.match")
        notify_post("com.apple.BiometricKit_Sim.fingerTouch.match")
    }

    static func noMatch() {
        notify_post("com.apple.BiometricKit_Sim.pearl.nomatch")
        notify_post("com.apple.BiometricKit_Sim.fingerTouch.nomatch")
    }
}

/// The Face ID prompt as LocalAuthentication announces it to the whole simulator: coreauthd
/// posts `ui.presented` when it shows a prompt and `ui.dismissed` once when that prompt ends
/// (matched, cancelled or failed). Both are counted from the first use (`setUp`), so a prompt
/// a tap raised before a helper looks is still seen. A prompt is open while more were shown
/// than ended.
final class Prompts: @unchecked Sendable {
    static let shared = Prompts()

    private let lock = NSLock()
    private var shown = 0
    private var ended = 0

    private init() {
        let queue = DispatchQueue(label: "sealctl.uitests.prompts")
        for (name, isEnd) in [("com.apple.LocalAuthentication.ui.presented", false),
                              ("com.apple.LocalAuthentication.ui.dismissed", true)] {
            var token: Int32 = 0
            notify_register_dispatch(name, &token, queue) { [self] _ in
                lock.lock()
                if isEnd { ended += 1 } else { shown += 1 }
                lock.unlock()
            }
        }
    }

    var counts: (shown: Int, ended: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (shown, ended)
    }

    var open: Bool { let c = counts; return c.shown > c.ended }
}

/// The Face ID prompt's own buttons (in SpringBoard), after a face it didn't recognise.
enum PromptButtons {
    static let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    static var tryAgain: XCUIElement {
        springboard.buttons["com.apple.localauthentication.ax.authentication.button.try-again"].firstMatch
    }
    static var cancel: XCUIElement {
        springboard.buttons["com.apple.localauthentication.ax.authentication.button.cancel"].firstMatch
    }
}
