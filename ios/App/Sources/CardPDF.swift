import UIKit

/// The blank card (SPEC.md 11.3 step 3): 24 numbered lines with four boxes each, boxes for
/// the words fingerprint and the date. Blank: no words, no fingerprint, no date.
@MainActor
enum CardPDF {
    static func file(letter: Bool) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cards", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(letter ? "sealctl-card-letter.pdf" : "sealctl-card-a4.pdf")
        if !FileManager.default.fileExists(atPath: url.path) { try? data(letter: letter).write(to: url) }
        return url
    }

    static func data(letter: Bool) -> Data {
        let (w, h): (CGFloat, CGFloat) = letter ? (612, 792) : (595, 842)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: w, height: h))
        return renderer.pdfData { ctx in
            ctx.beginPage()
            let ink = UIColor(red: 0x1a / 255, green: 0x21 / 255, blue: 0x33 / 255, alpha: 1)
            let muted = UIColor(red: 0x6b / 255, green: 0x71 / 255, blue: 0x83 / 255, alpha: 1)
            let margin: CGFloat = 48
            func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ font: UIFont, _ color: UIColor = ink) {
                (s as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
            }
            let mono = UIFont.monospacedSystemFont(ofSize: 16, weight: .semibold)
            let small = UIFont.systemFont(ofSize: 9)
            let num = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            text("sealctl", margin, margin - 8, mono)
            text("Write each word in full: first four letters in the boxes, the whole word on the line.", margin, margin + 16, small, muted)
            text("Keep this card away from cameras. Anyone with it can open everything.", margin, margin + 28, small, muted)
            let cg = ctx.cgContext
            cg.setStrokeColor(ink.cgColor)
            cg.setLineWidth(0.8)
            let top = margin + 64
            let colW = (w - 2 * margin) / 2
            let rowH = (h - top - margin - 60) / 12
            for i in 0..<24 {
                let x = margin + CGFloat(i / 12) * colW
                let y = top + CGFloat(i % 12) * rowH
                text(String(format: "%2d", i + 1), x, y + 3, num)
                for b in 0..<4 { cg.stroke(CGRect(x: x + 20 + CGFloat(b) * 16, y: y + 2, width: 14, height: 16)) }
                cg.move(to: CGPoint(x: x + 90, y: y + 18))
                cg.addLine(to: CGPoint(x: x + colW - 16, y: y + 18))
                cg.strokePath()
            }
            let by = h - margin - 40
            text("Words fingerprint", margin, by - 10, small, muted)
            for b in 0..<4 { cg.stroke(CGRect(x: margin + 90 + CGFloat(b) * 16, y: by - 12, width: 14, height: 16)) }
            text("Written on", margin + colW, by - 10, small, muted)
            cg.move(to: CGPoint(x: margin + colW + 56, y: by + 4))
            cg.addLine(to: CGPoint(x: w - margin, y: by + 4))
            text("Retired on", margin, by + 16, small, muted)
            cg.move(to: CGPoint(x: margin + 56, y: by + 30))
            cg.addLine(to: CGPoint(x: margin + colW - 16, y: by + 30))
            cg.strokePath()
        }
    }

    static func print(letter: Bool) {
        let p = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .grayscale
        info.jobName = "sealctl card"
        p.printInfo = info
        p.printingItem = file(letter: letter)
        p.present(animated: true)
    }
}
