import Foundation
import Testing
import EngineKit
import SealCore
import UserNotifications
import Vault
@testable import Engine

let testRelay = ProcessInfo.processInfo.environment["SEALCTL_TEST_RELAY"]
let machineBin = ProcessInfo.processInfo.environment["FAKE_MACHINE_BIN"]

/// Records notifications instead of showing them.
@MainActor
final class RecordingNotifier: Notifier {
    var posted: [(String, String)] = []
    var removed: [String] = []
    var badge = 0

    func post(id: String, content: UNNotificationContent, at: Date?) { posted.append((id, content.title)) }
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

@MainActor
func makeEngine(testDelay: Int = 2, vault: MemoryVault = MemoryVault()) async throws -> (AppEngine, MemoryVault, RecordingNotifier) {
    let dir = tempDir()
    let db = try Database(path: dir.appendingPathComponent("sealctl.db").path)
    let notifier = RecordingNotifier()
    let engine = await AppEngine(vault: vault, db: db, config: EngineConfig(relayURL: testRelay ?? "http://127.0.0.1:8787", testDelaySecs: testDelay),
                                 files: SharedFiles(root: dir.appendingPathComponent("shared")), notifier: notifier, places: nil)
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

    final class Run: @unchecked Sendable {
        let process: Process
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
            Thread.sleep(forTimeInterval: 0.1)
            return (process.terminationStatus, output)
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
        env["SEALCTL_RELAY"] = testRelay!
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
#endif
