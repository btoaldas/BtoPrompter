import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Piezas del editor de composición para la fase de capas: el selector de
// proyectos, la sección de fuentes propias y el panel de N capas del usuario
// (vídeos e imágenes con su orden, su geometría y sus tiempos).

// MARK: - Selector de proyectos

// Lista de todas las grabaciones/proyectos, no solo el último. Doble clic
// abre; también se puede abrir cualquier carpeta o montar un proyecto desde
// vídeos sueltos (sin copiarlos: se referencian donde estén).
struct ProjectPickerView: View {
    struct Entry: Identifiable {
        let id = UUID()
        let folder: URL
        let hasCamera: Bool
        let hasScreen: Bool
        let hasProject: Bool
    }

    let onOpen: (URL) -> Void
    @State private var entries: [Entry] = []

    var body: some View {
        VStack(spacing: 0) {
            List(entries) { e in
                HStack {
                    Image(systemName: e.hasProject ? "film.stack" : "film")
                        .foregroundStyle(e.hasProject ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.folder.lastPathComponent).font(.system(size: 13, weight: .semibold))
                        Text([e.hasCamera ? "cámara" : nil,
                              e.hasScreen ? "pantalla" : nil,
                              e.hasProject ? "proyecto guardado" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Abrir") { onOpen(e.folder) }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onOpen(e.folder) }
            }
            .overlay {
                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "film")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("Aún no hay grabaciones").font(.headline)
                        Text("Graba desde Ajustes → Grabación, o monta un proyecto "
                             + "con «Nuevo desde vídeos…»")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                    }
                }
            }
            HStack {
                Button("Otra carpeta…") { pickFolder() }
                Button("Nuevo desde vídeos…") { newFromVideos() }
                    .help("Elige uno o varios vídeos tuyos: el primero será la base "
                          + "y el resto entran como capas. No se copian, se referencian.")
                Spacer()
                Text("\(entries.count) grabaciones")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .frame(width: 460, height: 380)
        .onAppear { load() }
    }

    private func load() {
        let base = RecordingEngine.baseFolder
        let fm = FileManager.default
        // Orden por fecha real, no por nombre: los proyecto-* empiezan por
        // letra y por nombre quedarían siempre arriba, enterrando la
        // grabación más reciente.
        let folders = ((try? fm.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted {
                ((try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast)
            }
        entries = folders.compactMap { folder in
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
                return nil
            }
            let cam = files.contains { $0.lastPathComponent.hasPrefix("camara-") }
            let scr = files.contains { $0.lastPathComponent.hasPrefix("pantalla-") }
            let proj = files.contains { $0.lastPathComponent == "project.json" }
            guard cam || scr || proj else { return nil }
            return Entry(folder: folder, hasCamera: cam, hasScreen: scr, hasProject: proj)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Abrir carpeta"
        if panel.runModal() == .OK, let url = panel.url { onOpen(url) }
    }

    // Proyecto desde vídeos sueltos: el primero es la base (fuente pantalla),
    // los demás capas. La carpeta del proyecto solo guarda el project.json.
    private func newFromVideos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "Montar proyecto"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let stamp = RecordingEngine.timestamp()
        let folder = RecordingEngine.baseFolder.appendingPathComponent("proyecto-\(stamp)",
                                                                       isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            let alert = NSAlert()
            alert.messageText = "No se pudo crear el proyecto"
            alert.informativeText = "\(folder.path)\n\(error.localizedDescription)"
            alert.runModal()
            return
        }
        var project = VideoProject()
        project.layouts = [SegmentLayout(mode: .onlyScreen)]
        project.screenOverridePath = panel.urls[0].path
        for url in panel.urls.dropFirst() {
            var layer = ExtraLayer(kind: .video, path: url.path,
                                   name: url.deletingPathExtension().lastPathComponent)
            layer.rect = NRect(x: 0.6, y: 0.55, width: 0.36, height: 0.4)
            project.extraLayers.append(layer)
        }
        VideoProjectStore.save(project, folder: folder)
        onOpen(folder)
    }
}

// MARK: - Fuentes propias

// Sustituir la cámara o la pantalla grabadas por un vídeo del usuario (o
// aportarlas si no existen). Cambiarlas reconstruye la composición.
struct SourceOverrideSection: View {
    @ObservedObject var state: VideoProjectState
    let discoveredCamera: String?
    let discoveredScreen: String?
    let onStructureChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fuentes").font(.caption).foregroundStyle(.secondary)
            sourceRow(label: "Cámara", override: state.project.cameraOverridePath,
                      recorded: discoveredCamera) { path in
                state.project.cameraOverridePath = path
                onStructureChange()
            }
            sourceRow(label: "Pantalla", override: state.project.screenOverridePath,
                      recorded: discoveredScreen) { path in
                state.project.screenOverridePath = path
                onStructureChange()
            }
        }
    }

    private func sourceRow(label: String, override: String?, recorded: String?,
                           set: @escaping (String?) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).frame(width: 55, alignment: .leading)
            Text(override.map { URL(fileURLWithPath: $0).lastPathComponent }
                 ?? recorded ?? "—")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(override != nil ? Color.accentColor : .secondary)
            Spacer()
            Button("Cambiar…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
                if panel.runModal() == .OK, let url = panel.url { set(url.path) }
            }
            .font(.system(size: 10))
            if override != nil {
                Button("Grabada") { set(nil) }
                    .font(.system(size: 10))
                    .help("Volver al archivo grabado")
            }
        }
    }
}

// MARK: - Panel de capas

