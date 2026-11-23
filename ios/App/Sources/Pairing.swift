@preconcurrency import AVFoundation
import DesignSystem
import Engine
import EngineKit
import SealCore
import SwiftUI
import UIKit
import Vault

private enum PairStep {
    case scan
    case type
    case confirm(PairingOffer)
    case duplicate(PairingOffer, Machine)
    case cardWords(PairingOffer, String?)
    /// Two card words before a new gate (9.6), then the prompt again.
    case gateCard(PairingOffer, String?, GateResult)
    case done(String)
}

/// Pairing (SPEC.md 11.5, 11.6): scan or type the code; confirm; biometrics; register.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let fromLink: Bool
    @SwiftUI.State private var step: PairStep = .scan
    @SwiftUI.State private var error: String?
    @SwiftUI.State private var busy = false

    var body: some View {
        let e = model.engine!
        switch step {
        case .scan:
            ScanView(fromLink: fromLink, error: error, onCode: { accept($0, e) }, onType: { error = nil; step = .type })
        case .type:
            TypeCodeView(error: error, onCode: { accept($0, e) }, onBack: { error = nil; step = .scan })
        case .confirm(let offer):
            Page(onBack: { router.pop() }) {
                Gap(24)
                TitleText("Pair this machine?")
                MonoText(shown(offer.name(), 0), style: .title3, weight: .semibold)
                detailLine(offer)
                BodyText("It will be able to ask this phone for keys. You still approve every request.")
            } bottom: {
                ErrorText(error)
                PrimaryButton("Pair", enabled: !busy) { confirm(offer, replaces: nil, e) }
                PlainButton("Cancel") { router.pop() }
            }
        case .duplicate(let offer, let existing):
            let sameHint = offer.hint() != nil && offer.hint() == existing.hint
            Page(onBack: { router.pop() }) {
                Gap(24)
                if sameHint {
                    TitleText("Already paired")
                    BodyText("\(shown(offer.name())) is already paired (same hardware, last seen \(Texts.ago(existing.lastSeen.map { Int64($0) }))). Replace it?", markdown: false)
                } else {
                    TitleText("Same machine?")
                    BodyText("Another machine is already called \(shown(offer.name())) (\(shown(existing.model ?? existing.os)), paired \(Texts.isoDate(Int64(existing.pairedAt)))). Same machine?", markdown: false)
                }
            } bottom: {
                ErrorText(error)
                if sameHint {
                    PrimaryButton("Replace", enabled: !busy) { confirm(offer, replaces: existing.key, e) }
                    SecondaryButton("Pair as new", enabled: !busy) { confirm(offer, replaces: nil, e) }
                } else {
                    PrimaryButton("Yes, replace it", enabled: !busy) { confirm(offer, replaces: existing.key, e) }
                    SecondaryButton("No, another machine", enabled: !busy) { confirm(offer, replaces: nil, e) }
                }
                PlainButton("Cancel") { router.pop() }
            }
        case .cardWords(let offer, let replaces):
            CardWordsView(positions: 2, groups: 2, title: "Use your card", body: nil, onPassed: {
                Task {
                    await e.vault.resetGate()
                    let ok = await register(offer, replaces, e)
                    if !ok {
                        // Back to the screen that asked, where the error shows.
                        if let k = replaces, let existing = e.machine(k) {
                            step = .duplicate(offer, existing)
                        } else {
                            step = .confirm(offer)
                        }
                    }
                }
            }, onCancel: { step = .confirm(offer) })
        case .gateCard(let offer, let replaces, let why):
            GateCardWordsView(why: why, onPassed: {
                back(offer, replaces, e)
                confirm(offer, replaces: replaces, e)
            }, onCancel: { back(offer, replaces, e) })
        case .done(let name):
            Page(onBack: nil) {
                Gap(24)
                TitleText(Texts.paired(name))
            } bottom: {
                PrimaryButton("Done") { router.pop() }
            }
        }
    }

    private func detailLine(_ offer: PairingOffer) -> some View {
        let parts = [offer.os().nonEmpty, offer.model()].compactMap { $0 }.map { shown($0) }
        return HStack(spacing: 0) {
            Text(parts.joined(separator: " · ") + (parts.isEmpty ? "" : " · ")).foregroundStyle(Palette.muted)
            MonoText("#\(offer.tag())", style: .subheadline, color: Palette.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private func accept(_ text: String, _ e: AppEngine) {
        switch e.parseOffer(text) {
        case .success(let offer):
            error = nil
            if let same = e.liveMachines.first(where: { $0.name == offer.name() && $0.key != offer.machineKey() }) {
                step = .duplicate(offer, same)
            } else {
                step = .confirm(offer)
            }
        case .failure(let err):
            error = err.text
        }
    }

    /// Level 2 (9.6): biometrics, or two card words without them.
    private func confirm(_ offer: PairingOffer, replaces: String?, _ e: AppEngine) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            if await e.vault.biometrics() != .available {
                step = .cardWords(offer, replaces)
                return
            }
            let result = await e.vault.gate(reason: "Confirm pairing \(shown(offer.name())).")
            switch result {
            case .passed: await register(offer, replaces, e)
            case .cancelled: break
            case .changed, .noGate: step = .gateCard(offer, replaces, result)
            case .lockedOut, .unavailable: step = .cardWords(offer, replaces)
            case .failed(let m): error = "Couldn't confirm (\(m))."
            }
        }
    }

    /// Back to the screen that asked.
    private func back(_ offer: PairingOffer, _ replaces: String?, _ e: AppEngine) {
        if let k = replaces, let existing = e.machine(k) {
            step = .duplicate(offer, existing)
        } else {
            step = .confirm(offer)
        }
    }

    @discardableResult
    private func register(_ offer: PairingOffer, _ replaces: String?, _ e: AppEngine) async -> Bool {
        switch await e.pair(offer, replaces: replaces) {
        case .success(let m):
            haptic(true)
            step = .done(e.displayName(m))
            return true
        case .failure(let err):
            error = err.text
            return false
        }
    }
}

