import Foundation
import os.log

// Capa de datos de la biblioteca de discursos: modelo + persistencia JSON.
// Archivo: ~/Library/Application Support/BtoPrompter/speeches.json

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
    static let log = Logger(subsystem: "com.bto.btoprompter", category: "storage")

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
        if let data = try? Data(contentsOf: fileURL) {
            do {
                library = try JSONDecoder().decode(Library.self, from: data)
            } catch {
                Self.log.error("speeches.json corrupto: \(error.localizedDescription)")
                // No pisar el archivo dañado: respaldo con marca de tiempo para
                // rescate manual (un nombre fijo colisionaría con incidentes previos).
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let backupURL = fileURL.deletingPathExtension()
                    .appendingPathExtension("corrupt-\(stamp).json")
                do {
                    try FileManager.default.copyItem(at: fileURL, to: backupURL)
                    Self.log.error("respaldo del archivo corrupto en \(backupURL.lastPathComponent)")
                } catch {
                    Self.log.fault("no se pudo respaldar speeches.json corrupto: \(error.localizedDescription)")
                }
            }
        }
        migrateLegacyScriptIfNeeded()
    }

    // Migración desde la versión 1.0 (texto único en UserDefaults).
    private func migrateLegacyScriptIfNeeded() {
        guard library.speeches.isEmpty else { return }
        var old = Settings.string(.legacyScript, default: "")
        if old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            old = Settings.string(.legacyLastScript, default: "")
        }
        if !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            library.speeches.append(SpeechDoc(title: "Mi discurso", body: old))
            saveNow()
        }
    }

    // MARK: Persistencia (guardado agrupado para no escribir en cada tecla)

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveNow() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(library)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("no se pudo guardar la biblioteca: \(error.localizedDescription)")
        }
    }

    // MARK: Consultas

    func speech(_ id: UUID?) -> SpeechDoc? {
        guard let id else { return nil }
        return library.speeches.first(where: { $0.id == id })
    }

    func index(_ id: UUID) -> Int? {
        library.speeches.firstIndex(where: { $0.id == id })
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

    // MARK: Mutaciones

    @discardableResult
    func newSpeech(title: String = "Nuevo discurso", body: String = "", folder: String = "") -> SpeechDoc {
        let doc = SpeechDoc(title: title, body: body, folder: folder)
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
}
