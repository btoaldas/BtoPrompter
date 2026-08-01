import Foundation

// Descarga y gestión de modelos locales de reconocimiento (Whisper en formato
// GGML). Descarga reanudable: se puede cancelar y continuar donde quedó, y
// sobrevive al cierre de la app porque el progreso queda en disco.

struct LocalSTTModel: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let approxMB: Int
    let url: URL
    let sha: String?

    var fileName: String { url.lastPathComponent }
}

final class LocalModelStore: ObservableObject {
    static let shared = LocalModelStore()

    // Catálogo de modelos Whisper multilingües (incluyen español).
    static let catalog: [LocalSTTModel] = [
        LocalSTTModel(id: "whisper-base", name: "Whisper base",
                      detail: "Rápido, calidad básica. Buen punto de partida.",
                      approxMB: 148,
                      url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
                      sha: nil),
        LocalSTTModel(id: "whisper-small", name: "Whisper small",
                      detail: "Equilibrio entre velocidad y precisión.",
                      approxMB: 488,
                      url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
                      sha: nil),
        LocalSTTModel(id: "whisper-medium", name: "Whisper medium",
                      detail: "Más preciso en español, necesita más CPU.",
                      approxMB: 1530,
                      url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!,
                      sha: nil),
        LocalSTTModel(id: "whisper-large-v3-turbo", name: "Whisper large v3 turbo",
                      detail: "La mejor calidad local; pesa más y pide equipo potente.",
                      approxMB: 1620,
                      url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
                      sha: nil),
    ]

    struct DownloadState {
        var progress: Double = 0
        var downloadedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var running = false
        var error: String?
    }

    @Published private(set) var states: [String: DownloadState] = [:]

    private var tasks: [String: URLSessionDataTask] = [:]
    private var handles: [String: FileHandle] = [:]
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: proxy, delegateQueue: nil)
    }()
    private lazy var proxy = DownloadProxy(store: self)

    var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BtoPrompter/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func fileURL(_ model: LocalSTTModel) -> URL { directory.appendingPathComponent(model.fileName) }
    func partialURL(_ model: LocalSTTModel) -> URL { directory.appendingPathComponent(model.fileName + ".part") }

    func isInstalled(_ model: LocalSTTModel) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(model).path)
    }

    func partialBytes(_ model: LocalSTTModel) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: partialURL(model).path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func installedSize(_ model: LocalSTTModel) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(model).path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: Descarga reanudable

    func start(_ model: LocalSTTModel) {
        guard tasks[model.id] == nil, !isInstalled(model) else { return }
        let already = partialBytes(model)
        var request = URLRequest(url: model.url)
        request.timeoutInterval = 60
        if already > 0 {
            // Continuar donde quedó, incluso tras cerrar la app.
            request.setValue("bytes=\(already)-", forHTTPHeaderField: "Range")
        }
        var state = states[model.id] ?? DownloadState()
        state.running = true
        state.error = nil
        state.downloadedBytes = already
        state.totalBytes = Int64(model.approxMB) * 1_048_576
        publish(model.id, state)

        let fm = FileManager.default
        if !fm.fileExists(atPath: partialURL(model).path) {
            fm.createFile(atPath: partialURL(model).path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: partialURL(model)) else {
            fail(model.id, "No se pudo escribir en la carpeta de modelos.")
            return
        }
        _ = try? handle.seekToEnd()
        handles[model.id] = handle

        let task = session.dataTask(with: request)
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()
    }

    func cancel(_ model: LocalSTTModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        try? handles[model.id]?.close()
        handles[model.id] = nil
        var state = states[model.id] ?? DownloadState()
        state.running = false
        state.downloadedBytes = partialBytes(model)
        publish(model.id, state)
    }

    func remove(_ model: LocalSTTModel) {
        cancel(model)
        try? FileManager.default.removeItem(at: fileURL(model))
        try? FileManager.default.removeItem(at: partialURL(model))
        publish(model.id, DownloadState())
    }

    // MARK: Callbacks del proxy

    fileprivate func append(_ id: String, _ data: Data, expected: Int64) {
        guard let handle = handles[id] else { return }
        try? handle.write(contentsOf: data)
        var state = states[id] ?? DownloadState()
        state.downloadedBytes += Int64(data.count)
        if expected > 0 { state.totalBytes = expected }
        state.progress = state.totalBytes > 0
            ? min(1, Double(state.downloadedBytes) / Double(state.totalBytes)) : 0
        state.running = true
        publish(id, state)
    }

    fileprivate func finish(_ id: String, error: Error?) {
        try? handles[id]?.close()
        handles[id] = nil
        tasks[id] = nil
        guard let model = Self.catalog.first(where: { $0.id == id }) else { return }
        if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            var state = states[id] ?? DownloadState()
            state.running = false
            state.downloadedBytes = partialBytes(model)
            state.error = cancelled ? nil : error.localizedDescription
            publish(id, state)
            return
        }
        // Completo: el .part pasa a ser el modelo definitivo.
        try? FileManager.default.removeItem(at: fileURL(model))
        try? FileManager.default.moveItem(at: partialURL(model), to: fileURL(model))
        var state = states[id] ?? DownloadState()
        state.running = false
        state.progress = 1
        state.error = nil
        publish(id, state)
    }

    private func fail(_ id: String, _ message: String) {
        var state = states[id] ?? DownloadState()
        state.running = false
        state.error = message
        publish(id, state)
    }

    private func publish(_ id: String, _ state: DownloadState) {
        DispatchQueue.main.async { self.states[id] = state }
    }
}

// Delegado de URLSession: escribe cada trozo al archivo parcial.
private final class DownloadProxy: NSObject, URLSessionDataDelegate {
    unowned let store: LocalModelStore
    init(store: LocalModelStore) { self.store = store }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = dataTask.taskDescription else { return }
        let expected = dataTask.response?.expectedContentLength ?? 0
        let already = store.states[id]?.downloadedBytes ?? 0
        store.append(id, data, expected: expected > 0 ? already + expected : 0)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        store.finish(id, error: error)
    }
}
