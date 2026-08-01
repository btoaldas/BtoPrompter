import AppKit
import SwiftUI
import Combine
import NaturalLanguage
import Speech
import UniformTypeIdentifiers
import Carbon.HIToolbox

// MARK: - Documentos

struct SpeechDoc: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var body: String
    var folder: String = ""          // "" = raíz
    var isDraft: Bool = false
    var isArchived: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

struct Library: Codable {
    var speeches: [SpeechDoc] = []
    var folders: [String] = []
}

final class SpeechStore: ObservableObject {
    static let shared = SpeechStore()

    @Published var library = Library()
    @Published var importStatus: String? = nil

    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BtoPrompter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("speeches.json")
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let lib = try? JSONDecoder().decode(Library.self, from: data) {
            library = lib
        }
        // Migración desde la versión 1.0 (texto único en UserDefaults).
        if library.speeches.isEmpty {
            let d = UserDefaults.standard
            var old = d.string(forKey: "script") ?? ""
            if old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                old = d.string(forKey: "lastScript") ?? ""
            }
            if !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                library.speeches.append(SpeechDoc(title: "Mi discurso", body: old))
                saveNow()
            }
        }
    }

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveNow() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(library) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: CRUD

    func speech(_ id: UUID?) -> SpeechDoc? {
        guard let id else { return nil }
        return library.speeches.first(where: { $0.id == id })
    }

    func index(_ id: UUID) -> Int? {
        library.speeches.firstIndex(where: { $0.id == id })
    }

    @discardableResult
    func newSpeech(folder: String = "") -> SpeechDoc {
        let doc = SpeechDoc(title: "Nuevo discurso", body: "", folder: folder)
        library.speeches.insert(doc, at: 0)
        saveNow()
        return doc
    }

    func update(_ id: UUID, _ mutate: (inout SpeechDoc) -> Void) {
        guard let i = index(id) else { return }
        mutate(&library.speeches[i])
        library.speeches[i].updatedAt = Date()
        scheduleSave()
    }

    func delete(_ id: UUID) {
        library.speeches.removeAll(where: { $0.id == id })
        saveNow()
    }

    func addFolder(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !allFolders.contains(n) else { return }
        library.folders.append(n)
        saveNow()
    }

    func deleteFolder(_ name: String) {
        // Los discursos de la carpeta pasan a la raíz.
        for i in library.speeches.indices where library.speeches[i].folder == name {
            library.speeches[i].folder = ""
        }
        library.folders.removeAll(where: { $0 == name })
        saveNow()
    }

    var allFolders: [String] {
        let used = Set(library.speeches.map(\.folder)).subtracting([""])
        return Set(library.folders).union(used).sorted()
    }

    func speeches(inFolder folder: String, archived: Bool) -> [SpeechDoc] {
        library.speeches
            .filter { $0.folder == folder && $0.isArchived == archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var archivedSpeeches: [SpeechDoc] {
        library.speeches.filter(\.isArchived).sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Importación

    func importFiles(urls: [URL], folder: String) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let title = url.deletingPathExtension().lastPathComponent
            switch ext {
            case "txt", "md", "markdown", "text":
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    addImported(title: title, body: text, folder: folder)
                } else if let text = try? String(contentsOf: url, encoding: .isoLatin1) {
                    addImported(title: title, body: text, folder: folder)
                }
            case "pptx":
                if let text = Self.extractPPTX(url) {
                    addImported(title: title, body: text, folder: folder)
                } else {
                    importStatus = "No se pudo leer \(url.lastPathComponent)"
                }
            case "m4a", "mp3", "wav", "aac", "aiff", "caf", "flac":
                transcribeAudio(url: url, title: title, folder: folder)
            default:
                importStatus = "Formato no soportado: .\(ext)"
            }
        }
    }

    private func addImported(title: String, body: String, folder: String) {
        let doc = SpeechDoc(title: title, body: body, folder: folder)
        library.speeches.insert(doc, at: 0)
        saveNow()
        PrompterModel.shared.selectedID = doc.id
        importStatus = nil
    }

    // PPTX = ZIP con XML por diapositiva; extrae los runs de texto <a:t>.
    static func extractPPTX(_ url: URL) -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("btoprompter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", url.path, "ppt/slides/*", "-d", tmp.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        do {
            try unzip.run()
            unzip.waitUntilExit()
        } catch { return nil }
        let slidesDir = tmp.appendingPathComponent("ppt/slides")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: slidesDir.path) else { return nil }
        let slideFiles = files
            .filter { $0.hasPrefix("slide") && $0.hasSuffix(".xml") }
            .sorted { a, b in
                let na = Int(a.dropFirst(5).dropLast(4)) ?? 0
                let nb = Int(b.dropFirst(5).dropLast(4)) ?? 0
                return na < nb
            }
        guard !slideFiles.isEmpty else { return nil }
        var sections: [String] = []
        let regex = try! NSRegularExpression(pattern: "<a:t[^>]*>(.*?)</a:t>", options: [.dotMatchesLineSeparators])
        for f in slideFiles {
            guard let xml = try? String(contentsOf: slidesDir.appendingPathComponent(f), encoding: .utf8) else { continue }
            let ns = xml as NSString
            var texts: [String] = []
            regex.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m, m.numberOfRanges > 1 {
                    let raw = ns.substring(with: m.range(at: 1))
                    let decoded = raw
                        .replacingOccurrences(of: "&lt;", with: "<")
                        .replacingOccurrences(of: "&gt;", with: ">")
                        .replacingOccurrences(of: "&quot;", with: "\"")
                        .replacingOccurrences(of: "&apos;", with: "'")
                        .replacingOccurrences(of: "&amp;", with: "&")
                        .trimmingCharacters(in: .whitespaces)
                    if !decoded.isEmpty { texts.append(decoded) }
                }
            }
            guard !texts.isEmpty else { continue }
            var lines: [String] = []
            lines.append("## " + texts[0])
            lines.append(contentsOf: texts.dropFirst())
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    // Transcripción con el motor de voz del sistema (requiere autorización, una sola vez).
    private func transcribeAudio(url: URL, title: String, folder: String) {
        importStatus = "Transcribiendo \(url.lastPathComponent)…"
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.importStatus = "Autoriza el reconocimiento de voz en Ajustes del Sistema → Privacidad."
                    return
                }
                let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
                    ?? SFSpeechRecognizer()
                guard let recognizer, recognizer.isAvailable else {
                    self.importStatus = "Reconocimiento de voz no disponible en este equipo."
                    return
                }
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.shouldReportPartialResults = false
                if recognizer.supportsOnDeviceRecognition {
                    request.requiresOnDeviceRecognition = true
                }
                recognizer.recognitionTask(with: request) { result, error in
                    DispatchQueue.main.async {
                        if let result, result.isFinal {
                            self.addImported(title: title, body: result.bestTranscription.formattedString, folder: folder)
                            self.importStatus = nil
                        } else if let error {
                            self.importStatus = "Error al transcribir: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Prompter

enum ChunkStyle { case normal, h1, h2, bullet }

struct Chunk: Identifiable {
    let id: Int
    let words: [String]
    let range: Range<Int>
    let isParagraphEnd: Bool
    let style: ChunkStyle
    var isGuide: Bool = false   // se ve pero no se lee: el karaoke la salta
}

// Atajos globales del sistema (Carbon): funcionan aunque el foco esté en
// PowerPoint/Keynote/Adobe. Solo se registran mientras el prompter está activo.
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()
    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private(set) var active = false

    func register() {
        guard !active else { return }
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                DispatchQueue.main.async {
                    let m = PrompterModel.shared
                    switch hkID.id {
                    case 1: m.togglePlay()
                    case 2: m.changeSpeed(+10)
                    case 3: m.changeSpeed(-10)
                    default: break
                    }
                }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        let sig = OSType(0x42746F50) // "BtoP"
        let mods = UInt32(cmdKey | optionKey)
        let keys: [(UInt32, UInt32)] = [
            (UInt32(kVK_ANSI_P), 1),
            (UInt32(kVK_UpArrow), 2),
            (UInt32(kVK_DownArrow), 3),
        ]
        for (code, id) in keys {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(code, mods, EventHotKeyID(signature: sig, id: id),
                                GetEventDispatcherTarget(), 0, &ref)
            if let ref { refs.append(ref) }
        }
        active = true
    }

    func unregister() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
        active = false
    }
}

final class PrompterModel: ObservableObject {
    static let shared = PrompterModel()

    enum Mode { case editing, prompting }

    @Published var mode: Mode = .editing
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString ?? "", forKey: "selectedID") }
    }
    @Published var chunks: [Chunk] = []
    @Published var currentIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var wpm: Int {
        didSet { UserDefaults.standard.set(wpm, forKey: "wpm") }
    }
    @Published var fontSize: CGFloat {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }
    @Published var bgOpacity: Double {
        didSet { UserDefaults.standard.set(bgOpacity, forKey: "bgOpacity") }
    }
    // Modo espía: la ventana no aparece en capturas ni pantalla compartida.
    @Published var spyMode: Bool {
        didSet { UserDefaults.standard.set(spyMode, forKey: "spyMode") }
    }
    // Títulos (#, ##) como guías visibles que el karaoke no lee.
    @Published var guideTitles: Bool {
        didSet { UserDefaults.standard.set(guideTitles, forKey: "guideTitles") }
    }

    var totalWords: Int { chunks.last?.range.upperBound ?? 0 }

    var currentChunkID: Int? {
        chunks.first(where: { $0.range.contains(currentIndex) })?.id
    }

    var remainingTimeText: String {
        guard totalWords > 0 else { return "--:--" }
        let remaining = max(0, totalWords - currentIndex)
        let seconds = Int(Double(remaining) / Double(wpm) * 60.0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var pendingWork: DispatchWorkItem?

    private init() {
        let d = UserDefaults.standard
        wpm = d.object(forKey: "wpm") as? Int ?? 130
        fontSize = d.object(forKey: "fontSize") as? CGFloat ?? 34
        bgOpacity = d.object(forKey: "bgOpacity") as? Double ?? 0.85
        var spy = d.object(forKey: "spyMode") as? Bool ?? true
        if CommandLine.arguments.contains("--capturable") { spy = false }
        spyMode = spy
        guideTitles = d.object(forKey: "guideTitles") as? Bool ?? true
        if let s = d.string(forKey: "selectedID"), let uuid = UUID(uuidString: s) {
            selectedID = uuid
        }
    }

    // MARK: Parseo — Markdown ligero → chunks con estilo

    private func parse(_ text: String) -> [Chunk] {
        var result: [Chunk] = []
        var offset = 0
        var cid = 0
        let tokenizer = NLTokenizer(unit: .sentence)

        func stripInline(_ s: String) -> String {
            var out = s
            for marker in ["**", "__", "*", "_", "`"] {
                out = out.replacingOccurrences(of: marker, with: "")
            }
            return out
        }

        func appendChunk(_ sentence: String, style: ChunkStyle, paragraphEnd: Bool, guide: Bool = false) {
            let words = sentence.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !words.isEmpty else { return }
            // Las guías no aportan palabras leíbles: rango vacío, el karaoke las salta.
            let range = guide ? offset..<offset : offset..<(offset + words.count)
            result.append(Chunk(id: cid, words: words, range: range,
                                isParagraphEnd: paragraphEnd, style: style, isGuide: guide))
            cid += 1
            if !guide { offset += words.count }
        }

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines {
            if line.hasPrefix("//") {
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                appendChunk(stripInline(text), style: .normal, paragraphEnd: true, guide: true)
            } else if line.hasPrefix("# ") {
                appendChunk(stripInline(String(line.dropFirst(2))), style: .h1, paragraphEnd: true, guide: guideTitles)
            } else if line.hasPrefix("## ") {
                appendChunk(stripInline(String(line.dropFirst(3))), style: .h2, paragraphEnd: true, guide: guideTitles)
            } else if line.hasPrefix("### ") {
                appendChunk(stripInline(String(line.dropFirst(4))), style: .h2, paragraphEnd: true, guide: guideTitles)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                appendChunk("• " + stripInline(String(line.dropFirst(2))), style: .bullet, paragraphEnd: true)
            } else {
                let clean = stripInline(line)
                tokenizer.string = clean
                var sentences: [String] = []
                tokenizer.enumerateTokens(in: clean.startIndex..<clean.endIndex) { r, _ in
                    let s = String(clean[r]).trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { sentences.append(s) }
                    return true
                }
                if sentences.isEmpty { sentences = [clean] }
                for (si, sentence) in sentences.enumerated() {
                    appendChunk(sentence, style: .normal, paragraphEnd: si == sentences.count - 1)
                }
            }
        }
        return result
    }

    // MARK: Transporte

    func startPrompter() {
        guard let doc = SpeechStore.shared.speech(selectedID) else { return }
        chunks = parse(doc.body)
        guard totalWords > 0 else { return }
        currentIndex = 0
        isPlaying = false
        mode = .prompting
        NSApp.keyWindow?.makeFirstResponder(nil)
        GlobalHotKeys.shared.register()
    }

    func backToEditor() {
        pause()
        mode = .editing
        GlobalHotKeys.shared.unregister()
    }

    func play() {
        guard mode == .prompting, totalWords > 0 else { return }
        if currentIndex >= totalWords - 1 { currentIndex = 0 }
        isPlaying = true
        scheduleNext()
    }

    func pause() {
        isPlaying = false
        pendingWork?.cancel()
        pendingWork = nil
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func reset() {
        pause()
        currentIndex = 0
    }

    func skip(_ delta: Int) {
        guard totalWords > 0 else { return }
        currentIndex = min(max(0, currentIndex + delta), totalWords - 1)
        if isPlaying { reschedule() }
    }

    func jump(to index: Int) {
        guard totalWords > 0 else { return }
        currentIndex = min(max(0, index), totalWords - 1)
        if isPlaying { reschedule() }
    }

    func changeSpeed(_ delta: Int) {
        wpm = min(max(60, wpm + delta), 400)
        if isPlaying { reschedule() }
    }

    func changeFont(_ delta: CGFloat) {
        fontSize = min(max(20, fontSize + delta), 72)
    }

    func changeOpacity(_ delta: Double) {
        bgOpacity = min(max(0.0, bgOpacity + delta), 1.0)
    }

    private func reschedule() {
        pendingWork?.cancel()
        scheduleNext()
    }

    private func scheduleNext() {
        guard isPlaying, currentIndex < totalWords - 1 else {
            if currentIndex >= totalWords - 1 { isPlaying = false }
            return
        }
        let base = 60.0 / Double(wpm)
        var multiplier = 1.0
        let word = wordAt(currentIndex)
        if let last = word.last {
            if ".!?…:".contains(last) { multiplier = 1.9 }
            else if ",;".contains(last) { multiplier = 1.4 }
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isPlaying else { return }
            self.currentIndex += 1
            self.scheduleNext()
        }
        pendingWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + base * multiplier, execute: item)
    }

    private func wordAt(_ index: Int) -> String {
        guard let chunk = chunks.first(where: { $0.range.contains(index) }) else { return "" }
        return chunk.words[index - chunk.range.lowerBound]
    }

    // MARK: Teclado (solo en modo prompter)

    func handleKey(_ event: NSEvent) -> Bool {
        guard mode == .prompting, !event.modifierFlags.contains(.command) else { return false }
        switch event.keyCode {
        case 49: togglePlay(); return true          // espacio
        case 123: skip(-10); return true            // ←
        case 124: skip(+10); return true            // →
        case 126: changeSpeed(+10); return true     // ↑
        case 125: changeSpeed(-10); return true     // ↓
        case 53: backToEditor(); return true        // esc
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": reset(); return true
        case "+", "=": changeFont(+2); return true
        case "-": changeFont(-2); return true
        case "[": changeOpacity(-0.1); return true
        case "]": changeOpacity(+0.1); return true
        default: return false
        }
    }
}

// MARK: - Vistas

struct ContentView: View {
    @EnvironmentObject var model: PrompterModel
    @EnvironmentObject var store: SpeechStore

    var body: some View {
        ZStack {
            Color.black
                .opacity(model.mode == .editing ? 0.94 : model.bgOpacity)
                .ignoresSafeArea()
            if model.mode == .editing {
                LibraryView()
            } else {
                PrompterView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: Biblioteca (sidebar + editor)

struct LibraryView: View {
    @EnvironmentObject var model: PrompterModel
    @EnvironmentObject var store: SpeechStore

    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 340)
            EditorPane()
                .frame(minWidth: 420, maxWidth: .infinity)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: PrompterModel
    @EnvironmentObject var store: SpeechStore
    @State private var newFolderPrompt = false
    @State private var newFolderName = ""
    @State private var pendingDelete: SpeechDoc? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("BtoPrompter")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.yellow)
                Spacer()
                Button { _ = selectNew() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).help("Nuevo discurso")
                Button { newFolderPrompt = true } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).help("Nueva carpeta")
                Button { openImportPanel() } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.plain).help("Importar archivos (txt, md, pptx, audio)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if let status = store.importStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.system(size: 11)).foregroundColor(.orange)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            List {
                Section("Discursos") {
                    ForEach(store.speeches(inFolder: "", archived: false)) { doc in
                        row(doc)
                    }
                }
                ForEach(store.allFolders, id: \.self) { folder in
                    Section {
                        ForEach(store.speeches(inFolder: folder, archived: false)) { doc in
                            row(doc)
                        }
                    } header: {
                        HStack {
                            Label(folder, systemImage: "folder")
                            Spacer()
                        }
                        .contextMenu {
                            Button("Eliminar carpeta (los discursos pasan a la raíz)") {
                                store.deleteFolder(folder)
                            }
                        }
                    }
                }
                if !store.archivedSpeeches.isEmpty {
                    Section("Archivados") {
                        ForEach(store.archivedSpeeches) { doc in
                            row(doc)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color.white.opacity(0.04))
        .alert("Nueva carpeta", isPresented: $newFolderPrompt) {
            TextField("Nombre", text: $newFolderName)
            Button("Crear") {
                store.addFolder(newFolderName)
                newFolderName = ""
            }
            Button("Cancelar", role: .cancel) { newFolderName = "" }
        }
        .alert("¿Eliminar \"\(pendingDelete?.title ?? "")\"?", isPresented: .init(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Eliminar", role: .destructive) {
                if let doc = pendingDelete {
                    store.delete(doc.id)
                    if model.selectedID == doc.id { model.selectedID = store.library.speeches.first?.id }
                }
                pendingDelete = nil
            }
            Button("Cancelar", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Esta acción no se puede deshacer. Si prefieres conservarlo, usa Archivar.")
        }
    }

    private func selectNew() -> SpeechDoc {
        let doc = store.newSpeech()
        model.selectedID = doc.id
        return doc
    }

    private func row(_ doc: SpeechDoc) -> some View {
        HStack(spacing: 6) {
            Image(systemName: doc.isArchived ? "archivebox" : (doc.isDraft ? "doc.badge.clock" : "doc.text"))
                .foregroundColor(doc.id == model.selectedID ? .yellow : .gray)
                .font(.system(size: 12))
            Text(doc.title.isEmpty ? "Sin título" : doc.title)
                .lineLimit(1)
                .foregroundColor(doc.id == model.selectedID ? .yellow : .white)
            Spacer()
            if doc.isDraft {
                Text("borrador")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.25))
                    .cornerRadius(4)
                    .foregroundColor(.orange)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = doc.id }
        .contextMenu {
            Button("Iniciar prompter") {
                model.selectedID = doc.id
                model.startPrompter()
            }
            Button(doc.isDraft ? "Quitar marca de borrador" : "Marcar como borrador") {
                store.update(doc.id) { $0.isDraft.toggle() }
            }
            Menu("Mover a carpeta") {
                Button("(raíz)") { store.update(doc.id) { $0.folder = "" } }
                ForEach(store.allFolders, id: \.self) { f in
                    Button(f) { store.update(doc.id) { $0.folder = f } }
                }
            }
            Button(doc.isArchived ? "Desarchivar" : "Archivar") {
                store.update(doc.id) { $0.isArchived.toggle() }
            }
            Divider()
            Button("Eliminar…", role: .destructive) { pendingDelete = doc }
        }
    }

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        var types: [UTType] = [.plainText, .audio]
        for ext in ["md", "markdown", "pptx", "m4a", "mp3", "wav", "aac", "aiff"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        panel.message = "Importa discursos desde texto, Markdown, PowerPoint o audio (se transcribe)"
        if panel.runModal() == .OK {
            store.importFiles(urls: panel.urls, folder: "")
        }
    }
}

struct EditorPane: View {
    @EnvironmentObject var model: PrompterModel
    @EnvironmentObject var store: SpeechStore

    private var titleBinding: Binding<String> {
        Binding(
            get: { store.speech(model.selectedID)?.title ?? "" },
            set: { v in if let id = model.selectedID { store.update(id) { $0.title = v } } }
        )
    }

    private var bodyBinding: Binding<String> {
        Binding(
            get: { store.speech(model.selectedID)?.body ?? "" },
            set: { v in if let id = model.selectedID { store.update(id) { $0.body = v } } }
        )
    }

    var body: some View {
        if let doc = store.speech(model.selectedID) {
            VStack(spacing: 10) {
                HStack {
                    TextField("Título del discurso", text: titleBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Spacer()
                    Toggle("Borrador", isOn: .init(
                        get: { doc.isDraft },
                        set: { v in store.update(doc.id) { $0.isDraft = v } }
                    ))
                    .toggleStyle(.checkbox)
                    .help("Marca este discurso como borrador")
                    Toggle("Títulos = guía", isOn: $model.guideTitles)
                        .toggleStyle(.checkbox)
                        .help("Los títulos (#, ##) se ven en azul pero el karaoke NO los lee — sirven de referencia, ej. \"Diapositiva 1\". Las líneas que empiezan con // siempre son guía.")
                    SpyToggle()
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: bodyBinding)
                        .font(.system(size: 16))
                        .scrollContentBackground(.hidden)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(8)
                    if doc.body.isEmpty {
                        Text("Pega aquí tu discurso… Soporta Markdown (# títulos, - viñetas) y guías: las líneas que empiezan con // se ven en el prompter pero no se leen (ej: // Diapositiva 1)")
                            .foregroundColor(.gray)
                            .padding(.top, 8)
                            .padding(.leading, 6)
                            .allowsHitTesting(false)
                    }
                }
                HStack(spacing: 14) {
                    Button {
                        if let s = NSPasteboard.general.string(forType: .string) {
                            store.update(doc.id) { $0.body = s }
                        }
                    } label: {
                        Label("Pegar", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        store.update(doc.id) { $0.body = "" }
                    } label: {
                        Label("Limpiar", systemImage: "trash")
                    }
                    Text("Guardado automático ✓")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                    Spacer()
                    HStack(spacing: 6) {
                        Button("−") { model.changeSpeed(-10) }
                        Text("\(model.wpm) ppm")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 74)
                        Button("+") { model.changeSpeed(+10) }
                    }
                    .help("Velocidad en palabras por minuto")
                    Button {
                        model.startPrompter()
                    } label: {
                        Label("Iniciar", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                    .foregroundColor(.black)
                    .disabled(doc.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Atajos en el prompter:  ␣ play/pausa · ← → saltar 10 palabras · ↑ ↓ velocidad · + − letra · [ ] transparencia · R reiniciar · Esc volver aquí")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            .padding(16)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 40))
                    .foregroundColor(.gray)
                Text("Selecciona un discurso o crea uno nuevo")
                    .foregroundColor(.gray)
                Button("Nuevo discurso") {
                    model.selectedID = store.newSpeech().id
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundColor(.black)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Prompter

struct PrompterView: View {
    @EnvironmentObject var model: PrompterModel

    var body: some View {
        VStack(spacing: 0) {
            header
            scroller
            controls
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            ProgressView(value: model.totalWords > 0
                         ? Double(model.currentIndex) / Double(max(1, model.totalWords - 1))
                         : 0)
                .tint(.yellow)
            HStack {
                Text("\(model.currentIndex + 1) / \(model.totalWords)")
                Spacer()
                Text("~\(model.remainingTimeText) restante · \(model.wpm) ppm")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.gray)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

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
            a.foregroundColor = Color(red: 0.45, green: 0.78, blue: 1.0).opacity(0.85)
            a.font = font
            return a
        }
        var result = AttributedString()
        for (i, word) in chunk.words.enumerated() {
            let g = chunk.range.lowerBound + i
            var a = AttributedString(word)
            a.font = font
            if g < model.currentIndex {
                a.foregroundColor = Color.white.opacity(0.32)
            } else if g == model.currentIndex {
                a.foregroundColor = .yellow
                a.underlineStyle = .single
            } else {
                a.foregroundColor = chunk.style == .h1 || chunk.style == .h2
                    ? Color(red: 1.0, green: 0.92, blue: 0.6)
                    : .white
            }
            result += a
            if i < chunk.words.count - 1 { result += AttributedString(" ") }
        }
        return result
    }

    private var controls: some View {
        HStack(spacing: 16) {
            ControlButton(symbol: "gobackward", help: "Reiniciar (R)") { model.reset() }
            ControlButton(symbol: "backward.fill", help: "Atrás 10 palabras (←)") { model.skip(-10) }
            ControlButton(symbol: model.isPlaying ? "pause.fill" : "play.fill",
                          help: "Play / Pausa (espacio)", size: 22, color: .yellow) {
                model.togglePlay()
            }
            ControlButton(symbol: "forward.fill", help: "Adelante 10 palabras (→)") { model.skip(+10) }
            ControlButton(symbol: "stop.fill", help: "Volver al editor (Esc)") { model.backToEditor() }
            Divider().frame(height: 18)
            HStack(spacing: 4) {
                ControlButton(symbol: "tortoise.fill", help: "Más lento (↓)", size: 13) { model.changeSpeed(-10) }
                Text("\(model.wpm)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.gray)
                    .frame(width: 32)
                ControlButton(symbol: "hare.fill", help: "Más rápido (↑)", size: 13) { model.changeSpeed(+10) }
            }
            HStack(spacing: 4) {
                ControlButton(symbol: "textformat.size.smaller", help: "Letra más pequeña (−)", size: 13) { model.changeFont(-2) }
                ControlButton(symbol: "textformat.size.larger", help: "Letra más grande (+)", size: 13) { model.changeFont(+2) }
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
                .foregroundColor(Color(red: 0.45, green: 0.78, blue: 1.0))
                .help("Atajos GLOBALES: funcionan aunque estés en PowerPoint, Keynote o cualquier otra app")
            SpyToggle()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05))
    }
}

struct ControlButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 17
    var color: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(color)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct SpyToggle: View {
    @EnvironmentObject var model: PrompterModel

    var body: some View {
        Button {
            model.spyMode.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.spyMode ? "eye.slash.fill" : "eye.fill")
                Text(model.spyMode ? "Invisible al compartir" : "VISIBLE al compartir")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(model.spyMode ? .green : .red)
        }
        .buttonStyle(.plain)
        .help("Con el ojo tachado, la ventana NO aparece en Zoom/Teams ni en capturas de pantalla")
    }
}

// MARK: - App / Ventana

// Panel no-activante: flota sobre TODO (incluidas apps en pantalla completa,
// como PowerPoint o Keynote presentando) y no roba el foco al hacer clic.
final class PrompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        // Esc no cierra el panel; en modo prompter el monitor de teclado lo usa.
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = PrompterModel.shared
        let store = SpeechStore.shared

        // Selección inicial coherente.
        if store.speech(model.selectedID) == nil {
            model.selectedID = store.library.speeches.first?.id
        }

        let panel = PrompterPanel(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        window = panel
        window.title = "BtoPrompter"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.minSize = NSSize(width: 640, height: 360)
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.sharingType = model.spyMode ? .none : .readOnly
        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(model)
                .environmentObject(store)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)

        model.$spyMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] spy in
                self?.window.sharingType = spy ? .none : .readOnly
            }
            .store(in: &cancellables)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            PrompterModel.shared.handleKey(event) ? nil : event
        }

        buildMenu()
        NSApp.activate(ignoringOtherApps: true)

        if CommandLine.arguments.contains("--autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                model.startPrompter()
                model.play()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKeys.shared.unregister()
        SpeechStore.shared.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Salir de BtoPrompter",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edición")
        editMenu.addItem(NSMenuItem(title: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Rehacer", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - Arranque

if let i = CommandLine.arguments.firstIndex(of: "--test-pptx"), CommandLine.arguments.count > i + 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    print(SpeechStore.extractPPTX(url) ?? "ERROR: no se pudo extraer texto")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
