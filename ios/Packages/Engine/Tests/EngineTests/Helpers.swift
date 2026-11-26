import Foundation
import Testing
import EngineKit
import Places
import SealCore
import UserNotifications
import Vault
@testable import Engine

let testRelay = ProcessInfo.processInfo.environment["SEALCTL_TEST_RELAY"]
let machineBin = ProcessInfo.processInfo.environment["FAKE_MACHINE_BIN"]
/// The real sealctl CLI, run in a temporary HOME like sealctl's scripts/pair-test.sh.
let cliBin = ProcessInfo.processInfo.environment["SEALCTL_BIN"]
/// `tools/fake-relay`, which the timing tests start on a loopback port of their own.
let relayBin = ProcessInfo.processInfo.environment["FAKE_RELAY_BIN"]

/// Records notifications instead of showing them.
@MainActor
final class RecordingNotifier: Notifier {
    var posted: [(String, String)] = []
    /// The body of each post, in the same order.
    var bodies: [String] = []
    var removed: [String] = []
    var badge = 0
    /// When each scheduled post is due, by id (nil: at once).
    var due: [String: Date] = [:]

    func post(id: String, content: UNNotificationContent, at: Date?) {
        posted.append((id, content.title))
        bodies.append(content.body)
        due[id] = at
    }
    func remove(ids: [String]) { removed += ids }
    func removeStale(now: Int64, answered: Set<String>) {}
    func allowed() -> Bool { true }
    func setBadge(_ n: Int) { badge = n }
    func titles() -> [String] { posted.map(\.1) }
}

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("sealctl-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// Places with location allowed and no monitoring: tests set `currentPlace` themselves.
@MainActor
final class StubPlaces: PlacesProvider {
    var hasForeground = true
    var hasAlways = true
    var undetermined = false
    func requestWhenInUse() async {}
    func requestAlways() async {}
    func monitor(_ fences: [Fence], onTransition: @escaping @Sendable ([String], Bool?) async -> Void) async {}
    func sample() async -> Fix? { nil }
}

@MainActor
func makeEngine(testDelay: Int = 2, vault: MemoryVault = MemoryVault(), relayURL: String? = nil,
                places: PlacesProvider? = nil,
                callResourceTimeout: TimeInterval? = nil) async throws -> (AppEngine, MemoryVault, RecordingNotifier) {
    let dir = tempDir()
    let db = try Database(path: dir.appendingPathComponent("sealctl.db").path)
    let notifier = RecordingNotifier()
    let url = relayURL ?? testRelay ?? "http://127.0.0.1:8787"
    var config = EngineConfig(relayURL: url, testDelaySecs: testDelay)
    if let callResourceTimeout { config.callResourceTimeout = callResourceTimeout }
    let engine = await AppEngine(vault: vault, db: db, config: config,
                                 files: SharedFiles(root: dir.appendingPathComponent("shared")), notifier: notifier, places: places)
    return (engine, vault, notifier)
}

/// Onboarding to `Ready` without the screens: words made, card checked, steps done.
@MainActor
func onboard(_ engine: AppEngine) async throws {
    #expect(await engine.words.create() == .passed)
    await engine.words.cardChecked()
    await engine.applyLocal(.setOnboardingStep(step: 0))
    await engine.computePhase()
}

#if os(macOS)
/// A `tools/fake-machine` process with its own home.
final class FakeMachine: @unchecked Sendable {
    let home = tempDir()
    /// The relay it talks to: the shared test relay, or a test's own `LocalRelay`.
    let relay: String?

    init(relay: String? = testRelay) { self.relay = relay }

    /// A started process: its output as it comes, and its exit.
    ///
    /// The output is read in the pipe's `readabilityHandler`, which Foundation runs on one serial
    /// queue for every file handle in the process: a read there that blocks holds up the output
    /// of every other process. The pipe is non-blocking, so a handler called with nothing to read
    /// returns at once; at the end of the output the handler is removed before the pipe closes,
    /// so a later pipe that gets the same descriptor number never wakes this one. The exit comes
    /// from `terminationHandler` (set before the process runs), never from a thread blocked in
    /// `waitUntilExit`.
    final class Run: @unchecked Sendable {
        let process: Process
        /// Kept open while the process runs: under `script`, an early end of input reads as ^D.
        var input: FileHandle?
        private let lock = NSLock()
        private var buffer = Data()
        private var status: Int32?
        private var outputEnded = false
        private var exitWaiters: [CheckedContinuation<Void, Never>] = []

        init(process: Process, out: Pipe) {
            self.process = process
            let reader = out.fileHandleForReading
            let fd = reader.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            reader.readabilityHandler = { [weak self] h in
                let (data, end) = Run.drain(h.fileDescriptor)
                if end {
                    h.readabilityHandler = nil
                    try? h.close()
                }
                guard let self else { return }
                self.lock.withLock {
                    self.buffer.append(data)
                    if end { self.outputEnded = true }
                }
            }
            process.terminationHandler = { [weak self] p in
                guard let self else { return }
                let waiters = self.lock.withLock {
                    self.status = p.terminationStatus
                    defer { self.exitWaiters = [] }
                    return self.exitWaiters
                }
                waiters.forEach { $0.resume() }
            }
        }

        /// Everything readable now from a non-blocking descriptor, and whether the output ended
        /// (end of file, or an error other than "nothing yet").
        private static func drain(_ fd: Int32) -> (Data, Bool) {
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 16_384)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n > 0 { data.append(chunk, count: n); continue }
                if n == 0 { return (data, true) }
                if errno == EINTR { continue }
                return (data, errno != EAGAIN && errno != EWOULDBLOCK)
            }
        }

        var output: String { lock.withLock { String(decoding: buffer, as: UTF8.self) } }

        /// Not exited yet (as `terminationHandler` reported it).
        var isRunning: Bool { lock.withLock { status == nil } }

        private var exitStatus: Int32? { lock.withLock { status } }
        private var ended: Bool { lock.withLock { outputEnded } }

        /// Waits for the exit on this thread, keeping its run loop turning (as `waitUntilExit`
        /// did), then up to 0.5 s for the rest of the output: a process the child left running
        /// (the CLI's daemon) may hold the pipe open.
        func wait() -> (Int32, String) {
            while exitStatus == nil {
                if !RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            try? input?.close()
            let end = Date().addingTimeInterval(0.5)
            while !ended && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
            return (exitStatus ?? -1, output)
        }

        /// `wait()` without holding a thread.
        func finished() async -> (Int32, String) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let done = lock.withLock {
                    if status != nil { return true }
                    exitWaiters.append(c)
                    return false
                }
                if done { c.resume() }
            }
            try? input?.close()
            for _ in 0..<50 where !ended { try? await Task.sleep(for: .milliseconds(10)) }
            return (exitStatus ?? -1, output)
        }

        /// The first match of a regular expression's group 1 in the output, waiting for it.
        func find(_ pattern: String, timeout: Double = 30) async throws -> String {
            let re = try NSRegularExpression(pattern: pattern)
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                let out = output
                if let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
                   let r = Range(m.range(at: 1), in: out) { return String(out[r]) }
                if !isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw CancellationError()
        }

        /// The number the machine shows for the number match.
        func number() async throws -> UInt32 {
            for _ in 0..<100 {
                if let line = output.split(separator: "\n").first(where: { $0.hasPrefix("NUMBER ") }),
                   let n = UInt32(line.dropFirst(7)) { return n }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw CancellationError()
        }
    }

    func start(_ args: [String]) throws -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: machineBin!)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["FAKE_MACHINE_HOME"] = home.path
        env["SEALCTL_RELAY"] = relay!
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let run = Run(process: p, out: out)
        try p.run()
        return run
    }

    func run(_ args: [String]) throws -> (Int32, String) { try start(args).wait() }

    /// The run's exit status and output, without holding a thread.
    static func waitAsync(_ r: Run) async -> (Int32, String) { await r.finished() }

    func waitAsync(_ r: Run) async -> (Int32, String) { await r.finished() }
}

