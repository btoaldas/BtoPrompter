import AppKit
import Foundation

// Comprobación de actualizaciones contra los releases de GitHub.
// Solo consulta cuando el usuario lo pide; no llama a la red por su cuenta.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var status: String? = nil
    @Published var latestURL: URL? = nil
    @Published var assetURL: URL? = nil
    @Published var checking = false
    @Published var installing = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var autoInstall: Bool {
        get { Settings.bool(.autoInstallUpdates, default: true) }
        set { Settings.set(newValue, .autoInstallUpdates) }
    }

    func check() {
        guard !checking else { return }
        checking = true
        status = "Comprobando…"
        latestURL = nil
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/btoaldas/BtoPrompter/releases/latest")!)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                self.checking = false
                guard error == nil, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    self.status = "No se pudo comprobar (¿sin internet?)"
                    return
                }
                let current = "v" + self.currentVersion
                if tag == current {
                    self.status = "Estás al día ✓"
                } else {
                    self.status = "Nueva versión \(tag) disponible"
                    if let urlString = json["html_url"] as? String {
                        self.latestURL = URL(string: urlString)
                    }
                    if let assets = json["assets"] as? [[String: Any]],
                       let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                       let dl = zip["browser_download_url"] as? String {
                        self.assetURL = URL(string: dl)
                    }
                }
            }
        }.resume()
    }

    func openDownload() {
        if let url = latestURL { NSWorkspace.shared.open(url) }
    }

    // Actúa según la preferencia: instalar solo, o abrir el navegador.
    func applyUpdate() {
        if autoInstall, assetURL != nil {
            downloadAndInstall()
        } else {
            openDownload()
        }
    }

    // Descarga el zip del release, lo valida y reemplaza la app actual.
    // Con dryRun solo descarga y valida (para pruebas sin tocar la app).
    func downloadAndInstall(dryRun: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard let assetURL, !installing else { completion?(false); return }
        installing = true
        status = "Descargando actualización…"
        URLSession.shared.downloadTask(with: assetURL) { tmp, _, error in
            DispatchQueue.main.async {
                guard let tmp, error == nil else {
                    self.installing = false
                    self.status = "Error al descargar: \(error?.localizedDescription ?? "desconocido")"
                    completion?(false)
                    return
                }
                do {
                    try self.install(from: tmp, dryRun: dryRun)
                    completion?(true)
                } catch {
                    self.installing = false
                    self.status = "Error al instalar: \(error.localizedDescription)"
                    completion?(false)
                }
            }
        }.resume()
    }

    private func install(from zip: URL, dryRun: Bool) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("btop-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { if dryRun { try? fm.removeItem(at: work) } }

        try runTool("/usr/bin/ditto", ["-xk", zip.path, work.path])
        let newApp = work.appendingPathComponent("BtoPrompter.app")
        guard fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/BtoPrompter").path) else {
            throw NSError(domain: "BtoPrompter", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "El paquete descargado no es válido"])
        }
        try? runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        if dryRun {
            installing = false
            status = "✓ Prueba de descarga e instalación válida (sin instalar)"
            return
        }

        status = "Instalando…"
        let currentPath = Bundle.main.bundlePath
        let backupPath = currentPath + ".old"
        try? fm.removeItem(atPath: backupPath)
        try fm.moveItem(atPath: currentPath, toPath: backupPath)
        do {
            try fm.moveItem(atPath: newApp.path, toPath: currentPath)
        } catch {
            // Restaurar si algo falla a mitad del reemplazo.
            try? fm.moveItem(atPath: backupPath, toPath: currentPath)
            throw error
        }
        try? fm.removeItem(atPath: backupPath)
        status = "✓ Actualizado. Reiniciando…"
        SpeechStore.shared.saveNow()
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunch.arguments = ["-n", currentPath]
        try? relaunch.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApp.terminate(nil)
        }
    }

    private func runTool(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "BtoPrompter", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: path).lastPathComponent) falló"])
        }
    }
}
