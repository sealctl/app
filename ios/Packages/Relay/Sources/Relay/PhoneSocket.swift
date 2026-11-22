import Foundation

/// The phone socket while the app is in the foreground (SPEC.md 8.3): `ping` every 30 s, a
/// dead socket after 10 s without `pong`, reconnect with backoff 1, 2, 4, 8, 16 then 30 s
/// (±20% jitter), at most 60 upgrades an hour. The first `pong` counts as connected.
public actor PhoneSocket {
    public typealias OnMessage = @Sendable (JSON) async -> Void
    public typealias OnState = @Sendable (Bool) async -> Void

    private let client: RelayClient
    private let onMessage: OnMessage
    private let onConnected: @Sendable () async -> Void
    private let onState: OnState
    private var loop: Task<Void, Never>?
    private var task: URLSessionWebSocketTask?
    private var lastPong: Date = .distantPast
    private var upgrades: [Date] = []
    public private(set) var isOpen = false

    public init(client: RelayClient, onMessage: @escaping OnMessage, onConnected: @escaping @Sendable () async -> Void,
                onState: @escaping OnState = { _ in }) {
        self.client = client
        self.onMessage = onMessage
        self.onConnected = onConnected
        self.onState = onState
    }

    public func start() {
        if let loop, !loop.isCancelled { return }
        loop = Task { await run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isOpen = false
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            let now = Date()
            upgrades.removeAll { now.timeIntervalSince($0) > 3600 }
            if upgrades.count >= 60 {
                try? await Task.sleep(for: .seconds(60))
                continue
            }
            upgrades.append(now)
            if await connectOnce() { attempt = 0 }
            if Task.isCancelled { break }
            let base = [1.0, 2, 4, 8, 16, 30][min(attempt, 5)]
            attempt += 1
            try? await Task.sleep(for: .seconds(base * Double.random(in: 0.8...1.2)))
        }
    }

    /// One connection until it drops. Returns whether it was ever open.
    private func connectOnce() async -> Bool {
        guard let request = try? await client.socketRequest() else { return false }
        let ws = client.webSocket(request)
        task = ws
        ws.resume()
        var opened = false
        let pinger = Task { [weak self] in await self?.keepAlive(ws) }
        defer { pinger.cancel() }
        do {
            try await ws.send(.string("ping"))
            while !Task.isCancelled {
                let message = try await ws.receive()
                guard case .string(let text) = message else { continue }
                if text == "pong" {
                    lastPong = Date()
                    if !opened {
                        opened = true
                        isOpen = true
                        await onState(true)
                        await onConnected()
                    }
                    continue
                }
                if let data = text.data(using: .utf8), let json = try? JSON(data: data) {
                    await onMessage(json)
                }
            }
        } catch {
            // Closed or failed: reconnect.
        }
        ws.cancel(with: .goingAway, reason: nil)
        if task === ws { task = nil }
        isOpen = false
        await onState(false)
        return opened
    }

    private func keepAlive(_ ws: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { return }
            let sent = Date()
            try? await ws.send(.string("ping"))
            try? await Task.sleep(for: .seconds(10))
            if lastPong < sent {
                ws.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }
}