/// A `tools/fake-relay` of one test's own, on a free loopback port: never a shared or remote
/// relay. Its `/test/` routes set its clock and make calls fail.
final class LocalRelay: @unchecked Sendable {
    let process = Process()
    let url: String

    init() throws {
        let port = Int.random(in: 20_000..<40_000)
        url = "http://127.0.0.1:\(port)"
        process.executableURL = URL(fileURLWithPath: relayBin!)
        process.arguments = ["--bind", "127.0.0.1:\(port)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Test calls to a local relay: a relay that does not answer fails them in seconds, not
    /// after URLSession's default minute.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        c.timeoutIntervalForResource = 5
        return URLSession(configuration: c)
    }()

    /// Started and answering `/v1/health`, within 5 seconds.
    static func start() async throws -> LocalRelay {
        let r = try LocalRelay()
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if let (_, resp) = try? await session.data(from: URL(string: r.url + "/v1/health")!),
               (resp as? HTTPURLResponse)?.statusCode == 200 { return r }
            try await Task.sleep(for: .milliseconds(50))
        }
        r.stop()
        throw CancellationError()
    }

    /// A `/test/` control call.
    @discardableResult
    func control(_ path: String, _ body: String) async throws -> String {
        var req = URLRequest(url: URL(string: url + path)!)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        return String(decoding: try await Self.session.data(for: req).0, as: UTF8.self)
    }

