import Foundation
import SealCore

/// A relay error answer or a transport failure (SPEC.md 8.1).
public enum RelayError: Error, Sendable, Equatable {
    /// An error body `{"error": code, ...}` with its HTTP status.
    case http(status: Int, code: String, body: JSON)
    /// `401 clock_skew` after the retry.
    case clockSkew
    /// `429 rate_limited`: no calls until `until` (Unix ms) except replies the user taps.
    case rateLimited(until: Int64, scope: String?)
    /// `409 conflict` on the state, with the stored revision.
    case conflict(rev: Int64)
    /// No answer: offline, timeout, TLS.
    case transport(String)
    /// This phone has no keys yet.
    case noKeys

    public var status: Int {
        switch self {
        case .http(let s, _, _): return s
        case .clockSkew: return 401
        case .rateLimited: return 429
        case .conflict: return 409
        case .transport, .noKeys: return 0
        }
    }

    public var code: String {
        switch self {
        case .http(_, let c, _): return c
        case .clockSkew: return "clock_skew"
        case .rateLimited: return "rate_limited"
        case .conflict: return "conflict"
        case .transport: return "transport"
        case .noKeys: return "no_keys"
        }
    }

    public var body: JSON {
        if case .http(_, _, let b) = self { return b }
        return .null
    }
}

public struct RelayRequest: Sendable, Equatable {
    public let id: String
    public let machine: String
    public let sealed: String
    public let created: Int64
    public let expires: Int64
    public let near: Bool

    public init(id: String, machine: String, sealed: String, created: Int64, expires: Int64, near: Bool) {
        self.id = id; self.machine = machine; self.sealed = sealed
        self.created = created; self.expires = expires; self.near = near
    }

    public init(json o: JSON) {
        self.init(id: o["id"].str, machine: o["machine"].str, sealed: o["sealed"].str,
                  created: o["created"].long, expires: o["expires"].long, near: o["near"].bool ?? false)
    }
}

public struct RelayMachine: Sendable, Equatable {
    public let machine: String
    public let name: String
    public let os: String?
    public let model: String?
    public let pairedAt: Int64
    public let lastSeen: Int64?
}

public struct RelayStatus: Sendable, Equatable {
    public let machine: String
    public let sealed: String
    public let updated: Int64
}

public struct RelayDelayed: Sendable, Equatable {
    public let id: String
    public let machine: String?
    public let created: Int64
    public let releaseAt: Int64
    public let expires: Int64
    public let state: String
    /// Who cancelled it (`phone` or a machine key) when `state` is `cancelled`.
    public var by: String? = nil
}

public struct RelayDevice: Sendable, Equatable {
    public let device: String
    public let platform: String
    public let sandbox: Bool
    public let updated: Int64
}

