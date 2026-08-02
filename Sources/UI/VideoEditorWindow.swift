import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

// Editor de composición: junta la cámara y la pantalla de una grabación en un
// vídeo publicable, por TRAMOS de tiempo — del segundo A al B la cara en
// círculo abajo a la derecha, del B al C lado a lado 30/70, etc.
// Previsualización real (el mismo compositor que exporta), proyecto guardado
// en project.json junto a los .mov, y exportar MP4.
//
// Se crea BAJO DEMANDA: con la función apagada esta ventana no existe.
// OJO: esta ventana SÍ se ve al compartir pantalla. Es un editor, no el
// teleprompter; la invisibilidad es del PrompterPanel y de nadie más.

@MainActor
final class VideoEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = VideoEditorWindowController()
    private var window: NSWindow?

    static var enabled: Bool { Settings.bool(.videoEditorEnabled, default: false) }

    private var pickerWindow: NSWindow?

    // Sin carpeta explícita se abre el SELECTOR: cualquier grabación o
    // proyecto, no solo el último.
    func open(folder: URL? = nil) {
        guard Self.enabled else { return }
        guard let target = folder else {
            openPicker()
            return
        }
        openFolder(target)
    }

    private func openPicker() {
        if pickerWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Elegir grabación o proyecto"
            w.center()
            w.isReleasedWhenClosed = false
            pickerWindow = w
        }
        pickerWindow?.contentView = NSHostingView(rootView: ProjectPickerView { [weak self] url in
            self?.pickerWindow?.orderOut(nil)
            self?.openFolder(url)
        })
        pickerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openFolder(_ target: URL) {
        guard Self.enabled else { return }
        guard let sources = CompositionBuilder.sources(inFolder: target) else {
            let alert = NSAlert()
            alert.messageText = "No hay ninguna grabación que componer"
            alert.informativeText = "El editor necesita una carpeta de grabación con al menos "
                + "un archivo de cámara o de pantalla. Graba primero desde Ajustes → Grabación."
            alert.runModal()
            return
        }
        openEditorWindow(target: target, sources: sources)
    }

    private func openEditorWindow(target: URL, sources: CompositionBuilder.Sources) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Componer grabación"
            w.center()
            w.delegate = self
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.title = "Componer grabación — \(target.lastPathComponent)"
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

// MARK: - Estado observable del proyecto

// Un solo dueño del proyecto: cada cambio pasa por aquí, va a la caja del
// compositor (fotograma siguiente ya sale nuevo) y se guarda a disco.
@MainActor
final class VideoProjectState: ObservableObject {
    @Published var project: VideoProject {
        didSet {
            // Al compositor de inmediato (preview en vivo); al disco con
            // calma: un arrastre de slider son decenas de cambios por segundo
            // y escribir JSON en cada uno castiga el disco sin necesidad.
            CompositionParameters.shared.project = project
            scheduleSave()
            onChange?()
        }
    }

    private var saveWork: DispatchWorkItem?

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            VideoProjectStore.save(self.project, folder: self.folder)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // Guardado inmediato: al cerrar la ventana y antes de exportar.
    func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        VideoProjectStore.save(project, folder: folder)
    }
    @Published var selectedSegment = 0
    // Capa seleccionada: compartida entre el panel y el lienzo vivo.
    @Published var selectedLayerID: UUID? = nil
    let folder: URL
    var onChange: (() -> Void)?

    init(folder: URL, duration: Double) {
        self.folder = folder
        var p = VideoProjectStore.load(folder: folder, duration: duration)
        p.duration = duration
        project = p.sanitized()
        CompositionParameters.shared.project = project
    }

    var selectedLayout: SegmentLayout {
        get {
            let i = min(selectedSegment, project.layouts.count - 1)
            return project.layouts[max(0, i)]
        }
        set {
            let i = min(selectedSegment, project.layouts.count - 1)
            guard i >= 0 else { return }
            project.layouts[i] = newValue.sanitized()
        }
    }

    func cut(at seconds: Double) {
        var p = project
        if let newIndex = p.addCut(at: seconds) {
            project = p
            selectedSegment = newIndex
        }
    }

    func removeSelected() {
        var p = project
        p.removeSegment(selectedSegment)
        project = p
        selectedSegment = max(0, min(selectedSegment - 1, p.layouts.count - 1))
    }

    func applyChapters() {
        let seconds = VideoProjectStore.chapterSeconds(inFolder: folder)
        guard !seconds.isEmpty else { return }
        var p = project
        p.applyChapterCuts(seconds)
        project = p
    }

    var hasChapters: Bool {
        !VideoProjectStore.chapterSeconds(inFolder: folder).isEmpty
    }
}

