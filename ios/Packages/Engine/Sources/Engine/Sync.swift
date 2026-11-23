import Foundation
import EngineKit
import Relay
import SealCore
import UserNotifications

extension AppEngine {
    // MARK: sync (6.5)

    public func scheduleUpload(after seconds: Double) {
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            if Task.isCancelled { return }
            _ = await self?.upload()
        }
    }

    @discardableResult
    public func upload() async -> Bool {
        guard state.settings.relayBackup else { return false }
        switch phase {
        case .ready, .onboarding: break
        default: return false
        }
        for _ in 0..<3 {
            // Turned off while this upload waited on a conflict: the blob is being cleared.
            guard state.settings.relayBackup else { return false }
            guard let plain = try? await db.run({ try $0.stateForUpload() }),
                  let blob = await withRoot({ try stateSeal(root: $0, plaintext: plain) }) else { return false }
            do {
                let rev = try await relay.putState(rev: Int64(local.stateRev), blob: blob)
                await applyLocal(.synced(rev: UInt64(clamping: rev), uploaded: true))
                relayOk()
                return true
            } catch RelayError.conflict {
                // Merge and try again here: rescheduling would cancel this upload's own task.
                if !(await download(rescheduleUpload: false)) { return false }
            } catch {
                relayFailed(error)
                return false
            }
        }
        return false
    }

    /// Downloads and merges the relay state.
    @discardableResult
    public func download(rescheduleUpload: Bool = true) async -> Bool {
        guard await phoneKeys() != nil else { return false }
        do {
            let (rev, blob) = try await relay.getState()
            if let blob {
                guard let remote = await withRoot({ try decodeState(bytes: stateOpen(root: $0, blob: blob)) }) else { return false }
                await apply(.mergeRemote(remote: remote), rescheduleUpload: rescheduleUpload)
            }
            await applyLocal(.synced(rev: UInt64(clamping: rev), uploaded: false))
            return true
        } catch {
            relayFailed(error)
            return false
        }
    }

    /// Off also replaces the blob on the relay with an empty state (6.5). When the relay could
    /// not be cleared the backup stays on, as it still is, and the person is told.
    @discardableResult
    public func setRelayBackup(_ on: Bool) async -> Bool {
        var s = state.settings
        s.relayBackup = on
        await apply(.setSettings(settings: s), upload: on)
        guard !on else { return true }
        uploadTask?.cancel()
        if await clearRelayState() { return true }
        s.relayBackup = true
        await apply(.setSettings(settings: s))
        show(Texts.relayBackupKept)
        return false
    }

    /// `PUT` of a sealed empty state over the stored blob; nothing to do when there is none.
    func clearRelayState() async -> Bool {
        guard await phoneKeys() != nil,
              let empty = await withRoot({ try stateSeal(root: $0, plaintext: encodeState(state: Self.emptyState)) }) else {
            return false
        }
        do {
            let stored = try await relay.getState()
            guard stored.blob != nil else { return true }
            var rev = stored.rev
            for _ in 0..<3 {
                do {
                    rev = try await relay.putState(rev: rev, blob: empty)
                    await applyLocal(.synced(rev: UInt64(clamping: rev), uploaded: true))
                    relayOk()
                    return true
                } catch RelayError.conflict(let current) {
                    rev = current
                }
            }
        } catch {
            relayFailed(error)
        }
        return false
    }

    public func setKeychainBackup(_ on: Bool) async -> Bool {
        var s = state.settings
        s.keychainBackup = on
        await apply(.setSettings(settings: s))
        if !on {
            await vault.deleteSyncBackup()
            return true
        }
        return true
    }

    // MARK: push (8.2, 10.1)

    public func deviceId() async -> String {
        let d = local.device
        if !d.deviceId.isEmpty { return d.deviceId }
        let id = randomId()
        await applyLocal(.setDevice(device: DeviceInfo(deviceId: id, token: nil, platform: "apns", sandbox: config.sandboxPush, registered: 0)))
        return id
    }

    /// Registers this install's APNs token (hex) with the relay. Not once Leave sealctl has
    /// reached its deletion step: that would put this phone back on the relay (11.22).
    public func registerPush(token: String? = nil) async {
        guard local.leaveStep < 5, await phoneKeys() != nil, let t = token ?? local.device.token else { return }
        let id = await deviceId()
        do {
            try await relay.putPush(device: id, platform: "apns", token: t, sandbox: config.sandboxPush)
            await applyLocal(.setDevice(device: DeviceInfo(deviceId: id, token: t, platform: "apns", sandbox: config.sandboxPush,
                                                           registered: UInt64(nowMs()))))
        } catch {
            relayFailed(error)
        }
    }

    /// "Send a test request" (10.4): nil when the relay sent it, else the text to show.
    public func testPush() async -> String? {
        let id = await deviceId()
        do {
            try await relay.testPush(id)
            return nil
        } catch let e as RelayError {
            switch e.code {
            case "push_failed" where e.body["removed"].bool == true:
                return "This phone's notification address was out of date. It has been renewed. Try again."
            case "push_failed": return "The push service refused the test (\(e.body["reason"].str))."
            case "push_not_configured": return "The relay can't send notifications right now."
            case "unknown_device":
                await registerPush()
                return "This phone was registered again. Try again."
            default: return e.status == 0 ? Texts.relayDown : Texts.relayError(e.code)
            }
        } catch {
            return Texts.relayDown
        }
    }

    /// A push reached the app (10.1): `request`, `test`, `delayed` or `cancelled`.
    public func onPush(type: String, id: String?) async {
        switch type {
        case "request": await catchUp(fromPush: true)
        case "test": await notifier.post(id: "test", content: Notes.active(Texts.testPush))
        case "delayed":
            await refreshDelayed()
        case "cancelled":
            await refreshDelayed()
        default: break
        }
    }

    // MARK: delete relay data and erase (11.19)

    /// Notices, locks, then `DELETE /v1/phones/{phone}`. Returns the text to show.
    public func deleteRelayData(lockFirst: Bool) async -> (ok: Bool, text: String) {
        await sendNotice(what: "delete", state: "done", machine: nil, delayId: nil, at: nil)
        if lockFirst {
            for m in liveMachines where MachineView.of(m, self).state == .open { await lock(m) }
        }
        do {
            try await relay.deletePhone()
            await apply(.forgetMachines)
            var s = state.settings
            s.relayBackup = false
            await apply(.setSettings(settings: s))
            return (true, "Deleted. The relay has nothing for these words.")
        } catch {
            relayFailed(error)
            return (false, "The relay isn't answering. Try again.")
        }
    }

    /// Erase (11.19): this install's push device, the keychain items, the database and the
    /// snapshot; back to Welcome.
    public func erase(alsoBackup: Bool) async {
        if await phoneKeys() != nil { try? await relay.deletePush(await deviceId()) }
        if alsoBackup { await vault.deleteSyncBackup() }
        await onBackground()
        await vault.erase()
        forgetPhoneKeys()
        _ = try? await db.run { try $0.erase() }
        files.removeAll()
        waiting = []
        await notifier.remove(ids: [])
        await computePhase()
    }

    // MARK: Leave sealctl (11.22)

    public func setLeave(step: Int, skipped: [String]) async {
        await applyLocal(.setLeave(step: UInt32(step), skipped: skipped))
    }

    /// Step 5: unpair the skipped machines, delete the relay data and the words backup.
    public func leaveDeleteEverything() async -> Bool {
        for k in local.leaveSkipped { try? await relay.removeMachine(k) }
        let r = await deleteRelayData(lockFirst: false)
        guard r.ok else { return false }
        await vault.deleteSyncBackup()
        var items = [ReportItem(kind: "relay", name: "Relay data", to: "deleted", state: "done"),
                     ReportItem(kind: "backup", name: "Words backup", to: "removed", state: "done")]
        for k in local.leaveSkipped {
            items.append(ReportItem(kind: "computer", name: machine(k)?.name ?? String(k.prefix(8)), to: "skipped", state: "skipped"))
        }
        await apply(.addReport(report: HandbackReport(id: "leave-\(nowMs())", machine: "", machineName: "This phone", what: "leave",
                                                      planHash: "", items: items, run: "", time: UInt64(nowMs()), updated: 0)))
        return true
    }
}