/// The Relay API client (SPEC.md 8): every call signed by the phone key with the core's
/// `relay_headers`, a clock offset corrected from `401 clock_skew`, the rate-limit window,
/// an ephemeral `URLSession` (no cache, no cookies) and a 10-second timeout.
public actor RelayClient {
    public nonisolated let baseURL: String
    public nonisolated let host: String
    private let keys: @Sendable () async -> PhoneKeys?
    private let now: @Sendable () -> Int64
    private let session: URLSession
    public private(set) var clockOffsetSecs: Int64 = 0
    public private(set) var rateLimitedUntil: Int64 = 0

    public init(baseURL: String, keys: @escaping @Sendable () async -> PhoneKeys?,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        self.baseURL = base
        self.host = base.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        self.keys = keys
        self.now = now
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
    }

    private func phoneKeys() async throws -> PhoneKeys {
        guard let k = await keys() else { throw RelayError.noKeys }
        return k
    }

    public func phoneId() async throws -> String { try await phoneKeys().publicId() }

    /// Milliseconds left in the rate-limit window (0 when calls may go out).
    public func rateLimitedForMs() -> Int64 { max(0, rateLimitedUntil - now()) }

    private func unixTime() -> Int64 { now() / 1000 + clockOffsetSecs }

    private func phone() async throws -> String { "/v1/phones/\(try await phoneId())" }

    /// One signed call. Throws `RelayError`.
    @discardableResult
    public func call(_ method: String, _ path: String, body: JSON? = nil, userTapped: Bool = false) async throws -> JSON {
        if !userTapped && now() < rateLimitedUntil {
            throw RelayError.rateLimited(until: rateLimitedUntil, scope: nil)
        }
        var (status, json) = try await execute(method, path, body)
        if status == 401 && json["error"].str == "clock_skew" {
            if let t = json["time"].int64 { clockOffsetSecs = t - now() / 1000 }
            (status, json) = try await execute(method, path, body)
            if status == 401 && json["error"].str == "clock_skew" { throw RelayError.clockSkew }
        }
        if (200..<300).contains(status) { return json }
        if status == 429 {
            let retry = json["retryAfter"].int64 ?? 60
            rateLimitedUntil = now() + retry * 1000
            throw RelayError.rateLimited(until: rateLimitedUntil, scope: json["scope"].string)
        }
        if status == 409 && json["error"].str == "conflict" {
            throw RelayError.conflict(rev: json["rev"].long)
        }
        throw RelayError.http(status: status, code: json["error"].str, body: json)
    }

    private func execute(_ method: String, _ path: String, _ body: JSON?) async throws -> (Int, JSON) {
        let bytes = body?.data() ?? Data()
        let h = relayHeaders(keys: try await phoneKeys(), method: method, pathAndQuery: path,
                             unixTime: UInt64(max(0, unixTime())), body: bytes)
        guard let url = URL(string: baseURL + path) else { throw RelayError.transport("bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(h.key, forHTTPHeaderField: "Sealctl-Key")
        req.setValue(h.time, forHTTPHeaderField: "Sealctl-Time")
        req.setValue(h.signature, forHTTPHeaderField: "Sealctl-Signature")
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bytes
        } else if method != "GET" && method != "DELETE" {
            req.httpBody = Data()
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw RelayError.transport(String(describing: type(of: error)))
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSON(data: data)) ?? (code < 300 ? .object([:]) : ["error": .string("http_\(code)")])
        return (code, json)
    }

    // MARK: typed calls (SPEC.md 8.2)

    public func health() async throws -> JSON {
        guard let url = URL(string: baseURL + "/v1/health") else { throw RelayError.transport("bad url") }
        do {
            let (data, _) = try await session.data(from: url)
            return try JSON(data: data)
        } catch {
            throw RelayError.transport(String(describing: type(of: error)))
        }
    }

    @discardableResult
    public func addMachine(machine: String, name: String, os: String, model: String?, proof: String) async throws -> JSON {
        var o: [String: JSON] = ["machine": .string(machine), "name": .string(name), "os": .string(os), "proof": .string(proof)]
        if let model { o["model"] = .string(model) }
        return try await call("POST", "\(try await phone())/machines", body: .object(o), userTapped: true)
    }

    public func machines() async throws -> [RelayMachine] {
        try await call("GET", "\(try await phone())/machines")["machines"].array.map {
            RelayMachine(machine: $0["machine"].str, name: $0["name"].str, os: $0["os"].string, model: $0["model"].string,
                         pairedAt: $0["pairedAt"].long, lastSeen: $0["lastSeen"].int64)
        }
    }

    public func removeMachine(_ machine: String) async throws {
        do {
            try await call("DELETE", "\(try await phone())/machines/\(machine)", userTapped: true)
        } catch let e as RelayError where e.code == "not_paired" {
            return
        }
    }

    public func requests() async throws -> [RelayRequest] {
        try await call("GET", "\(try await phone())/requests")["requests"].array.map(RelayRequest.init(json:))
    }

    /// Posts a reply; `delay` for a level 3 approval away from a trusted place.
    @discardableResult
    public func reply(id: String, sealed: String, delay: Int? = nil, userTapped: Bool = true) async throws -> JSON {
        var o: [String: JSON] = ["sealed": .string(sealed)]
        if let delay { o["delay"] = .number(Double(delay)) }
        return try await call("POST", "\(try await phone())/requests/\(id)/reply", body: .object(o), userTapped: userTapped)
    }

    /// `(rev, blob)`; the blob is nil before the first upload.
    public func getState() async throws -> (rev: Int64, blob: String?) {
        let o = try await call("GET", "\(try await phone())/state")
        return (o["rev"].long, o["blob"].string)
    }

    public func putState(rev: Int64, blob: String?) async throws -> Int64 {
        let o: JSON = ["rev": .number(Double(rev)), "blob": blob.map { .string($0) } ?? .null]
        return try await call("PUT", "\(try await phone())/state", body: o)["rev"].long
    }

    /// Registers this install's push device: `apns` with the hex token (`sandbox` for
    /// development builds) or `fcm`.
    @discardableResult
    public func putPush(device: String, platform: String, token: String, sandbox: Bool) async throws -> Int {
        var o: [String: JSON] = ["platform": .string(platform), "token": .string(token)]
        if sandbox { o["sandbox"] = .bool(true) }
        return Int(try await call("PUT", "\(try await phone())/push/\(device)", body: .object(o))["devices"].long)
    }

    public func listPush() async throws -> [RelayDevice] {
        try await call("GET", "\(try await phone())/push")["devices"].array.map {
            RelayDevice(device: $0["device"].str, platform: $0["platform"].str, sandbox: $0["sandbox"].bool ?? false,
                        updated: $0["updated"].long)
        }
    }

    public func deletePush(_ device: String) async throws {
        do {
            try await call("DELETE", "\(try await phone())/push/\(device)", userTapped: true)
        } catch let e as RelayError where e.code == "unknown_device" {
            return
        }
    }

    @discardableResult
    public func testPush(_ device: String) async throws -> JSON {
        try await call("POST", "\(try await phone())/push/\(device)/test", userTapped: true)
    }

    @discardableResult
    public func deletePhone() async throws -> JSON {
        try await call("DELETE", try await phone(), userTapped: true)
    }

    public func status() async throws -> [RelayStatus] {
        try await call("GET", "\(try await phone())/status")["status"].array.map {
            RelayStatus(machine: $0["machine"].str, sealed: $0["sealed"].str, updated: $0["updated"].long)
        }
    }

    /// `delivered: false` means the relay holds it for up to 24 hours.
    @discardableResult
    public func postMessage(machine: String, sealed: String) async throws -> Bool {
        try await call("POST", "\(try await phone())/machines/\(machine)/messages", body: ["sealed": .string(sealed)],
                       userTapped: true)["delivered"].bool ?? false
    }

    public func addDelayed(id: String, delay: Int) async throws -> RelayDelayed {
        let o = try await call("POST", "\(try await phone())/delayed",
                               body: ["id": .string(id), "delay": .number(Double(delay))], userTapped: true)
        return RelayDelayed(id: o["id"].string ?? id, machine: nil, created: now(), releaseAt: o["releaseAt"].long,
                            expires: o["expires"].long, state: "waiting")
    }

    public func listDelayed() async throws -> [RelayDelayed] {
        try await call("GET", "\(try await phone())/delayed")["delayed"].array.map {
            RelayDelayed(id: $0["id"].str, machine: $0["machine"].string, created: $0["created"].long,
                         releaseAt: $0["releaseAt"].long, expires: $0["expires"].long, state: $0["state"].str,
                         by: $0["by"].string)
        }
    }

    /// Who cancelled a record (`by`), or nil.
    public func cancelledBy(_ id: String) async -> String? {
        guard let o = try? await call("GET", "\(try await phone())/delayed/\(id)") else { return nil }
        return o["by"].string
    }

    public func cancelDelayed(_ id: String) async throws {
        try await call("POST", "\(try await phone())/delayed/\(id)/cancel", userTapped: true)
    }

    @discardableResult
    public func finishDelayed(_ id: String) async throws -> JSON {
        try await call("POST", "\(try await phone())/delayed/\(id)/finish", userTapped: true)
    }

    /// A signed upgrade request for the phone socket (foreground only, SPEC.md 8.3).
    public func socketRequest() async throws -> URLRequest {
        let path = "\(try await phone())/socket"
        let h = relayHeaders(keys: try await phoneKeys(), method: "GET", pathAndQuery: path,
                             unixTime: UInt64(max(0, unixTime())), body: Data())
        let ws = baseURL.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
        guard let url = URL(string: ws + path) else { throw RelayError.transport("bad url") }
        var req = URLRequest(url: url)
        req.setValue(h.key, forHTTPHeaderField: "Sealctl-Key")
        req.setValue(h.time, forHTTPHeaderField: "Sealctl-Time")
        req.setValue(h.signature, forHTTPHeaderField: "Sealctl-Signature")
        return req
    }

    public nonisolated func webSocket(_ request: URLRequest) -> URLSessionWebSocketTask {
        session.webSocketTask(with: request)
    }
}