// MARK: - Vista raíz

struct VideoEditorView: View {
    let sources: CompositionBuilder.Sources
    let folder: URL

    @StateObject private var state: VideoProjectState
    @State private var player: AVPlayer? = nil
    @State private var status: String? = nil
    @State private var exporting = false
    @State private var exportProgress = 0.0
    @State private var exportError: String? = nil
    @State private var exportSession: AVAssetExportSession? = nil
    @State private var composition: AVMutableComposition? = nil
    @State private var videoComposition: AVMutableVideoComposition? = nil
    @State private var playhead: Double = 0
    @State private var timeObserver: Any? = nil
    // Serializa prepare()/rebuild(): solo la construcción más reciente asigna.
    @State private var buildGeneration = 0
    @State private var isPlaying = false
    // Herramienta de anotación activa (nil = mover/redimensionar normal).
    @State private var tool: ShapeContent.Kind? = nil

    // Barra de anotaciones sobre la previsualización: eliges la herramienta y
    // arrastras sobre el vídeo para dibujarla. Se apaga sola tras dibujar.
    private var annotationBar: some View {
        HStack(spacing: 4) {
            ForEach(ShapeContent.Kind.allCases, id: \.self) { kind in
                Button(action: { tool = (tool == kind) ? nil : kind }) {
                    Image(systemName: kind.symbol)
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(tool == kind ? Color.accentColor : Color.black.opacity(0.45)))
                .foregroundColor(.white)
                .help(kind.label)
            }
            if tool != nil {
                Text("arrastra sobre el vídeo")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
                    .padding(.leading, 4)
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.4)))
        .padding(.top, 8)
    }

    private func togglePlay() {
        guard let p = player else { return }
        if p.rate == 0 {
            p.play()
            isPlaying = true
        } else {
            p.pause()
            isPlaying = false
        }
    }

    init(sources: CompositionBuilder.Sources, folder: URL) {
        self.sources = sources
        self.folder = folder
        _state = StateObject(wrappedValue: VideoProjectState(folder: folder, duration: 0))
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if let player {
                    ZStack(alignment: .top) {
                        PlainPlayerSurface(player: player)
                        LiveCanvasOverlay(state: state, playhead: $playhead, tool: $tool)
                        annotationBar
                    }
                    .background(Color.black)
                    .layoutPriority(1)
                } else {
                    ZStack {
                        Color.black
                        if let status {
                            Text(status).foregroundStyle(.orange).padding()
                        } else {
                            ProgressView("Preparando la composición…")
                        }
                    }
                    .layoutPriority(1)
                }

                TimelineStrip(state: state, playhead: $playhead) { seconds in
                    seek(to: seconds)
                }
                .frame(height: 74)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                bottomBar
            }
            .frame(minWidth: 640)

            SegmentInspector(state: state, playhead: $playhead,
                             discoveredCamera: sources.cameraURL?.lastPathComponent,
                             discoveredScreen: sources.screenURL?.lastPathComponent,
                             onStructureChange: { Task { await rebuild() } },
                             refresh: { refreshPausedFrame() })
                .frame(minWidth: 300, maxWidth: 380)
        }
        .frame(minWidth: 980, minHeight: 640)
        .task { await prepare() }
        .onReceive(NotificationCenter.default.publisher(for: .init("BtoPrompterRebuild"))) { _ in
            Task { await rebuild() }
        }
        .onDisappear {
            if let obs = timeObserver { player?.removeTimeObserver(obs) }
            timeObserver = nil
            player?.pause()
            player = nil
            // Cerrar con una exportación en marcha la cancela con claridad,
            // en vez de dejarla huérfana escribiendo sin dueño.
            exportSession?.cancelExport()
            exportSession = nil
            CompositionParameters.shared.exportProject = nil
            state.flushSave()
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button(action: { togglePlay() }) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(player == nil)
            .help("Reproducir / pausar (espacio)")

            Button(action: { state.cut(at: playhead) }) {
                Label("Cortar aquí", systemImage: "scissors")
            }
            .keyboardShortcut("s", modifiers: [])
            .help("Parte el tramo bajo el cursor en dos (tecla S)")
            .disabled(player == nil)

            Button(action: { state.removeSelected() }) {
                Label("Fusionar tramo", systemImage: "arrow.triangle.merge")
            }
            .help("Elimina el tramo seleccionado fusionándolo con el anterior")
            .disabled(state.project.layouts.count < 2)

            if state.hasChapters {
                Button(action: { state.applyChapters() }) {
                    Label("Un tramo por capítulo", systemImage: "book")
                }
                .help("Genera un corte en cada capítulo del guion (capitulos.txt)")
            }

            Spacer()

            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 320)
            }
            if exporting {
                ProgressView(value: exportProgress).frame(width: 140)
                Text("\(Int(exportProgress * 100)) %").monospacedDigit()
            } else {
                Button("Exportar…") { exportVideo() }
                    .buttonStyle(.borderedProminent)
                    .disabled(composition == nil)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private func prepare() async {
        do {
            // Las capas de vídeo necesitan pista propia: se leen del proyecto
            // guardado ANTES de construir la composición.
            buildGeneration += 1
            let gen = buildGeneration
            let saved = VideoProjectStore.load(folder: folder, duration: 0)
            let built = try await CompositionBuilder.build(sources, extraLayers: saved.extraLayers,
                                                           audioLayers: saved.audioLayers,
                                                           micVolume: saved.micVolume,
                                                           screenAudioVolume: saved.screenAudioVolume)
            guard gen == buildGeneration else { return }
            composition = built.composition
            videoComposition = built.video
            // El proyecto se RECARGA de disco ahora que la duración es real:
            // cargarlo antes con duración 0 y sanearlo destruía los cortes
            // guardados (y el didSet persistía la destrucción).
            state.project = VideoProjectStore.load(folder: folder, duration: built.duration)
            state.onChange = { refreshPausedFrame() }

            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.video
            item.audioMix = built.audioMix
            let p2 = AVPlayer(playerItem: item)
            timeObserver = p2.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 10), queue: .main
            ) { t in
                Task { @MainActor in
                    // Solo mueve el cursor. La SELECCIÓN es del usuario: si el
                    // observador la pisara cada décima, editar un tramo con la
                    // reproducción en marcha sería imposible (los controles
                    // cambiarían de tramo bajo las manos).
                    playhead = t.seconds
                }
            }
            player = p2
        } catch {
            status = error.localizedDescription
        }
    }

    // Cambió la ESTRUCTURA (capa de vídeo añadida/quitada, fuente sustituida):
    // la composición se reconstruye con las pistas nuevas, conservando dónde
    // estaba el cursor. Los cambios de dibujo no pasan por aquí.
    private func rebuild() async {
        let keep = playhead
        state.flushSave()
        buildGeneration += 1
        let gen = buildGeneration
        do {
            let freshSources = CompositionBuilder.sources(inFolder: folder)
            let src = freshSources ?? sources
            let built = try await CompositionBuilder.build(src, extraLayers: state.project.extraLayers,
                                                           audioLayers: state.project.audioLayers,
                                                           micVolume: state.project.micVolume,
                                                           screenAudioVolume: state.project.screenAudioVolume)
            // Otro rebuild arrancó mientras este esperaba: el viejo se calla
            // en vez de terminar último y pisar al nuevo.
            guard gen == buildGeneration else { return }
            composition = built.composition
            videoComposition = built.video
            var proj = state.project
            proj.duration = built.duration
            state.project = proj.sanitized()
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.video
            item.audioMix = built.audioMix
            player?.replaceCurrentItem(with: item)
            await player?.seek(to: CMTime(seconds: min(keep, built.duration), preferredTimescale: 600),
                               toleranceBefore: .zero, toleranceAfter: .zero)
        } catch {
            status = error.localizedDescription
        }
    }

    // En pausa el fotograma no se refresca solo: se fuerza un redibujado.
    // OJO: pedir seek AL MISMO instante es un no-op para AVPlayer (ya está
    // ahí) y la imagen no se recompone — el arrastre movía el recuadro pero
    // el vídeo quedaba congelado hasta el play. El microsalto de medio
    // fotograma alternado obliga a redibujar SIEMPRE, y es invisible.
    @State private var refreshFlip = false

    private func refreshPausedFrame() {
        guard let p = player, p.rate == 0 else { return }
        refreshFlip.toggle()
        let jitter = CMTime(value: refreshFlip ? 1 : -1, timescale: 1200)
        let target = CMTimeMaximum(.zero, CMTimeAdd(p.currentTime(), jitter))
        p.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = seconds
        state.selectedSegment = state.project.segmentIndex(at: seconds)
    }

    // Los subtítulos separados viajan CON el vídeo: video.srt junto al MP4 y
    // las traducciones que existan como video.<código>.srt, listos para
    // subirlos a YouTube como pistas.
    private func writeSubtitleFiles(next videoURL: URL) {
        guard let track = state.project.subtitles, track.enabled,
              !track.chunks.isEmpty, !track.burnIn else { return }
        let base = videoURL.deletingPathExtension()
        try? SubtitleBuilder.toSRT(track.chunks)
            .write(to: base.appendingPathExtension("srt"), atomically: true, encoding: .utf8)
        let fm = FileManager.default
        for lang in SubtitleAI.languages {
            let translated = folder.appendingPathComponent("subtitulos.\(lang.code).srt")
            guard fm.fileExists(atPath: translated.path) else { continue }
            let dest = URL(fileURLWithPath: base.path + ".\(lang.code).srt")
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: translated, to: dest)
        }
    }

    private func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "montaje-\(folder.lastPathComponent).mp4"
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.flushSave()
        exporting = true
        exportProgress = 0
        exportError = nil
        // UNA copia congelada para todo el camino: la receta que dibuja el
        // compositor y las capas con que se montan las pistas salen del mismo
        // instante — seguir editando mientras exporta no contamina el archivo.
        let snapshot = state.project
        CompositionParameters.shared.exportProject = snapshot
        Task {
            do {
                // Fuentes RELEÍDAS de disco: si el usuario sustituyó la cámara
                // o la pantalla en esta sesión, el MP4 debe salir con lo que
                // está viendo, no con lo que había al abrir la ventana.
                // flushSave ya persistió los cambios, así que sources() los ve.
                let src = CompositionBuilder.sources(inFolder: folder) ?? sources
                let built = try await CompositionBuilder.build(src,
                                                               extraLayers: snapshot.extraLayers,
                                                               audioLayers: snapshot.audioLayers,
                                                               micVolume: snapshot.micVolume,
                                                               screenAudioVolume: snapshot.screenAudioVolume)
                built.video.customVideoCompositorClass = ExportCompositor.self
                exportSession = CompositionExporter.export(
                    composition: built.composition, video: built.video,
                    audioMix: built.audioMix,
                    to: url, progress: { exportProgress = $0 }) { result in
                    exporting = false
                    exportSession = nil
                    CompositionParameters.shared.exportProject = nil
                    switch result {
                    case .success(let out):
                        writeSubtitleFiles(next: out)
                        NSWorkspace.shared.activateFileViewerSelecting([out])
                    case .failure(let error):
                        exportError = error.localizedDescription
                    }
                }
            } catch {
                exporting = false
                CompositionParameters.shared.exportProject = nil
                exportError = error.localizedDescription
            }
        }
    }
}

