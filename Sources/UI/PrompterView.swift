import SwiftUI

// Vista del prompter: progreso, texto con karaoke y barra de controles.

struct PrompterView: View {
    @EnvironmentObject var model: PrompterModel

    var body: some View {
        ZStack {
            if model.miniMode {
                MiniPrompterView()
            } else {
                VStack(spacing: 0) {
                    header
                    scroller
                    controls
                }
            }
            if let n = model.countdown {
                CountdownOverlay(number: n, compact: model.miniMode)
            }
        }
    }

    // MARK: Encabezado (progreso y tiempo)

    private var header: some View {
        VStack(spacing: 4) {
            ProgressView(value: model.totalWords > 0
                         ? Double(model.currentIndex) / Double(max(1, model.totalWords - 1))
                         : 0)
                .tint(Theme.accent)
            HStack {
                Text("\(model.currentIndex + 1) / \(model.totalWords)")
                Spacer()
                Text("~\(model.remainingTimeText) restante · \(model.wpm) ppm\(deltaText)")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.gray)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var deltaText: String {
        let d = model.chunkAt(model.currentIndex)?.speedDelta ?? 0
        return d == 0 ? "" : String(format: " (%+d)", d)
    }

    // MARK: Texto

    private var scroller: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: model.fontSize * 0.55) {
                    Color.clear.frame(height: 200).id(-1)
                    ForEach(model.chunks) { chunk in
                        Text(attributedText(for: chunk))
                            .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                            .shadow(color: .black.opacity(0.7), radius: 6)
                            .id(chunk.id)
                            .padding(.bottom, chunk.isParagraphEnd ? model.fontSize * 0.5 : 0)
                            .padding(.leading, chunk.style == .bullet ? model.fontSize * 0.8 : 0)
                            .onTapGesture { model.jump(to: chunk.range.lowerBound) }
                    }
                    Color.clear.frame(height: 240).id(-2)
                }
                .padding(.horizontal, 28)
            }
            .onReceive(model.$currentIndex) { _ in
                if let id = model.currentChunkID {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onAppear {
                proxy.scrollTo(model.currentChunkID ?? 0, anchor: .center)
            }
        }
    }

    // El peso y tamaño NUNCA cambian con el resaltado: así la palabra pintada
    // no altera el ancho del texto y las líneas no saltan de sitio.
    private func fontFor(_ style: ChunkStyle) -> Font {
        switch style {
        case .h1: return .system(size: model.fontSize * 1.45, weight: .black, design: .rounded)
        case .h2: return .system(size: model.fontSize * 1.2, weight: .heavy, design: .rounded)
        case .bullet, .normal: return .system(size: model.fontSize, weight: .semibold, design: .rounded)
        }
    }

    private func attributedText(for chunk: Chunk) -> AttributedString {
        let font = fontFor(chunk.style)
        if chunk.isGuide {
            // Guía: se ve, no se lee. Color propio, sin karaoke.
            var a = AttributedString("▸ " + chunk.words.joined(separator: " "))
            a.foregroundColor = Theme.guide.opacity(0.85)
            a.font = font
            return a
        }
        var result = AttributedString()
        for (i, word) in chunk.words.enumerated() {
            let g = chunk.range.lowerBound + i
            var a = AttributedString(word)
            a.font = font
            if g < model.currentIndex {
                a.foregroundColor = Theme.dimmed
            } else if g == model.currentIndex {
                a.foregroundColor = Theme.highlight(model.accentColorID)
                a.underlineStyle = .single
            } else {
                a.foregroundColor = chunk.style == .h1 || chunk.style == .h2 ? Theme.heading : .white
            }
            result += a
            if i < chunk.words.count - 1 { result += AttributedString(" ") }
        }
        return result
    }

    // MARK: Controles

    private var controls: some View {
        HStack(spacing: 16) {
            ControlButton(symbol: "gobackward", help: "Reiniciar (R)") { model.reset() }
            ControlButton(symbol: "backward.fill", help: "Atrás 10 palabras (←)") { model.skip(-10) }
            ControlButton(symbol: "backward.frame.fill", help: "Atrás 1 palabra (⇧←)", size: 13) { model.skip(-1) }
            ControlButton(symbol: model.isPlaying || model.countdown != nil ? "pause.fill" : "play.fill",
                          help: "Play / Pausa (espacio)", size: 22, color: Theme.accent) {
                model.togglePlay()
            }
            ControlButton(symbol: "forward.frame.fill", help: "Adelante 1 palabra (⇧→)", size: 13) { model.skip(+1) }
            ControlButton(symbol: "forward.fill", help: "Adelante 10 palabras (→)") { model.skip(+10) }
            ControlButton(symbol: "stop.fill", help: "Volver al editor (Esc)") { model.backToEditor() }
            ControlButton(symbol: "menubar.dock.rectangle", help: "Modo minimalista: barra de 2 líneas arriba de la pantalla (M)") {
                model.toggleMiniMode()
            }
            Divider().frame(height: 18)
            HStack(spacing: 4) {
                ControlButton(symbol: "tortoise.fill", help: "Más lento (↓)", size: 13) {
                    model.changeSpeed(-Settings.Limits.wpmStep)
                }
                Text("\(model.wpm)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.gray)
                    .frame(width: 32)
                ControlButton(symbol: "hare.fill", help: "Más rápido (↑)", size: 13) {
                    model.changeSpeed(+Settings.Limits.wpmStep)
                }
            }
            HStack(spacing: 4) {
                ControlButton(symbol: "textformat.size.smaller", help: "Letra más pequeña (−)", size: 13) {
                    model.changeFont(-Settings.Limits.fontStep)
                }
                ControlButton(symbol: "textformat.size.larger", help: "Letra más grande (+)", size: 13) {
                    model.changeFont(+Settings.Limits.fontStep)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                Slider(value: $model.bgOpacity, in: 0.0...1.0)
                    .frame(width: 80)
                Image(systemName: "circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            .help("Opacidad del fondo: 0% = solo letras flotando ( [ y ] en teclado )")
            Spacer()
            Text("⌥⌘P ⏯ · ⌥⌘↑↓ velocidad")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.guide)
                .help("Atajos GLOBALES: funcionan aunque estés en PowerPoint, Keynote o cualquier otra app")
            SpyToggle()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05))
    }
}