// N capas de vídeo o imagen: orden (la última se dibuja encima), posición,
// tamaño, escalado/deformado/recorte, forma, opacidad y TIEMPOS de aparición.
struct LayersSection: View {
    @ObservedObject var state: VideoProjectState
    @Binding var playhead: Double
    let onStructureChange: () -> Void


    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Capas (\(state.project.extraLayers.count))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("＋ Vídeo") { addLayer(kind: .video) }.font(.system(size: 10))
                Button("＋ Imagen") { addLayer(kind: .image) }.font(.system(size: 10))
            }

            ForEach(Array(state.project.extraLayers.enumerated()), id: \.element.id) { i, layer in
                layerRow(i, layer)
            }

            if let sel = state.selectedLayerID,
               let idx = state.project.extraLayers.firstIndex(where: { $0.id == sel }) {
                layerControls(idx)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.15)))
            }
        }
    }

    private func layerRow(_ i: Int, _ layer: ExtraLayer) -> some View {
        HStack(spacing: 6) {
            Image(systemName: layer.kind == .video ? "video" : "photo")
                .font(.system(size: 10))
            Text(layer.name).font(.caption).lineLimit(1)
            if !FileManager.default.fileExists(atPath: layer.path) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9)).foregroundStyle(.orange)
                    .help("El archivo ya no está en \(layer.path)")
            }
            Spacer()
            // Orden z: subir dibuja más tarde = más arriba.
            Button(action: { move(i, by: 1) }) { Image(systemName: "square.2.layers.3d.top.filled") }
                .buttonStyle(.plain).font(.system(size: 10))
                .disabled(i == state.project.extraLayers.count - 1)
                .help("Traer más al frente")
            Button(action: { move(i, by: -1) }) { Image(systemName: "square.2.layers.3d.bottom.filled") }
                .buttonStyle(.plain).font(.system(size: 10))
                .disabled(i == 0)
                .help("Enviar más atrás")
            Button(action: { remove(i) }) { Image(systemName: "trash") }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.red)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(state.selectedLayerID == layer.id ? Color.accentColor.opacity(0.25) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { state.selectedLayerID = layer.id }
    }

    // Controles de la capa seleccionada.
    private func layerControls(_ idx: Int) -> some View {
        func bind<T>(_ kp: WritableKeyPath<ExtraLayer, T>) -> Binding<T> {
            Binding(
                get: { state.project.extraLayers[idx][keyPath: kp] },
                set: { v in
                    var p = state.project
                    guard idx < p.extraLayers.count else { return }
                    p.extraLayers[idx][keyPath: kp] = v
                    state.project = p
                }
            )
        }
        let layer = state.project.extraLayers[idx]

        return VStack(alignment: .leading, spacing: 5) {
            miniSlider("Horizontal", bind(\.rect.x), 0...0.97)
            miniSlider("Vertical", bind(\.rect.y), 0...0.97)
            miniSlider("Ancho", bind(\.rect.width), 0.03...1)
            miniSlider("Alto", bind(\.rect.height), 0.03...1)
            Picker("Ajuste", selection: bind(\.settings.fit)) {
                Text("Llenar").tag(SourceFit.fill)
                Text("Encajar").tag(SourceFit.fit)
                Text("Deformar").tag(SourceFit.stretch)
                Text("Recorte manual").tag(SourceFit.crop)
            }
            .pickerStyle(.menu).font(.system(size: 11))
            if layer.settings.fit == .crop {
                miniSlider("Recorte izq.", bind(\.settings.crop.x), 0...0.95)
                miniSlider("Recorte arriba", bind(\.settings.crop.y), 0...0.95)
                miniSlider("Recorte ancho", bind(\.settings.crop.width), 0.05...1)
                miniSlider("Recorte alto", bind(\.settings.crop.height), 0.05...1)
            }
            Picker("Forma", selection: bind(\.shape)) {
                Text("Rectángulo").tag(SegmentLayout.Shape.rect)
                Text("Redondeada").tag(SegmentLayout.Shape.rounded)
                Text("Círculo").tag(SegmentLayout.Shape.circle)
            }
            .pickerStyle(.segmented)
            miniSlider("Opacidad", bind(\.opacity), 0.05...1)
            miniSlider("Borde", bind(\.borderWidth), 0...0.05)
            Toggle("Detrás de la cámara flotante", isOn: bind(\.behindCamera))
                .font(.system(size: 11))

            appearancesEditor(idx)
        }
    }

    // Los TIEMPOS: cuándo se ve la capa. Sin intervalos = siempre visible.
    private func appearancesEditor(_ idx: Int) -> some View {
        let layer = state.project.extraLayers[idx]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(layer.appearances.isEmpty
                     ? "Visible todo el vídeo"
                     : "Apariciones")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("＋ desde el cursor") {
                    mutate(idx) { l in
                        let end = min(state.project.duration, playhead + 5)
                        l.appearances.append(LayerAppearance(from: playhead, to: end))
                    }
                }
                .font(.system(size: 10))
                .help("Añade un intervalo que empieza donde está el cursor")
            }
            ForEach(Array(layer.appearances.enumerated()), id: \.offset) { ai, a in
                HStack(spacing: 4) {
                    Text("de").font(.system(size: 10))
                    numField(value: a.from) { v in
                        // El clamp evita intervalos invertidos que el saneo
                        // borraría en silencio al guardar.
                        mutateAppearance(idx, ai) { $0.from = min(max(0, v), $0.to - 0.1) }
                    }
                    Text("a").font(.system(size: 10))
                    numField(value: a.to) { v in
                        mutateAppearance(idx, ai) { a2 in
                            let top = state.project.duration > 0 ? state.project.duration : v
                            a2.to = max(min(v, top), a2.from + 0.1)
                        }
                    }
                    Text("s").font(.system(size: 10)).foregroundStyle(.secondary)
                    Button("cursor→fin") {
                        mutateAppearance(idx, ai) { $0.to = playhead }
                    }
                    .font(.system(size: 9))
                    .disabled(playhead <= a.from)
                    .help("Cierra este intervalo donde está el cursor")
                    Spacer()
                    Button(action: {
                        mutate(idx) { l in
                            if ai < l.appearances.count { l.appearances.remove(at: ai) }
                        }
                    }) {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain).font(.system(size: 10))
                }
            }
        }
    }

    private func numField(value: Double, set: @escaping (Double) -> Void) -> some View {
        TextField("", text: Binding(
            get: { String(format: "%.1f", value) },
            set: { s in if let v = Double(s.replacingOccurrences(of: ",", with: ".")) { set(v) } }
        ))
        .frame(width: 44)
        .font(.system(size: 10, design: .monospaced))
        .textFieldStyle(.roundedBorder)
    }

    private func mutate(_ idx: Int, _ change: (inout ExtraLayer) -> Void) {
        var p = state.project
        guard idx < p.extraLayers.count else { return }
        let wasVideo = p.extraLayers[idx].kind == .video
        let anchorBefore = p.extraLayers[idx].firstAppearance
        change(&p.extraLayers[idx])
        state.project = p
        // La pista de un vídeo está anclada a su primera aparición: si el
        // ancla cambió, hay que reconstruir la composición (con calma: los
        // campos numéricos disparan por tecla).
        if wasVideo, idx < p.extraLayers.count,
           p.extraLayers[idx].firstAppearance != anchorBefore {
            scheduleStructureChange()
        }
    }

    @State private var structureWork: DispatchWorkItem? = nil

    private func scheduleStructureChange() {
        structureWork?.cancel()
        let work = DispatchWorkItem { onStructureChange() }
        structureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // Doble guardia: la fila de una aparición puede quedar obsoleta si el
    // saneo o otro control encogió el array (índice muerto = crash).
    private func mutateAppearance(_ idx: Int, _ ai: Int,
                                  _ change: (inout LayerAppearance) -> Void) {
        var p = state.project
        guard idx < p.extraLayers.count, ai < p.extraLayers[idx].appearances.count else { return }
        let wasVideo = p.extraLayers[idx].kind == .video
        let anchorBefore = p.extraLayers[idx].firstAppearance
        change(&p.extraLayers[idx].appearances[ai])
        state.project = p
        if wasVideo, p.extraLayers[idx].firstAppearance != anchorBefore {
            scheduleStructureChange()
        }
    }

    private func addLayer(kind: ExtraLayer.Kind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = kind == .video
            ? [.movie, .mpeg4Movie, .quickTimeMovie]
            : [.png, .jpeg, .heic, .tiff, .gif]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FrameComposer.forgetMissing(url.path)
        var layer = ExtraLayer(kind: kind, path: url.path,
                               name: url.deletingPathExtension().lastPathComponent)
        layer.rect = NRect(x: 0.6, y: 0.55, width: 0.34, height: 0.36)
        var p = state.project
        p.extraLayers.append(layer)
        state.project = p
        state.selectedLayerID = layer.id
        // Un vídeo nuevo necesita pista propia: reconstruir la composición.
        if kind == .video { onStructureChange() }
    }

    private func remove(_ i: Int) {
        var p = state.project
        guard i < p.extraLayers.count else { return }
        let wasVideo = p.extraLayers[i].kind == .video
        if state.selectedLayerID == p.extraLayers[i].id { state.selectedLayerID = nil }
        p.extraLayers.remove(at: i)
        state.project = p
        if wasVideo { onStructureChange() }
    }

    private func move(_ i: Int, by delta: Int) {
        var p = state.project
        let j = i + delta
        guard i >= 0, i < p.extraLayers.count, j >= 0, j < p.extraLayers.count else { return }
        p.extraLayers.swapAt(i, j)
        state.project = p
    }

    private func miniSlider(_ label: String, _ value: Binding<Double>,
                            _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).frame(width: 88, alignment: .leading)
            Slider(value: value, in: range)
        }
    }
}

