import AppKit
import AVFoundation
import AVKit
import SwiftUI

// Editor de composición: junta la cámara y la pantalla de una grabación en un
// vídeo publicable. Presets con un clic, previsualización real (el mismo
// compositor que exporta) y botón de exportar. Se crea BAJO DEMANDA: con la
// función apagada esta ventana no existe.
//
// OJO: esta ventana SÍ se ve al compartir pantalla. Es un editor, no el
// teleprompter; la invisibilidad es del PrompterPanel y de nadie más.

@MainActor
final class VideoEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = VideoEditorWindowController()
    private var window: NSWindow?

    static var enabled: Bool { Settings.bool(.videoEditorEnabled, default: false) }

    func open(folder: URL? = nil) {
        guard Self.enabled else { return }
        let target = folder ?? Self.latestRecordingFolder()
        guard let target, let sources = CompositionBuilder.sources(inFolder: target) else {
            let alert = NSAlert()
            alert.messageText = "No hay ninguna grabación completa"
            alert.informativeText = "El editor necesita una carpeta con cámara Y pantalla "
                + "(dos archivos .mov). Graba con ambas activadas en Ajustes → Grabación."
            alert.runModal()
            return
        }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Componer grabación"
            w.center()
            w.delegate = self
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.contentView = NSHostingView(rootView: VideoEditorView(sources: sources, folder: target))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Soltar el player y el compositor al cerrar: apagado = inerte.
        window?.contentView = nil
    }

    static func latestRecordingFolder() -> URL? {
        let base = RecordingEngine.baseFolder
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return nil
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first { CompositionBuilder.sources(inFolder: $0) != nil }
    }
}

struct VideoEditorView: View {
    let sources: CompositionBuilder.Sources
    let folder: URL

    @State private var player: AVPlayer? = nil
    @State private var status: String? = nil
    @State private var selectedPreset = 1
    @State private var exporting = false
    @State private var exportProgress = 0.0
    @State private var composition: AVMutableComposition? = nil
    @State private var videoComposition: AVMutableVideoComposition? = nil

    var body: some View {
        VStack(spacing: 0) {
            if let player {
                EditorPlayerSurface(player: player)
                    .background(Color.black)
            } else {
                ZStack {
                    Color.black
                    if let status {
                        Text(status).foregroundStyle(.orange)
                    } else {
                        ProgressView("Preparando la composición…")
                    }
                }
            }

            HStack(spacing: 10) {
                ForEach(Array(CompositionLayout.presets.enumerated()), id: \.offset) { i, preset in
                    Button(action: { apply(i) }) {
                        Text("\(i + 1) · \(preset.name)")
                            .font(.system(size: 12, weight: selectedPreset == i ? .bold : .regular))
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedPreset == i ? .accentColor : .secondary)
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
                }
                Spacer()
                if exporting {
                    ProgressView(value: exportProgress)
                        .frame(width: 140)
                    Text("\(Int(exportProgress * 100)) %").monospacedDigit()
                } else {
                    Button("Exportar…") { exportVideo() }
                        .buttonStyle(.borderedProminent)
                        .disabled(composition == nil)
                }
            }
            .padding(12)
            .background(.regularMaterial)

            Text("El desfase entre cámara y pantalla ya está corregido "
                 + "(\(Int(abs(sources.offsetSeconds * 1000))) ms, medido al grabar). "
                 + "Esta ventana SÍ aparece al compartir pantalla: es un editor, no el teleprompter.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(minWidth: 860, minHeight: 560)
        .task { await prepare() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func prepare() async {
        do {
            let built = try await CompositionBuilder.build(sources)
            composition = built.composition
            videoComposition = built.video
            apply(selectedPreset)
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.video
            let p = AVPlayer(playerItem: item)
            player = p
        } catch {
            status = error.localizedDescription
        }
    }

    private func apply(_ index: Int) {
        selectedPreset = index
        CompositionParameters.shared.layout = CompositionLayout.presets[index].layout
        // En pausa el fotograma no se refresca solo: se fuerza un redibujado.
        if let p = player, p.rate == 0 {
            let t = p.currentTime()
            p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func exportVideo() {
        guard let composition, let videoComposition else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "montaje-\(folder.lastPathComponent).mp4"
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        exportProgress = 0
        CompositionExporter.export(composition: composition, video: videoComposition,
                                   to: url, progress: { exportProgress = $0 }) { result in
            exporting = false
            switch result {
            case .success(let out):
                NSWorkspace.shared.activateFileViewerSelecting([out])
            case .failure(let error):
                status = error.localizedDescription
            }
        }
    }
}

// AVPlayerView trae controles del sistema (play, timeline) sin gestos que
// estorben; para el MVP basta y sobra.
private struct EditorPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        return v
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
