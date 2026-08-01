import AppKit
import Foundation

// Exporta el guion marcado a PDF (papel: fondo blanco): títulos, guías en
// azul, viñetas, pausas visibles y cambios de velocidad anotados.
enum PDFExporter {

    static func export(title: String, body: String, guideTitles: Bool, to url: URL) throws {
        let chunks = ScriptParser.parse(body, guideTitles: guideTitles)
        let text = NSMutableAttributedString()

        func append(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular,
                    color: NSColor = .black, italic: Bool = false) {
            var font = NSFont.systemFont(ofSize: size, weight: weight)
            if italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = size * 0.45
            text.append(NSAttributedString(string: s, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]))
        }

        append(title + "\n", size: 22, weight: .bold)
        var lastDelta = 0
        for chunk in chunks {
            if chunk.speedDelta != lastDelta && !chunk.isGuide {
                lastDelta = chunk.speedDelta
                let mark = chunk.speedDelta == 0 ? "‣ velocidad normal"
                    : String(format: "‣ velocidad %+d ppm", chunk.speedDelta)
                append(mark + "\n", size: 10, weight: .semibold, color: .systemOrange)
            }
            let line = chunk.words.joined(separator: " ")
            if chunk.isGuide {
                append("▸ " + line + "\n", size: 12, weight: .medium,
                       color: .systemBlue, italic: true)
            } else {
                switch chunk.style {
                case .h1: append(line + "\n", size: 18, weight: .bold)
                case .h2: append(line + "\n", size: 15, weight: .bold)
                case .bullet: append(line + "\n", size: 12.5)
                case .normal: append(line + (chunk.isParagraphEnd ? "\n" : " "), size: 12.5)
                }
            }
        }

        // Paginado A4 con Core Text.
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let inset: CGFloat = 50
        let textRect = pageRect.insetBy(dx: inset, dy: inset)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw NSError(domain: "BtoPrompter", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "No se pudo crear el PDF"])
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var location = 0
        let length = text.length
        var mediaBox = pageRect
        while location < length {
            ctx.beginPage(mediaBox: &mediaBox)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter,
                                                 CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPage()
            if visible.length == 0 { break }   // nada cupo: evitar bucle infinito
            location += visible.length
        }
        ctx.closePDF()
    }
}