// MARK: - Capas de audio

// Música de fondo, efectos, cualquier audio del usuario: volumen, recorte del
// archivo (desde qué segundo se lee) y posición en el proyecto. El volumen
// del micrófono (audio de la cámara) también vive aquí.
struct AudioSection: View {
    @ObservedObject var state: VideoProjectState
    @StateObject private var voiceover = VoiceoverRecorder()
    @Binding var playhead: Double
    let onStructureChange: () -> Void
    // Dónde estaba el cursor al empezar la toma: ahí se inserta la voz.
    @State private var voiceoverStart: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Audio").font(.caption).foregroundStyle(.secondary)
                Spacer()
                voiceoverButton
                Button("＋ Audio") { addAudio() }.font(.system(size: 10))
            }
            if let s = voiceover.status {
                Text(s).font(.caption2).foregroundStyle(.orange)
            }
            if hasSystemAudio {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Button(cleaning ? "Limpiando…" : "Probar limpieza del micrófono") {
                            cleanMicrophone()
                        }
                        .font(.system(size: 10))
                        .disabled(cleaning)
                        .help("Prueba a restar del micrófono lo que sonaba en el Mac. "
                              + "Crea una PISTA NUEVA; tu grabación original no se toca "
                              + "y puedes volver a ella cuando quieras.")
                        // Deshacer: la limpieza es una prueba, no un camino sin vuelta.
                        if hasCleanTrack {
                            Button("Volver al original") { revertClean() }
                                .font(.system(size: 10))
                                .help("Quita la pista limpia y devuelve el micrófono de la grabación")
                        }
                        if let s = cleanStatus {
                            Text(s).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("Opcional. El archivo original nunca se modifica: la voz limpia "
                         + "se guarda aparte y puedes comparar y volver atrás.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Image(systemName: "mic").font(.system(size: 10))
                Text("Micrófono").font(.caption)
                Slider(value: Binding(
                    get: { state.project.micVolume },
                    set: { v in state.project.micVolume = v; scheduleRebuild() }
                ), in: 0...1)
                Text("\(Int(state.project.micVolume * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .frame(width: 32)
            }
            HStack {
                Image(systemName: "speaker.wave.2").font(.system(size: 10))
                Text("Sistema").font(.caption)
                Slider(value: Binding(
                    get: { state.project.screenAudioVolume },
                    set: { v in state.project.screenAudioVolume = v; scheduleRebuild() }
                ), in: 0...1)
                Text("\(Int(state.project.screenAudioVolume * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .frame(width: 32)
            }
            .help("El sonido del Mac grabado con la pantalla (actívalo en Ajustes → "
                  + "Grabación). Independiente del micrófono: puedes ver el escritorio "
                  + "con solo el audio de la webcam, o al revés.")
            ForEach(Array(state.project.audioLayers.enumerated()), id: \.element.id) { i, audio in
                audioRow(i, audio)
            }
        }
    }

    private func audioRow(_ i: Int, _ audio: AudioLayer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "music.note").font(.system(size: 10))
                Text(audio.name).font(.caption).lineLimit(1)
                if !FileManager.default.fileExists(atPath: audio.path) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                }
                Spacer()
                Button(action: { removeAudio(i) }) { Image(systemName: "trash") }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.red)
            }
            HStack(spacing: 4) {
                Text("Vol").font(.system(size: 9))
                Slider(value: bindAudio(i, \.volume), in: 0...1).frame(width: 70)
                Text("archivo desde").font(.system(size: 9))
                numText(bindAudio(i, \.sourceStart))
                Text("s · en el vídeo desde").font(.system(size: 9))
                numText(bindAudio(i, \.projectStart))
                Text("s").font(.system(size: 9))
            }
            HStack(spacing: 4) {
                Text("duración").font(.system(size: 9))
                numText(bindAudio(i, \.duration))
                Text("s (0 = hasta el final)").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.12)))
    }

    // Cambios de audio SIEMPRE reconstruyen (las pistas y el mix viven en la
    // composición), con calma para no reconstruir por cada tick de slider.
    @State private var rebuildWork: DispatchWorkItem? = nil

    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { onStructureChange() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func bindAudio(_ i: Int, _ kp: WritableKeyPath<AudioLayer, Double>) -> Binding<Double> {
        Binding(
            get: {
                guard i < state.project.audioLayers.count else { return 0 }
                return state.project.audioLayers[i][keyPath: kp]
            },
            set: { v in
                var p = state.project
                guard i < p.audioLayers.count else { return }
                p.audioLayers[i][keyPath: kp] = v
                state.project = p
                scheduleRebuild()
            }
        )
    }

    private func numText(_ value: Binding<Double>) -> some View {
        TextField("", text: Binding(
            get: { String(format: "%.1f", value.wrappedValue) },
            set: { s in
                if let v = Double(s.replacingOccurrences(of: ",", with: ".")) {
                    value.wrappedValue = max(0, v)
                }
            }
        ))
        .frame(width: 42)
        .font(.system(size: 9, design: .monospaced))
        .textFieldStyle(.roundedBorder)
    }

    // Narrar sobre el vídeo: graba del micrófono y al parar la toma entra
    // como capa de audio posicionada donde estaba el cursor al empezar.
    private var voiceoverButton: some View {
        Button(action: { toggleVoiceover() }) {
            if voiceover.isRecording {
                HStack(spacing: 3) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text(String(format: "%.0f s — parar", voiceover.elapsed))
                }
            } else {
                Label("Voz en off", systemImage: "mic.badge.plus")
            }
        }
        .font(.system(size: 10))
        .tint(voiceover.isRecording ? .red : nil)
        .help(voiceover.isRecording
              ? "Parar la toma: entrará como capa de audio donde estaba el cursor"
              : "Grabar una voz en off desde el micrófono, insertada donde está el cursor")
    }

    private func toggleVoiceover() {
        if voiceover.isRecording {
            guard let url = voiceover.stop() else { return }
            var layer = AudioLayer(path: url.path,
                                   name: url.deletingPathExtension().lastPathComponent)
            layer.volume = 1.0
            layer.projectStart = voiceoverStart
            var p = state.project
            p.audioLayers.append(layer)
            state.project = p
            onStructureChange()
        } else {
            voiceoverStart = playhead
            _ = voiceover.start(inFolder: state.folder)
        }
    }

    @State private var cleaning = false
    @State private var cleanStatus: String? = nil

    // ¿Hay ya una pista de voz limpia en el proyecto?
    private var hasCleanTrack: Bool {
        state.project.audioLayers.contains {
            URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix("voz-limpia")
        }
    }

    // Deshacer la prueba: fuera la pista limpia, vuelve el micrófono original.
    // El archivo voz-limpia.wav se queda en la carpeta por si quiere volver a
    // usarlo; lo que no se toca NUNCA es la grabación de cámara.
    private func revertClean() {
        var p = state.project
        p.audioLayers.removeAll {
            URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix("voz-limpia")
        }
        p.micVolume = 1
        state.project = p
        cleanStatus = "Micrófono original restaurado"
        onStructureChange()
    }

    private var hasSystemAudio: Bool {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: state.folder, includingPropertiesForKeys: nil)) ?? []
        return files.contains { $0.lastPathComponent.hasPrefix("pantalla-") }
    }

    // Quita del micrófono el sonido del Mac usando la pista digital de la
    // pantalla como referencia. La voz limpia entra como capa de audio y el
    // micrófono original se baja a cero (reversible con su deslizador).
    private func cleanMicrophone() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: state.folder, includingPropertiesForKeys: nil)) ?? []
        guard let mic = CompositionBuilder.primaryFile(prefix: "camara-", in: files),
              let ref = CompositionBuilder.primaryFile(prefix: "pantalla-", in: files) else {
            cleanStatus = "Hacen falta la cámara y la pantalla"
            return
        }
        // Con cortes la limpieza aún no sabe de partes: limpiaría solo la
        // parte 1 y al silenciar el micrófono ENMUDECERÍA la voz del resto
        // de la toma. Mejor negarse con la verdad que romper el audio.
        if let src = CompositionBuilder.sources(inFolder: state.folder),
           src.cameraParts.count > 1 || src.screenParts.count > 1 {
            cleanStatus = "Esta toma tuvo cortes: la limpieza aún no funciona "
                + "con partes (dejaría sin voz todo lo posterior al corte)"
            return
        }
        cleaning = true
        cleanStatus = "Analizando…"
        // Nombre libre: una limpieza nueva no pisa la anterior, por si quiere
        // comparar dos intentos.
        var n = 1
        var out = state.folder.appendingPathComponent("voz-limpia.wav")
        while FileManager.default.fileExists(atPath: out.path) {
            n += 1
            out = state.folder.appendingPathComponent("voz-limpia-\(n).wav")
        }
        let folder = state.folder
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try AudioEchoRemover.removeSystemAudio(
                    micURL: mic, referenceURL: ref, outputURL: out)
                DispatchQueue.main.async {
                    cleaning = false
                    var layer = AudioLayer(path: r.outputURL.path, name: "voz limpia")
                    layer.volume = 1
                    // Arranca donde arrancaba el micrófono original: la voz
                    // limpia sale del mismo archivo, así que comparte reloj.
                    layer.projectStart = 0
                    var p = state.project
                    p.audioLayers.append(layer)
                    p.micVolume = 0
                    state.project = p
                    cleanStatus = String(format: "%.0f dB menos · compara y decide",
                                         -r.reductionDB)
                    onStructureChange()
                    _ = folder
                }
            } catch {
                DispatchQueue.main.async {
                    cleaning = false
                    cleanStatus = error.localizedDescription
                }
            }
        }
    }

    private func addAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var layer = AudioLayer(path: url.path,
                               name: url.deletingPathExtension().lastPathComponent)
        layer.projectStart = playhead
        var p = state.project
        p.audioLayers.append(layer)
        state.project = p
        onStructureChange()
    }

    private func removeAudio(_ i: Int) {
        var p = state.project
        guard i < p.audioLayers.count else { return }
        p.audioLayers.remove(at: i)
        state.project = p
        onStructureChange()
    }
}

