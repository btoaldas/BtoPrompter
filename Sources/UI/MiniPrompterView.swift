import AppKit
import SwiftUI

// Modo minimalista: barra delgada pegada arriba de la pantalla (debajo del
// notch/barra de menú), todo el ancho, con karaoke A RENGLÓN SEGUIDO en dos
// líneas fijas: se lee la línea de arriba, se sigue con la de abajo y, al
// pasar a ella, el texto sube un renglón — flujo continuo, sin saltos.
// Tecla M o el botón de expandir vuelven al modo normal.

// Token de render lineal: palabra leíble (con índice global) o palabra de guía.
private struct MiniToken {
    let text: String
    let globalIndex: Int?   // nil = guía (azul, no leída)
}

struct MiniPrompterView: View {
    @EnvironmentObject var model: PrompterModel

    // Cache de la partición en líneas: se recalcula solo si cambia la firma
    // (ancho disponible, tamaño de letra o discurso).
    @State private var lines: [[MiniToken]] = []
    @State private var lineOfIndex: [Int: Int] = [:]
    @State private var signature: String = ""

    var body: some View {
            let textWidth = model.miniContentWidth
            VStack(spacing: 0) {
                ProgressView(value: model.totalWords > 0
                             ? Double(model.currentIndex) / Double(max(1, model.totalWords - 1))
                             : 0)
                    .tint(Theme.accent)
                    .scaleEffect(x: 1, y: 0.5, anchor: .top)
                HStack(spacing: 10) {
                    ControlButton(symbol: "gobackward", help: "Reiniciar (R)", size: 12) { model.reset() }
                    ControlButton(symbol: model.isPlaying ? "pause.fill" : "play.fill",
                                  help: "Play / Pausa (espacio, ⌥⌘P)", size: 16, color: Theme.accent) {
                        model.togglePlay()
                    }

                    linesView
                        .frame(width: textWidth, alignment: .leading)
                        .clipped()

                    Spacer(minLength: 4)

                    HStack(spacing: 4) {
                        ControlButton(symbol: "tortoise.fill", help: "Más lento (↓)", size: 11) {
                            model.changeSpeed(-Settings.Limits.wpmStep)
                        }
                        Text("\(model.wpm)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                            .frame(width: 28)
                        ControlButton(symbol: "hare.fill", help: "Más rápido (↑)", size: 11) {
                            model.changeSpeed(+Settings.Limits.wpmStep)
                        }
                    }
                    HStack(spacing: 4) {
                        ControlButton(symbol: "textformat.size.smaller", help: "Letra más pequeña (−)", size: 11) {
                            model.changeFont(-Settings.Limits.fontStep)
                        }
                        ControlButton(symbol: "textformat.size.larger", help: "Letra más grande (+)", size: 11) {
                            model.changeFont(+Settings.Limits.fontStep)
                        }
                    }
                    ControlButton(symbol: model.spyMode ? "eye.slash.fill" : "eye.fill",
                                  help: "Invisible/visible al compartir pantalla", size: 12,
                                  color: model.spyMode ? Theme.spyOn : Theme.spyOff) {
                        model.spyMode.toggle()
                    }
                    ControlButton(symbol: "arrow.down.left.and.arrow.up.right",
                                  help: "Volver al tamaño normal (M)", size: 12) {
                        model.toggleMiniMode()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear { rebuildIfNeeded(width: textWidth) }
            .onReceive(model.$miniContentWidth) { w in rebuildIfNeeded(width: w) }
            .onReceive(model.$miniFontSize) { _ in rebuildIfNeeded(width: model.miniContentWidth, force: true) }
            .onReceive(model.$chunks) { _ in rebuildIfNeeded(width: model.miniContentWidth, force: true) }
    }

    // Las dos líneas del karaoke: la actual arriba, la siguiente abajo.
    private var linesView: some View {
        let li = lineOfIndex[model.currentIndex] ?? 0
        let lineHeight = ceil(model.miniFontSize * 1.3)
        return VStack(alignment: .leading, spacing: 2) {
            Text(attributed(line: li))
                .lineLimit(1)
                .frame(height: lineHeight, alignment: .leading)
            Text(attributed(line: li + 1))
                .lineLimit(1)
                .frame(height: lineHeight, alignment: .leading)
        }
        .shadow(color: .black.opacity(0.9), radius: 1, x: 0, y: 1)
        .animation(.easeOut(duration: 0.15), value: li)
    }

    private func attributed(line index: Int) -> AttributedString {
        guard index >= 0, index < lines.count else { return AttributedString(" ") }
        let font = Font.system(size: model.miniFontSize, weight: .semibold, design: .rounded)
        var result = AttributedString()
        for (i, token) in lines[index].enumerated() {
            var a = AttributedString(token.text)
            a.font = font
            if let g = token.globalIndex {
                if g < model.currentIndex {
                    a.foregroundColor = Theme.dimmed
                } else if g == model.currentIndex {
                    a.foregroundColor = Theme.highlight(model.accentColorID)
                    a.underlineStyle = .single
                } else {
                    a.foregroundColor = .white
                }
            } else {
                a.foregroundColor = Theme.guide.opacity(0.85)
            }
            result += a
            if i < lines[index].count - 1 { result += AttributedString(" ") }
        }
        return result
    }

    // MARK: Partición en líneas por ancho real de las palabras

    private func rebuildIfNeeded(width: CGFloat, force: Bool = false) {
        let sig = "\(Int(width))|\(Int(model.miniFontSize))|\(model.chunks.count)|\(model.totalWords)"
        guard force || sig != signature else { return }
        signature = sig

        let descriptor = NSFont.systemFont(ofSize: model.miniFontSize, weight: .semibold)
            .fontDescriptor.withDesign(.rounded)
        let font = descriptor.flatMap { NSFont(descriptor: $0, size: model.miniFontSize) }
            ?? NSFont.systemFont(ofSize: model.miniFontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let spaceWidth = (" " as NSString).size(withAttributes: attrs).width

        // Discurso completo como flujo continuo de tokens.
        var tokens: [MiniToken] = []
        for chunk in model.chunks {
            if chunk.isGuide {
                for (i, w) in chunk.words.enumerated() {
                    tokens.append(MiniToken(text: i == 0 ? "▸ " + w : w, globalIndex: nil))
                }
            } else {
                for (i, w) in chunk.words.enumerated() {
                    tokens.append(MiniToken(text: w, globalIndex: chunk.range.lowerBound + i))
                }
            }
        }

        // Partición greedy: cada línea se dibuja luego como un solo Text de una
        // línea, así esta partición ES el layout real (sin desincronización).
        var newLines: [[MiniToken]] = []
        var current: [MiniToken] = []
        var currentWidth: CGFloat = 0
        for token in tokens {
            let w = (token.text as NSString).size(withAttributes: attrs).width
            if !current.isEmpty && currentWidth + spaceWidth + w > width {
                newLines.append(current)
                current = []
                currentWidth = 0
            }
            currentWidth += (current.isEmpty ? 0 : spaceWidth) + w
            current.append(token)
        }
        if !current.isEmpty { newLines.append(current) }

        var map: [Int: Int] = [:]
        for (li, line) in newLines.enumerated() {
            for token in line {
                if let g = token.globalIndex { map[g] = li }
            }
        }
        lines = newLines
        lineOfIndex = map
    }
}
