import Foundation
import Testing

#if os(macOS)
/// The helper that runs the fake machine and the CLI (`FakeMachine.Run`): every process's output
/// and exit reach the test, also when many start and end at once and their pipes' descriptor
/// numbers are reused. One stalled read must not hold up the others (all output handlers share
/// one Foundation queue), and a finished run must not read another run's pipe.
@Suite(.timeLimit(.minutes(2)))
struct ProcessRunTests {
    /// `/bin/sh -c script`, its output on a pipe like the fake machine's.
    func shell(_ script: String) throws -> FakeMachine.Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let run = FakeMachine.Run(process: p, out: out)
        try p.run()
        return run
    }

    @Test func shortProcessesInARow() async throws {
        for i in 0..<150 {
            let (code, out) = await FakeMachine.waitAsync(try shell("echo line-\(i); exit \(i % 7)"))
            #expect(code == Int32(i % 7))
            #expect(out == "line-\(i)\n", "run \(i)")
        }
    }

    @Test func shortProcessesAtOnce() async throws {
        try await withThrowingTaskGroup(of: (Int, Int32, String).self) { group in
            for i in 0..<120 {
                group.addTask {
                    let r = try shell("echo line-\(i); sleep 0.0\(i % 10); echo end-\(i); exit \(i % 5)")
                    let (code, out) = await FakeMachine.waitAsync(r)
                    return (i, code, out)
                }
            }
            for try await (i, code, out) in group {
                #expect(code == Int32(i % 5))
                #expect(out == "line-\(i)\nend-\(i)\n", "run \(i)")
            }
        }
    }

    /// A child that leaves a process of its own holding the output pipe (as `sealctl` leaves its
    /// daemon): the exit is reported without waiting for that pipe to close.
    @Test func exitWhileAnotherProcessHoldsThePipe() async throws {
        let r = try shell("echo first; (sleep 30) & exit 3")
        let start = Date()
        let (code, out) = await FakeMachine.waitAsync(r)
        #expect(code == 3)
        #expect(out == "first\n")
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
#endif