// MARK: - Subtítulos

// Activables, con dos orígenes (el propio teleprompter o un SRT) y estilo
// completo: modelos con nombre, posición, filas, ancho, tamaño y caja.
struct SubtitleSection: View {
    @ObservedObject var state: VideoProjectState

    private var track: SubtitleTrack {
        state.project.subtitles ?? SubtitleTrack(enabled: false)
    }

    private func setTrack(_ t: SubtitleTrack?) {
        state.project.subtitles = t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Subtítulos").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { state.project.subtitles?.enabled ?? false },
                    set: { on in
                        var t = track
                        t.enabled = on
                        setTrack(t)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            HStack(spacing: 6) {
                if hasPrompterTrack {
                    Button("Del teleprompter") {
                        var t = track
                        t.chunks = SubtitleBuilder.fromRecording(folder: state.folder)
                        t.enabled = !t.chunks.isEmpty
                        setTrack(t)
                    }
                    .font(.system(size: 10))
                    .help("Genera las frases desde lo que el teleprompter marcó al grabar")
                }
                Button("Transcribir el audio") { transcribeAudio() }
                    .font(.system(size: 10))
                    .disabled(transcriber.running)
                    .help("Sin teleprompter: escucha la grabación y arma los "
                          + "subtítulos con los tiempos de cada palabra")
                Button("Archivo SRT…") { importSRT() }
                    .font(.system(size: 10))
                if !track.chunks.isEmpty {
                    Text("\(track.chunks.count) frases")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if state.project.subtitles?.enabled == true {
                Toggle("Quemar en el vídeo (si no, salen como .srt separado)", isOn: Binding(
                    get: { track.burnIn },
                    set: { v in var t2 = track; t2.burnIn = v; setTrack(t2) }
                ))
                .font(.system(size: 11))
                aiRow
                silenceRow
                stylePickers
            }
        }
    }

    @StateObject private var dubbing = DubbingEngine.shared
    @State private var aiBusy = false
    @State private var aiStatus: String? = nil

    // Traducir (SRT por idioma, listos para YouTube), refinar el texto con la
    // IA configurada, o DOBLAR el audio (traducción + TTS frase a frase).
    private var aiRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Menu("Traducir…") {
                    ForEach(SubtitleAI.languages, id: \.code) { lang in
                        Button(lang.name) { translate(to: [lang]) }
                    }
                    Divider()
                    Button("Los 10 idiomas") { translate(to: SubtitleAI.languages) }
                }
                .font(.system(size: 10))
                .disabled(aiBusy || track.chunks.isEmpty)

                Button("Refinar con IA") { refine() }
                    .font(.system(size: 10))
                    .disabled(aiBusy || track.chunks.isEmpty)

                Menu("Doblar…") {
                    ForEach(SubtitleAI.languages, id: \.code) { lang in
                        Button(lang.name) { dub(lang) }
                    }
                }
                .font(.system(size: 10))
                .disabled(dubbing.running || track.chunks.isEmpty)
            }
            if aiBusy, let s = aiStatus {
                Text(s).font(.caption2).foregroundStyle(.secondary)
            }
            if let s = aiStatus, !aiBusy {
                Text(s).font(.caption2).foregroundStyle(.orange)
            }
            if dubbing.running {
                Text(dubbing.progress).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func translate(to langs: [(code: String, name: String)]) {
        guard let config = SubtitleAI.ProviderConfig.current() else {
            aiStatus = "Configura un proveedor de IA en Ajustes → Ensayo IA"
            return
        }
        aiBusy = true
        var remaining = langs
        func next() {
            guard let lang = remaining.first else {
                aiBusy = false
                aiStatus = "Traducciones guardadas junto al proyecto (.srt por idioma)"
                return
            }
            remaining.removeFirst()
            aiStatus = "Traduciendo al \(lang.name)…"
            SubtitleAI.translate(track.chunks, to: lang.name, config: config) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let translated):
                        let srt = SubtitleBuilder.toSRT(translated)
                        let url = state.folder.appendingPathComponent("subtitulos.\(lang.code).srt")
                        try? srt.write(to: url, atomically: true, encoding: .utf8)
                    case .failure(let error):
                        aiStatus = "\(lang.name): \(error.localizedDescription)"
                    }
                    next()
                }
            }
        }
        next()
    }

    private func refine() {
        guard let config = SubtitleAI.ProviderConfig.current() else {
            aiStatus = "Configura un proveedor de IA en Ajustes → Ensayo IA"
            return
        }
        aiBusy = true
        aiStatus = "Refinando \(track.chunks.count) frases…"
        SubtitleAI.refine(track.chunks, config: config) { result in
            DispatchQueue.main.async {
                aiBusy = false
                switch result {
                case .success(let refined):
                    var t2 = track
                    t2.chunks = refined
                    setTrack(t2)
                    aiStatus = nil
                case .failure(let error):
                    aiStatus = error.localizedDescription
                }
            }
        }
    }

    private func dub(_ lang: (code: String, name: String)) {
        // El costo es real (una llamada de TTS por frase): confirmar antes.
        let alert = NSAlert()
        alert.messageText = "Doblar al \(lang.name)"
        alert.informativeText = "Se traducirán \(track.chunks.count) frases y se sintetizará "
            + "cada una con el proveedor de voz de Ajustes → Lectura "
            + "(\(track.chunks.count) llamadas). Las frases dobladas entran como capas de "
            + "audio y el micrófono original se baja a cero (puedes devolverlo)."
        alert.addButton(withTitle: "Doblar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DubbingEngine.shared.dub(chunks: track.chunks, language: lang,
                                 folder: state.folder) { result in
            switch result {
            case .success(let layers):
                var p = state.project
                p.audioLayers.append(contentsOf: layers)
                p.micVolume = 0
                state.project = p
                aiStatus = "Doblaje listo: \(layers.count) frases como capas de audio"
                NotificationCenter.default.post(name: .init("BtoPrompterRebuild"), object: nil)
            case .failure(let error):
                aiStatus = error.localizedDescription
            }
        }
    }

    @StateObject private var transcriber = SubtitleTranscriber.shared

    // Transcribe el audio de la grabación: subtítulos sin haber leído guion.
    // Con cortes se transcribe CADA parte y sus tiempos se corren al instante
    // real de la parte en el montaje; antes solo salía la parte 1 y los
    // subtítulos morían en el primer hueco.
    private func transcribeAudio() {
        if let src = CompositionBuilder.sources(inFolder: state.folder) {
            let parts = !src.cameraParts.isEmpty ? src.cameraParts : src.screenParts
            if parts.count > 1 {
                var named: [Double] = []
                if !src.cameraParts.isEmpty { named.append(src.cameraOffset) }
                if !src.screenParts.isEmpty { named.append(src.screenOffset) }
                transcribeParts(parts, latest: named.max() ?? 0)
                return
            }
        }
        guard let audio = SubtitleTranscriber.bestAudioSource(inFolder: state.folder) else {
            aiStatus = "No se encontró audio en esta grabación"
            return
        }
        aiStatus = "Transcribiendo…"
        transcriber.transcribe(url: audio) { result in
            switch result {
            case .success(let chunks):
                var t2 = track
                t2.chunks = chunks
                t2.enabled = true
                setTrack(t2)
                aiStatus = "\(chunks.count) frases desde el audio"
            case .failure(let error):
                aiStatus = error.localizedDescription
            }
        }
    }

    // Una parte tras otra (el transcriptor es de a uno), acumulando frases
    // ya corridas al reloj del montaje.
    private func transcribeParts(_ parts: [CompositionBuilder.SourcePart], latest: Double) {
        aiStatus = "Transcribiendo \(parts.count) partes…"
        var all: [SubtitleChunk] = []
        var failures = 0
        func next(_ i: Int) {
            guard i < parts.count else {
                guard !all.isEmpty else {
                    aiStatus = "No se pudo transcribir ninguna parte"
                    return
                }
                var t2 = track
                t2.chunks = all.sorted { $0.from < $1.from }
                t2.enabled = true
                setTrack(t2)
                aiStatus = "\(all.count) frases desde el audio (\(parts.count) partes"
                    + (failures > 0 ? ", \(failures) fallaron)" : ")")
                return
            }
            let part = parts[i]
            aiStatus = "Transcribiendo parte \(i + 1) de \(parts.count)…"
            let shift = part.offset - latest
            transcriber.transcribe(url: part.url) { result in
                if case .success(let chunks) = result {
                    all.append(contentsOf: chunks.map { c in
                        var c2 = c
                        c2.from = max(0, c.from + shift)
                        c2.to = max(c2.from, c.to + shift)
                        return c2
                    })
                } else {
                    failures += 1
                }
                next(i + 1)
            }
        }
        next(0)
    }

    @State private var silenceStatus: String? = nil

    // Los huecos sin voz se convierten en cortes: quedan marcados en la línea
    // de tiempo para revisarlos y quitarlos, en vez de buscarlos a mano.
    private var silenceRow: some View {
        HStack(spacing: 6) {
            Button("Marcar los silencios") { markSilences() }
                .font(.system(size: 10))
                .disabled(track.chunks.isEmpty)
                .help("Pone un corte donde nadie habló más de segundo y medio, "
                      + "para que puedas revisarlos y quitarlos")
            if let s = silenceStatus {
                Text(s).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func markSilences() {
        let huecos = SubtitleBuilder.silences(in: track.chunks,
                                              duration: state.project.duration)
        guard !huecos.isEmpty else {
            silenceStatus = "No hay silencios largos"
            return
        }
        var p = state.project
        var puestos = 0
        for h in huecos {
            if p.addCut(at: h.from) != nil { puestos += 1 }
            if p.addCut(at: h.to) != nil { puestos += 1 }
        }
        state.project = p
        silenceStatus = "\(huecos.count) silencios · \(puestos) cortes"
    }

    private var hasPrompterTrack: Bool {
        FileManager.default.fileExists(
            atPath: state.folder.appendingPathComponent("subtitulos.jsonl").path)
    }

    private var stylePickers: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Modelos con nombre: se aplican y se ajusta encima.
            HStack(spacing: 4) {
                ForEach(Array(SubtitleStyle.models.enumerated()), id: \.offset) { _, model in
                    Button(model.name) {
                        var t = track
                        t.style = model.style
                        setTrack(t)
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.bordered)
                }
            }
            Picker("Posición", selection: bindStyle(\.position)) {
                Text("Arriba").tag(SubtitleStyle.Position.top)
                Text("Al medio").tag(SubtitleStyle.Position.middle)
                Text("Abajo").tag(SubtitleStyle.Position.bottom)
            }
            .pickerStyle(.segmented)
            Picker("Filas", selection: bindStyle(\.maxLines)) {
                Text("Una fila").tag(1)
                Text("Dos filas").tag(2)
            }
            .pickerStyle(.segmented)
            styleSlider("Ancho", \.widthFraction, 0.5...1)
            styleSlider("Tamaño", \.fontSize, 0.02...0.12)
            styleSlider("Caja de fondo", \.boxOpacity, 0...1)
            Toggle("Sombra del texto", isOn: bindStyle(\.shadow))
                .font(.system(size: 11))
            ColorPicker("Color del texto", selection: Binding(
                get: {
                    let c = track.style.color
                    return Color(red: c.r, green: c.g, blue: c.b)
                },
                set: { new in
                    let ns = NSColor(new).usingColorSpace(.deviceRGB) ?? .white
                    var t = track
                    t.style.color = RGBA(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)
                    setTrack(t)
                }
            ))
            .font(.system(size: 11))
        }
    }

    private func bindStyle<T>(_ kp: WritableKeyPath<SubtitleStyle, T>) -> Binding<T> {
        Binding(
            get: { track.style[keyPath: kp] },
            set: { v in
                var t = track
                t.style[keyPath: kp] = v
                setTrack(t)
            }
        )
    }

    private func styleSlider(_ label: String, _ kp: WritableKeyPath<SubtitleStyle, Double>,
                             _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).frame(width: 88, alignment: .leading)
            Slider(value: bindStyle(kp), in: range)
        }
    }

    private func importSRT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .data]
        panel.prompt = "Importar SRT"
        guard panel.runModal() == .OK, let url = panel.url,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let chunks = SubtitleBuilder.parseSRT(content)
        guard !chunks.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No se encontraron subtítulos en el archivo"
            alert.informativeText = "El archivo no tiene bloques SRT válidos "
                + "(número, tiempos con -->, texto)."
            alert.runModal()
            return
        }
        var t = track
        t.chunks = chunks
        t.enabled = true
        setTrack(t)
    }
}