    /// Waits until `count` calls held by `/test/hold` on `path` have taken effect and wait for
    /// their answer, within 5 seconds; false if they do not.
    func untilHeld(_ path: String, count: Int = 1) async throws -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            // The relay answers within a second, as soon as a call is held.
            let out = try await control("/test/held", #"{"path": "\#(path)"}"#)
            if let n = (try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])?["held"] as? Int, n >= count {
                return true
            }
            // Some are held already: the relay answers at once, so look again shortly.
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Waits until the relay holds `n` phone sockets open, within 5 seconds; false if it never does.
    func untilPhoneSockets(_ n: Int) async throws -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            let (data, _) = try await Self.session.data(from: URL(string: url + "/test/sockets")!)
            if (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["phoneSockets"] as? Int == n { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}

/// The real `sealctl` in a temporary HOME (never the user's): no services, no agent, no SSH
/// agent, as sealctl's scripts/pair-test.sh runs it.
final class CLIMachine: @unchecked Sendable {
    let home: URL = {
        let u = URL(fileURLWithPath: "/tmp").appendingPathComponent("sealctl-cli-\(UUID().uuidString.prefix(8))/home")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return u
    }()

    /// `tty`: under a pseudo-terminal (`script`), for commands that need a person at a terminal.
    func start(_ args: [String], stdin: String? = nil, env extra: [String: String] = [:], tty: Bool = false) throws -> FakeMachine.Run {
        precondition(!home.path.hasPrefix(NSHomeDirectory()), "the CLI never runs in the user's HOME")
        let p = Process()
        if tty {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            p.arguments = ["-q", "/dev/null", cliBin!] + args
        } else {
            p.executableURL = URL(fileURLWithPath: cliBin!)
            p.arguments = args
        }
        p.currentDirectoryURL = home
        var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path, "SEALCTL_RELAY": testRelay!,
                                     "SEALCTL_NO_SERVICE": "1", "SEALCTL_AGENT": "0", "LANG": "en_US.UTF-8"]
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let input = Pipe()
        p.standardInput = input
        let run = FakeMachine.Run(process: p, out: out)
        try p.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        if tty { run.input = input.fileHandleForWriting } else { try? input.fileHandleForWriting.close() }
        return run
    }

    func cleanup() {
        _ = try? start(["daemon", "--stop"]).wait()
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }
}
#endif
