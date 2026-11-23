import Foundation
import os
import Relay
import SealCore

/// A request on this phone waiting for an answer from the person.
public struct Waiting: Sendable, Identifiable {
    public let relay: RelayRequest
    public let request: Request
    public let verdict: Verdict
    public let machine: Machine
    public let seenAt: Int64
    public var expired: Bool
    public let plan: RequestPlan?

    public var id: String { relay.id }

    /// When this phone stops offering the request, on its own clock (SPEC.md 8.5).
    public var deadline: Int64 { Self.deadline(seenAt: seenAt, created: relay.created, expires: relay.expires) }

    /// The relay's `expires` is on the relay's clock. A phone clock ahead of it by less than the
    /// relay's 5-minute window raises no clock error, yet would close every request at once:
    /// the time between `created` and seeing the request is added, up to that window. A late
    /// answer gets `404 gone` from the relay, which decides.
    public static func deadline(seenAt: Int64, created: Int64, expires: Int64) -> Int64 {
        expires + min(max(0, seenAt - created), clockWindowMs)
    }

    /// The relay's signature time window (Relay API, Signing).
    public static let clockWindowMs: Int64 = 300_000

    /// The same request with `request` opened again from the relay's sealed text: a request
    /// is sealed once, so a reply that could not be posted is sealed again from this one.
    public func reopened(_ request: Request) -> Waiting {
        Waiting(relay: relay, request: request, verdict: verdict, machine: machine, seenAt: seenAt, expired: expired,
                plan: plan)
    }

    public init(relay: RelayRequest, request: Request, verdict: Verdict, machine: Machine, seenAt: Int64,
                expired: Bool = false, plan: RequestPlan? = nil) {
        self.relay = relay; self.request = request; self.verdict = verdict; self.machine = machine
        self.seenAt = seenAt; self.expired = expired; self.plan = plan
    }
}

/// Private logging (SPEC.md 2 rule 7): names, keys, paths and commands never go to the log
/// in readable form; only event kinds and error types.
public enum Log {
    static let logger = Logger(subsystem: "com.sealctl.app", category: "app")

    public static func note(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    public static func secret(_ label: String, _ value: String) {
        logger.debug("\(label, privacy: .public): \(value, privacy: .private)")
    }
}