// MARK: - Cursor resaltado

// Halo que sigue al puntero en la grabación de pantalla. El recorrido lo
// grabó el grabador; aquí solo se enciende y se le da forma.
struct CursorSection: View {
    @ObservedObject var state: VideoProjectState

    private var track: CursorHighlight {
        state.project.cursor ?? CursorHighlight()
    }

    private var hasTrack: Bool {
        FileManager.default.fileExists(
            atPath: state.folder.appendingPathComponent("cursor.jsonl").path)
    }

    var body: some View {
        if hasTrack {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Cursor resaltado").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { state.project.cursor?.enabled ?? false },
                        set: { on in
                            var c = track
                            c.enabled = on
                            // El recorrido se carga la primera vez que se enciende.
                            if on, c.points.isEmpty {
                                c.points = CursorHighlight.fromRecording(folder: state.folder)
                            }
                            state.project.cursor = c
                        }
                    ))
                    .toggleStyle(.switch).controlSize(.mini)
                }
                if state.project.cursor?.enabled == true {
                    slider("Tamaño", \.radius, 0.005...0.15)
                    slider("Anillo", \.ringWidth, 0...0.02)
                    ColorPicker("Color", selection: Binding(
                        get: {
                            let c = track.color
                            return Color(red: c.r, green: c.g, blue: c.b).opacity(c.a)
                        },
                        set: { new in
                            let ns = NSColor(new).usingColorSpace(.deviceRGB) ?? .yellow
                            var c = track
                            c.color = RGBA(r: ns.redComponent, g: ns.greenComponent,
                                           b: ns.blueComponent, a: ns.alphaComponent)
                            state.project.cursor = c
                        }
                    ))
                    .font(.caption)
                    Text("\(track.points.count) posiciones registradas al grabar")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func slider(_ label: String, _ kp: WritableKeyPath<CursorHighlight, Double>,
                        _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).frame(width: 60, alignment: .leading)
            Slider(value: Binding(
                get: { track[keyPath: kp] },
                set: { v in var c = track; c[keyPath: kp] = v; state.project.cursor = c }
            ), in: range)
        }
    }
}

