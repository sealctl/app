import CoreLocation
import Foundation

/// A trusted place to monitor.
public struct Fence: Sendable, Equatable {
    public let id: String
    public let lat: Double
    public let lon: Double
    public let radius: Double
    public init(id: String, lat: Double, lon: Double, radius: Double) {
        self.id = id; self.lat = lat; self.lon = lon; self.radius = radius
    }
}

/// One location fix.
public struct Fix: Sendable, Equatable {
    public let lat: Double
    public let lon: Double
    public let accuracy: Double
    public let time: Int64
}

/// Places on the iPhone (SPEC.md 10.3, 11.9): one `CLMonitor` named `places` with one circular
/// condition per place, and one fix at the first approval of the day, at most 10 seconds.
/// Locations never leave the phone.
@MainActor
public final class Places: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var monitor: CLMonitor?
    private var events: Task<Void, Never>?
    private var authWaiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var status: CLAuthorizationStatus
    /// The place the phone is inside, from the monitor's events.
    public private(set) var inside: Set<String> = []

    public override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    public var hasForeground: Bool {
        #if os(iOS)
        return status == .authorizedWhenInUse || status == .authorizedAlways
        #else
        return status == .authorizedAlways || status == .authorized
        #endif
    }

    public var hasAlways: Bool { status == .authorizedAlways }

    public var undetermined: Bool { status == .notDetermined }

    /// When In Use first (onboarding step 9).
    public func requestWhenInUse() async {
        guard status == .notDetermined else { return }
        await withCheckedContinuation { c in
            authWaiters.append(c)
            #if os(iOS)
            manager.requestWhenInUseAuthorization()
            #else
            manager.requestAlwaysAuthorization()
            #endif
        }
    }

    /// Always, after the first trusted place (11.9). The system shows its prompt for Always
    /// once; asked again, it shows nothing and the status does not change, so this returns at
    /// once instead of waiting for an answer that never comes.
    public func requestAlways() async {
        guard status != .authorizedAlways else { return }
        let asked = "places.askedAlways"
        guard !UserDefaults.standard.bool(forKey: asked) else { return }
        UserDefaults.standard.set(true, forKey: asked)
        await withCheckedContinuation { c in
            authWaiters.append(c)
            manager.requestAlwaysAuthorization()
            // "Keep Only While Using" may change nothing: stop waiting after a minute.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(60))
                self?.resumeWaiters()
            }
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            self.status = s
            if s != .notDetermined { self.resumeWaiters() }
        }
    }

    private func resumeWaiters() {
        let w = authWaiters
        authWaiters = []
        w.forEach { $0.resume() }
    }

    /// Replaces the monitored places. `onTransition(ids, entered)` runs for every crossing;
    /// `entered` is nil when the state is unknown or unmonitored, which is not an exit.
    ///
    /// At launch the monitor sends only what changed while the app was not running, so the
    /// places the phone is already inside come from the monitor's records first (the state the
    /// system keeps, as `requestState(for:)` gave it for region monitoring). The records count
    /// only with Always: with When In Use the system watches the edges only while the app is in
    /// use, and a record could be from before the phone left.
    public func monitor(_ fences: [Fence], onTransition: @escaping @Sendable ([String], Bool?) async -> Void) async {
        guard hasForeground else { return }
        let m: CLMonitor
        if let monitor { m = monitor } else {
            m = await CLMonitor("places")
            monitor = m
            if hasAlways {
                for id in await m.identifiers {
                    guard let r = await m.record(for: id), r.lastEvent.state == .satisfied else { continue }
                    inside.insert(id)
                    await onTransition([id], true)
                }
            }
            events = Task { @MainActor [weak self] in
                do {
                    for try await e in await m.events {
                        let entered: Bool? = switch e.state {
                        case .satisfied: true
                        case .unsatisfied: false
                        default: nil
                        }
                        if entered == true { self?.inside.insert(e.identifier) } else { self?.inside.remove(e.identifier) }
                        await onTransition([e.identifier], entered)
                    }
                } catch {}
            }
        }
        let wanted = Set(fences.map(\.id))
        for id in await m.identifiers where !wanted.contains(id) { await m.remove(id) }
        let have = Set(await m.identifiers)
        for f in fences where !have.contains(f.id) {
            let c = CLMonitor.CircularGeographicCondition(
                center: CLLocationCoordinate2D(latitude: f.lat, longitude: f.lon), radius: f.radius)
            await m.add(c, identifier: f.id, assuming: .unsatisfied)
        }
    }

    /// One fix within 10 seconds; better than 100 m when the phone can give it.
    public func sample() async -> Fix? {
        guard hasForeground else { return nil }
        return await withTaskGroup(of: Fix?.self) { group in
            group.addTask {
                var best: Fix?
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        guard let l = update.location else { continue }
                        let fix = Fix(lat: l.coordinate.latitude, lon: l.coordinate.longitude,
                                      accuracy: l.horizontalAccuracy, time: Int64(l.timestamp.timeIntervalSince1970 * 1000))
                        if best == nil || fix.accuracy < best!.accuracy { best = fix }
                        if fix.accuracy <= 100 { return fix }
                    }
                } catch {}
                return best
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
