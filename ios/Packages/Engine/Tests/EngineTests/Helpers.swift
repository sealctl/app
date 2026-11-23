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

    func post(id: String, content: UNNotificationContent, at: Date?) {
        posted.append((id, content.title))
        bodies.append(content.body)
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
                places: PlacesProvider? = nil) async throws -> (AppEngine, MemoryVault, RecordingNotifier) {
    let dir = tempDir()
    let db = try Database(path: dir.appendingPathComponent("sealctl.db").path)
    let notifier = RecordingNotifier()
    let url = relayURL ?? testRelay ?? "http://127.0.0.1:8787"
    let engine = await AppEngine(vault: vault, db: db, config: EngineConfig(relayURL: url, testDelaySecs: testDelay),
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

    final class Run: @unchecked Sendable {
        let process: Process
        /// Kept open while the process runs: under `script`, an early end of input reads as ^D.
        var input: FileHandle?
        private let lock = NSLock()
        private var buffer = Data()

        init(process: Process, out: Pipe) {
            self.process = process
            out.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self, !d.isEmpty else { return }
                self.lock.withLock { self.buffer.append(d) }
            }
        }

        var output: String { lock.withLock { String(decoding: buffer, as: UTF8.self) } }

        func wait() -> (Int32, String) {
            process.waitUntilExit()
            try? input?.close()
            Thread.sleep(forTimeInterval: 0.1)
            return (process.terminationStatus, output)
        }

        /// The first match of a regular expression's group 1 in the output, waiting for it.
        func find(_ pattern: String, timeout: Double = 30) async throws -> String {
            let re = try NSRegularExpression(pattern: pattern)
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                let out = output
                if let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
                   let r = Range(m.range(at: 1), in: out) { return String(out[r]) }
                if !process.isRunning { break }
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

    func waitAsync(_ r: Run) async -> (Int32, String) {
        await withCheckedContinuation { c in
            DispatchQueue.global().async { c.resume(returning: r.wait()) }
        }
    }
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

    static func start() async throws -> LocalRelay {
        let r = try LocalRelay()
        for _ in 0..<100 {
            if let (_, resp) = try? await URLSession.shared.data(from: URL(string: r.url + "/v1/health")!),
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
        return String(decoding: try await URLSession.shared.data(for: req).0, as: UTF8.self)
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