// MARK: - Teclas en pantalla

struct KeystrokeSection: View {
    @ObservedObject var state: VideoProjectState

    private var track: KeystrokeOverlay { state.project.keystrokes ?? KeystrokeOverlay() }

    private var hasTrack: Bool {
        FileManager.default.fileExists(
            atPath: state.folder.appendingPathComponent("teclas.jsonl").path)
    }

    var body: some View {
        if hasTrack {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Teclas en pantalla").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { state.project.keystrokes?.enabled ?? false },
                        set: { on in
                            var k = track
                            k.enabled = on
                            if on, k.events.isEmpty {
                                k.events = KeystrokeOverlay.fromRecording(folder: state.folder)
                            }
                            state.project.keystrokes = k
                        }
                    ))
                    .toggleStyle(.switch).controlSize(.mini)
                }
                if state.project.keystrokes?.enabled == true {
                    Picker("Esquina", selection: Binding(
                        get: { track.corner },
                        set: { v in var k = track; k.corner = v; state.project.keystrokes = k }
                    )) {
                        Text("Abajo izq.").tag(KeystrokeOverlay.Corner.bottomLeft)
                        Text("Abajo centro").tag(KeystrokeOverlay.Corner.bottomCenter)
                        Text("Abajo der.").tag(KeystrokeOverlay.Corner.bottomRight)
                        Text("Arriba izq.").tag(KeystrokeOverlay.Corner.topLeft)
                        Text("Arriba der.").tag(KeystrokeOverlay.Corner.topRight)
                    }
                    .pickerStyle(.menu).font(.system(size: 11))
                    keySlider("Duración", \.seconds, 0.4...6)
                    keySlider("Tamaño", \.size, 0.02...0.12)
                    Text("\(track.events.count) atajos registrados")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func keySlider(_ label: String, _ kp: WritableKeyPath<KeystrokeOverlay, Double>,
                           _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).frame(width: 60, alignment: .leading)
            Slider(value: Binding(
                get: { track[keyPath: kp] },
                set: { v in var k = track; k[keyPath: kp] = v; state.project.keystrokes = k }
            ), in: range)
        }
    }
}