/// The scanner: the camera fills a square guide; "Can't scan? Type the pairing code".
private struct ScanView: View {
    @Environment(Router.self) private var router
    let fromLink: Bool
    let error: String?
    let onCode: (String) -> Void
    let onType: () -> Void
    @SwiftUI.State private var status = AVCaptureDevice.authorizationStatus(for: .video)
    private let hasCamera = AVCaptureDevice.default(for: .video) != nil

    var body: some View {
        Page("Scan the code", onBack: { router.pop() }) {
            if fromLink { BodyText(Texts.fromLink) }
            BodyText("Run `sealctl pair` on your computer and point the camera at the code.")
            if !hasCamera {
                MutedText("This device has no camera.")
            } else if status == .authorized {
                CameraView(onCode: onCode)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.accent, lineWidth: 3))
                    .accessibilityLabel("Camera")
            } else if status == .denied || status == .restricted {
                BodyText("The camera is needed to scan the pairing code. Allow it in Settings.")
                PrimaryButton("Open settings") { Links.settings() }
            } else {
                MutedText("The camera scans the pairing code that sealctl pair shows on your computer.")
                PrimaryButton("Allow camera") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        status = AVCaptureDevice.authorizationStatus(for: .video)
                    }
                }
            }
        } bottom: {
            ErrorText(error)
            SecondaryButton("Can't scan? Type the pairing code", action: onType)
        }
    }
}

/// The code text that `sealctl pair` prints under the QR code (12, 19.1).
private struct TypeCodeView: View {
    let error: String?
    let onCode: (String) -> Void
    let onBack: () -> Void
    @SwiftUI.State private var text = ""

    var body: some View {
        Page("Type the pairing code", onBack: onBack) {
            BodyText("`sealctl pair` prints the code under the QR code. Type or paste it here.")
            TextField("Pairing code", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .font(Fonts.mono(.body))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border))
                .accessibilityIdentifier("Pairing code")
        } bottom: {
            ErrorText(error)
            PrimaryButton("Continue", enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                onCode(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

/// `AVCaptureMetadataOutput` with QR codes; nothing leaves the phone.
private struct CameraView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return v }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return v }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.session?.stopRunning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        let onCode: (String) -> Void
        var session: AVCaptureSession?
        var last: String?
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                                        from connection: AVCaptureConnection) {
            guard let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            MainActor.assumeIsolated {
                guard text != last else { return }
                last = text
                onCode(text)
            }
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
