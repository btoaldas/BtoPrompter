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