// MARK: - Línea de tiempo

// Tira de tramos: cada bloque es un tramo con su modo; clic selecciona y
// mueve el cursor a su inicio; clic en la regla mueve solo el cursor.
struct TimelineStrip: View {
    @ObservedObject var state: VideoProjectState
    @Binding var playhead: Double
    let onSeek: (Double) -> Void
    @State private var draggingCut: Int? = nil

    private func modeLabel(_ m: SegmentLayout.Mode) -> String {
        switch m {
        case .overlay: return "◉ Círculo"
        case .sideBySide: return "◫ Lado a lado"
        case .onlyScreen: return "🖥 Pantalla"
        case .onlyCamera: return "🎥 Cámara"
        }
    }

    var body: some View {
        GeometryReader { geo in
            let duration = max(0.001, state.project.duration)
            let w = geo.size.width

            VStack(spacing: 3) {
                // Bloques de tramos.
                HStack(spacing: 1) {
                    ForEach(0..<state.project.layouts.count, id: \.self) { i in
                        let range = state.project.segmentRange(i)
                        let frac = max(0.001, (range.end - range.start) / duration)
                        let selected = i == state.selectedSegment
                        Text(modeLabel(state.project.layouts[i].mode))
                            .font(.system(size: 10, weight: selected ? .bold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(width: max(2, w * frac - 1), height: 34)
                            .background(selected ? Color.accentColor.opacity(0.85)
                                                 : Color.gray.opacity(0.35))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .onTapGesture {
                                state.selectedSegment = i
                                onSeek(range.start + 0.01)
                            }
                    }
                }

                // Regla con el cursor: clic o arrastre mueven la reproducción.
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 18)
                    // Marcas de corte: se agarran y se ARRASTRAN. moveCut ya
                    // impide invadir al corte vecino; el imán pega a segundos
                    // enteros cuando pasa a menos de un decimo.
                    ForEach(Array(state.project.cuts.enumerated()), id: \.offset) { ci, cut in
                        Rectangle()
                            .fill(draggingCut == ci ? Color.yellow : Color.orange)
                            .frame(width: 2, height: 18)
                            .frame(width: 14)               // zona de agarre generosa
                            .contentShape(Rectangle())
                            .offset(x: w * cut / duration - 7)
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { g in
                                        draggingCut = ci
                                        var s = Double((g.location.x) / w) * duration
                                        let whole = (s).rounded()
                                        if abs(s - whole) < 0.1 { s = whole }   // imán
                                        var p = state.project
                                        p.moveCut(ci, to: s)
                                        state.project = p
                                    }
                                    .onEnded { _ in draggingCut = nil }
                            )
                            .help(String(format: "Corte en %.1f s — arrastra para moverlo", cut))
                    }
                    // Cursor.
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 2, height: 18)
                        .offset(x: w * min(1, max(0, playhead / duration)))
                    Text(timeString(playhead) + " / " + timeString(duration))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let s = min(duration, max(0, Double(g.location.x / w) * duration))
                    onSeek(s)
                })
            }
        }
    }

    private func timeString(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Inspector del tramo

// Todo lo editable del tramo seleccionado, agrupado por componentes. Añadir
// un control nuevo = añadir una sección; nada de esto toca el reproductor.
struct SegmentInspector: View {
    @ObservedObject var state: VideoProjectState
    @Binding var playhead: Double
    let discoveredCamera: String?
    let discoveredScreen: String?
    let onStructureChange: () -> Void
    let refresh: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let range = state.project.segmentRange(state.selectedSegment)
                Text("Tramo \(state.selectedSegment + 1) de \(state.project.layouts.count)"
                     + String(format: "  ·  %.1f – %.1f s", range.start, range.end))
                    .font(.headline)

                presetRow
                modeSection

                if state.selectedLayout.mode == .overlay {
                    overlaySection
                }
                if state.selectedLayout.mode == .sideBySide {
                    splitSection
                }
                if state.selectedLayout.mode != .onlyScreen {
                    sourceSection(title: "Cámara", keyPath: \.camera)
                }
                if state.selectedLayout.mode != .onlyCamera {
                    sourceSection(title: "Pantalla", keyPath: \.screen)
                }
                shapeSection
                transitionSection
                Divider()
                LayersSection(state: state, playhead: $playhead,
                              onStructureChange: onStructureChange)
                Divider()
                PresetSection(state: state, onStructureChange: onStructureChange)
                Divider()
                SubtitleSection(state: state)
                Divider()
                AudioSection(state: state, playhead: $playhead,
                             onStructureChange: onStructureChange)
                Divider()
                SourceOverrideSection(state: state,
                                      discoveredCamera: discoveredCamera,
                                      discoveredScreen: discoveredScreen,
                                      onStructureChange: onStructureChange)
                Divider()
                backgroundSection
            }
            .padding(14)
        }
        .background(.regularMaterial)
    }

    // Preset = receta completa aplicada al tramo seleccionado (teclas 1–6).
    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(Array(SegmentLayout.presets.enumerated()), id: \.offset) { i, preset in
                    Button("\(i + 1) · \(preset.name)") {
                        state.selectedLayout = preset.layout
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
                }
            }
        }
    }

    private var modeSection: some View {
        Picker("Modo", selection: Binding(
            get: { state.selectedLayout.mode },
            set: { var l = state.selectedLayout; l.mode = $0; state.selectedLayout = l }
        )) {
            Text("Cámara sobre pantalla").tag(SegmentLayout.Mode.overlay)
            Text("Lado a lado").tag(SegmentLayout.Mode.sideBySide)
            Text("Solo pantalla").tag(SegmentLayout.Mode.onlyScreen)
            Text("Solo cámara").tag(SegmentLayout.Mode.onlyCamera)
        }
        .pickerStyle(.menu)
    }

    // Posición y tamaño de la cámara flotante.
    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Posición de la cámara").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 4) {
                positionButton("↖", x: 0.03, y: 0.05)
                positionButton("↑", x: 0.375, y: 0.05)
                positionButton("↗", x: 0.72, y: 0.05)
                positionButton("←", x: 0.03, y: 0.33)
                positionButton("·", x: 0.375, y: 0.33)
                positionButton("→", x: 0.72, y: 0.33)
                positionButton("↙", x: 0.03, y: 0.62)
                positionButton("↓", x: 0.375, y: 0.62)
                positionButton("↘", x: 0.72, y: 0.62)
            }
            slider("Tamaño", value: Binding(
                get: { state.selectedLayout.camRect.width },
                set: { v in
                    var l = state.selectedLayout
                    let cx = l.camRect.x + l.camRect.width / 2
                    let cy = l.camRect.y + l.camRect.height / 2
                    l.camRect.width = v
                    l.camRect.height = v * 1.36    // proporción original del preset
                    l.camRect.x = cx - v / 2
                    l.camRect.y = cy - v * 1.36 / 2
                    state.selectedLayout = l
                }), in: 0.08...0.6)
            slider("Horizontal", value: Binding(
                get: { state.selectedLayout.camRect.x },
                set: { var l = state.selectedLayout; l.camRect.x = $0; state.selectedLayout = l }),
                in: 0...0.94)
            slider("Vertical", value: Binding(
                get: { state.selectedLayout.camRect.y },
                set: { var l = state.selectedLayout; l.camRect.y = $0; state.selectedLayout = l }),
                in: 0...0.94)
        }
    }

    private func positionButton(_ label: String, x: Double, y: Double) -> some View {
        Button(label) {
            var l = state.selectedLayout
            l.camRect.x = x
            l.camRect.y = y
            state.selectedLayout = l
        }
        .font(.system(size: 12))
        .buttonStyle(.bordered)
    }

    // Reparto del lado a lado: 20/80 a 80/20.
    private var splitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            let pct = Int(state.selectedLayout.splitRatio * 100)
            Text("Reparto: cámara \(pct) % · pantalla \(100 - pct) %")
                .font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { state.selectedLayout.splitRatio },
                set: { var l = state.selectedLayout; l.splitRatio = $0; state.selectedLayout = l }
            ), in: 0.2...0.8)
        }
    }

    // Ajustes por fuente: cómo entra la imagen en su ventana, y el recorte.
    private func sourceSection(title: String,
                               keyPath: WritableKeyPath<SegmentLayout, SourceSettings>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker("Ajuste", selection: Binding(
                get: { state.selectedLayout[keyPath: keyPath].fit },
                set: { var l = state.selectedLayout; l[keyPath: keyPath].fit = $0; state.selectedLayout = l }
            )) {
                Text("Llenar (recorta sobrante)").tag(SourceFit.fill)
                Text("Encajar entera").tag(SourceFit.fit)
                Text("Recorte manual").tag(SourceFit.crop)
            }
            .pickerStyle(.menu)

            if state.selectedLayout[keyPath: keyPath].fit == .crop {
                cropControls(keyPath: keyPath)
            }
        }
    }

    // Recorte manual: qué parte del fotograma original se usa.
    private func cropControls(keyPath: WritableKeyPath<SegmentLayout, SourceSettings>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            slider("Desde la izquierda", value: Binding(
                get: { state.selectedLayout[keyPath: keyPath].crop.x },
                set: { var l = state.selectedLayout; l[keyPath: keyPath].crop.x = $0; state.selectedLayout = l }),
                in: 0...0.95)
            slider("Desde arriba", value: Binding(
                get: { state.selectedLayout[keyPath: keyPath].crop.y },
                set: { var l = state.selectedLayout; l[keyPath: keyPath].crop.y = $0; state.selectedLayout = l }),
                in: 0...0.95)
            slider("Ancho", value: Binding(
                get: { state.selectedLayout[keyPath: keyPath].crop.width },
                set: { var l = state.selectedLayout; l[keyPath: keyPath].crop.width = $0; state.selectedLayout = l }),
                in: 0.05...1)
            slider("Alto", value: Binding(
                get: { state.selectedLayout[keyPath: keyPath].crop.height },
                set: { var l = state.selectedLayout; l[keyPath: keyPath].crop.height = $0; state.selectedLayout = l }),
                in: 0.05...1)
            Button("Restablecer recorte") {
                var l = state.selectedLayout
                l[keyPath: keyPath].crop = SourceCrop()
                state.selectedLayout = l
            }
            .font(.system(size: 11))
        }
        .padding(.leading, 8)
    }

    private var shapeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Forma", selection: Binding(
                get: { state.selectedLayout.shape },
                set: { var l = state.selectedLayout; l.shape = $0; state.selectedLayout = l }
            )) {
                Text("Rectángulo").tag(SegmentLayout.Shape.rect)
                Text("Redondeada").tag(SegmentLayout.Shape.rounded)
                Text("Círculo").tag(SegmentLayout.Shape.circle)
            }
            .pickerStyle(.segmented)
            slider("Borde", value: Binding(
                get: { state.selectedLayout.borderWidth },
                set: { var l = state.selectedLayout; l.borderWidth = $0; state.selectedLayout = l }),
                in: 0...0.05)
        }
    }

    // Cómo se ENTRA a este tramo desde el anterior. En el primero no aplica.
    private var transitionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Entrada", selection: Binding(
                get: { state.selectedLayout.transitionIn },
                set: { var l = state.selectedLayout; l.transitionIn = $0; state.selectedLayout = l }
            )) {
                Text("Corte seco").tag(SegmentLayout.TransitionKind.cut)
                Text("Fundido").tag(SegmentLayout.TransitionKind.fade)
            }
            .pickerStyle(.segmented)
            .disabled(state.selectedSegment == 0)
            if state.selectedLayout.transitionIn == .fade {
                slider("Duración (ms)", value: Binding(
                    get: { state.selectedLayout.transitionMs },
                    set: { var l = state.selectedLayout; l.transitionMs = $0; state.selectedLayout = l }),
                    in: 100...2000)
            }
            if state.selectedSegment == 0 {
                Text("El primer tramo no tiene entrada.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // El fondo es GLOBAL (no por tramo): color, degradado o imagen.
    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fondo (todo el vídeo)").font(.caption).foregroundStyle(.secondary)
            Picker("Tipo", selection: Binding(
                get: { backgroundKind },
                set: { setBackgroundKind($0) }
            )) {
                Text("Color").tag(0)
                Text("Degradado").tag(1)
                Text("Imagen").tag(2)
            }
            .pickerStyle(.segmented)

            switch state.project.background {
            case .color(let c):
                colorRow("Color", c) { new in state.project.background = .color(new) }
            case .gradient(let top, let bottom):
                colorRow("Arriba", top) { new in
                    state.project.background = .gradient(top: new, bottom: bottom)
                }
                colorRow("Abajo", bottom) { new in
                    state.project.background = .gradient(top: top, bottom: new)
                }
            case .image(let path, let mode):
                let missing = !FileManager.default.fileExists(atPath: path)
                HStack {
                    if missing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(URL(fileURLWithPath: path).lastPathComponent
                         + (missing ? " (no encontrada)" : ""))
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(missing ? .orange : .primary)
                    Spacer()
                    Button("Elegir…") { chooseBackgroundImage(mode: mode) }
                        .font(.system(size: 11))
                }
                Picker("Modo", selection: Binding(
                    get: { mode },
                    set: { state.project.background = .image(path: path, mode: $0) }
                )) {
                    Text("Expandida").tag(BackgroundStyle.ImageMode.fill)
                    Text("Adaptada").tag(BackgroundStyle.ImageMode.fit)
                    Text("Estirada").tag(BackgroundStyle.ImageMode.stretch)
                    Text("Mosaico").tag(BackgroundStyle.ImageMode.tile)
                    Text("Centrada").tag(BackgroundStyle.ImageMode.center)
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var backgroundKind: Int {
        switch state.project.background {
        case .color: return 0
        case .gradient: return 1
        case .image: return 2
        }
    }

    private func setBackgroundKind(_ kind: Int) {
        switch kind {
        case 0: state.project.background = .color(RGBA(r: 0.07, g: 0.09, b: 0.13))
        case 1: state.project.background = .gradient(top: RGBA(r: 0.1, g: 0.15, b: 0.3),
                                                     bottom: RGBA(r: 0.02, g: 0.03, b: 0.08))
        default: chooseBackgroundImage(mode: .fill)
        }
    }

    private func chooseBackgroundImage(mode: BackgroundStyle.ImageMode) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        if panel.runModal() == .OK, let url = panel.url {
            // Si la ruta estuvo ausente y reaparece, el compositor debe
            // reintentarla en vez de recordarla como perdida.
            FrameComposer.forgetMissing(url.path)
            state.project.background = .image(path: url.path, mode: mode)
        }
    }

    private func colorRow(_ label: String, _ color: RGBA,
                          set: @escaping (RGBA) -> Void) -> some View {
        ColorPicker(label, selection: Binding(
            get: { Color(red: color.r, green: color.g, blue: color.b, opacity: color.a) },
            set: { new in
                let ns = NSColor(new).usingColorSpace(.deviceRGB) ?? .black
                set(RGBA(r: ns.redComponent, g: ns.greenComponent,
                         b: ns.blueComponent, a: ns.alphaComponent))
            }
        ))
        .font(.caption)
    }

    private func slider(_ label: String, value: Binding<Double>,
                        in range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
        }
    }
}