// MARK: - Presets estilo OBS

// Guardar y aplicar presets en cuatro niveles: características de la capa
// seleccionada, componente (capa completa), escena (el tramo con sus capas)
// y plantilla del proyecto entero. Las plantillas llevan las capas como
// "demo N": al aplicarlas se pide qué archivo va en cada hueco.
struct PresetSection: View {
    @ObservedObject var state: VideoProjectState
    let onStructureChange: () -> Void

    @State private var library = VideoPresetStore.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets (estilo OBS)").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Menu("Guardar…") {
                    if let idx = selectedLayerIndex {
                        Button("Características de «\(state.project.extraLayers[idx].name)»") {
                            saveStyle(from: state.project.extraLayers[idx])
                        }
                        Button("Componente «\(state.project.extraLayers[idx].name)»") {
                            saveComponent(from: state.project.extraLayers[idx])
                        }
                    }
                    Button("Escena (tramo actual)") { saveScene() }
                    Button("Proyecto completo como plantilla") { saveTemplate() }
                }
                .font(.system(size: 10))

                Menu("Aplicar…") {
                    if !library.styles.isEmpty, selectedLayerIndex != nil {
                        Section("Características") {
                            ForEach(Array(library.styles.enumerated()), id: \.offset) { _, s in
                                Button(s.name) { applyStyle(s) }
                            }
                        }
                    }
                    if !library.components.isEmpty {
                        Section("Componentes") {
                            ForEach(Array(library.components.enumerated()), id: \.offset) { _, c in
                                Button(c.name) { applyComponent(c) }
                            }
                        }
                    }
                    if !library.scenes.isEmpty {
                        Section("Escenas (al tramo actual)") {
                            ForEach(Array(library.scenes.enumerated()), id: \.offset) { _, s in
                                Button(s.name) { applyScene(s) }
                            }
                        }
                    }
                    if !library.templates.isEmpty {
                        Section("Plantillas de proyecto") {
                            ForEach(Array(library.templates.enumerated()), id: \.offset) { _, t in
                                Button(t.name) { applyTemplate(t) }
                            }
                        }
                    }
                    if library.styles.isEmpty && library.components.isEmpty
                        && library.scenes.isEmpty && library.templates.isEmpty {
                        Text("Aún no hay presets guardados")
                    }
                }
                .font(.system(size: 10))
            }
        }
        .onAppear { library = VideoPresetStore.load() }
    }

    private var selectedLayerIndex: Int? {
        guard let id = state.selectedLayerID else { return nil }
        return state.project.extraLayers.firstIndex { $0.id == id }
    }

    // MARK: Guardar

    private func askName(_ title: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private func saveStyle(from layer: ExtraLayer) {
        guard let name = askName("Nombre del preset de características") else { return }
        library.styles.append(StylePreset(name: name, shape: layer.shape,
                                          borderWidth: layer.borderWidth,
                                          opacity: layer.opacity,
                                          fit: layer.settings.fit))
        VideoPresetStore.save(library)
    }

    private func saveComponent(from layer: ExtraLayer) {
        guard let name = askName("Nombre del preset de componente") else { return }
        let placeholder = VideoPresetStore.placeholdered([layer])[0]
        library.components.append(ComponentPreset(name: name, layer: placeholder))
        VideoPresetStore.save(library)
    }

    private func saveScene() {
        guard let name = askName("Nombre del preset de escena") else { return }
        let seg = min(state.selectedSegment, state.project.layouts.count - 1)
        library.scenes.append(ScenePreset(
            name: name,
            layout: state.project.layouts[max(0, seg)],
            layers: VideoPresetStore.placeholdered(state.project.extraLayers)))
        VideoPresetStore.save(library)
    }

    private func saveTemplate() {
        guard let name = askName("Nombre de la plantilla de proyecto") else { return }
        library.templates.append(ProjectTemplate(
            name: name,
            cuts: state.project.cuts,
            layouts: state.project.layouts,
            layers: VideoPresetStore.placeholdered(state.project.extraLayers),
            background: state.project.background,
            subtitleStyle: state.project.subtitles?.style))
        VideoPresetStore.save(library)
    }

    // MARK: Aplicar

    private func applyStyle(_ s: StylePreset) {
        guard let idx = selectedLayerIndex else { return }
        var p = state.project
        p.extraLayers[idx].shape = s.shape
        p.extraLayers[idx].borderWidth = s.borderWidth
        p.extraLayers[idx].opacity = s.opacity
        p.extraLayers[idx].settings.fit = s.fit
        state.project = p
    }

    // Por cada hueco "demo N" se pide el archivo real; cancelar = se omite.
    private func resolvePlaceholders(_ layers: [ExtraLayer]) -> [ExtraLayer] {
        var result: [ExtraLayer] = []
        for layer in layers {
            guard VideoPresetStore.isPlaceholder(layer) else {
                result.append(layer)
                continue
            }
            let panel = NSOpenPanel()
            panel.message = "Elige el archivo para «\(layer.name)» (Cancelar la omite)"
            panel.allowedContentTypes = layer.kind == .video
                ? [.movie, .mpeg4Movie, .quickTimeMovie]
                : [.png, .jpeg, .heic, .tiff, .gif]
            guard panel.runModal() == .OK, let url = panel.url else { continue }
            var l = layer
            l.id = UUID()
            l.path = url.path
            l.name = url.deletingPathExtension().lastPathComponent
            FrameComposer.forgetMissing(url.path)
            result.append(l)
        }
        return result
    }

    private func applyComponent(_ c: ComponentPreset) {
        let resolved = resolvePlaceholders([c.layer])
        guard !resolved.isEmpty else { return }
        var p = state.project
        p.extraLayers.append(contentsOf: resolved)
        state.project = p
        if resolved.contains(where: { $0.kind == .video }) { onStructureChange() }
    }

    private func applyScene(_ s: ScenePreset) {
        var p = state.project
        let seg = min(state.selectedSegment, p.layouts.count - 1)
        guard seg >= 0 else { return }
        var layout = s.layout
        layout.layerOrder = nil   // el orden guardado apunta a ids de otro proyecto
        p.layouts[seg] = layout.sanitized()
        let resolved = resolvePlaceholders(s.layers)
        p.extraLayers.append(contentsOf: resolved)
        state.project = p
        if resolved.contains(where: { $0.kind == .video }) { onStructureChange() }
    }

    private func applyTemplate(_ t: ProjectTemplate) {
        var p = state.project
        p.cuts = t.cuts
        p.layouts = t.layouts.map { l in
            var l2 = l
            l2.layerOrder = nil
            return l2
        }
        p.background = t.background
        p.extraLayers = resolvePlaceholders(t.layers)
        if let style = t.subtitleStyle {
            var track = p.subtitles ?? SubtitleTrack(enabled: false)
            track.style = style
            p.subtitles = track
        }
        state.project = p.sanitized()
        state.selectedSegment = 0
        onStructureChange()
    }
}
