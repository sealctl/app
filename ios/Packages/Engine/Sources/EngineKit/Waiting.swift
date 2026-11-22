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
