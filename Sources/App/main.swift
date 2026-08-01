import AppKit
import AVFoundation
import Speech

// Punto de entrada: flags de línea de comandos y arranque de la app.
//   --capturable      arranca visible en capturas (para pruebas)
//   --autostart       entra directo al prompter reproduciendo
//   --selftest        corre las pruebas del parser y sale
//   --test-pptx <f>   extrae el texto de un .pptx y sale
//   --test-ai <f>     marca un texto con el Ensayo IA configurado y sale

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

if let i = CommandLine.arguments.firstIndex(of: "--test-pptx"), CommandLine.arguments.count > i + 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    print(SpeechStore.extractPPTX(url) ?? "ERROR: no se pudo extraer texto")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--export-pdf"), CommandLine.arguments.count > i + 2 {
    let input = CommandLine.arguments[i + 1]
    let output = CommandLine.arguments[i + 2]
    let body = (try? String(contentsOfFile: input, encoding: .utf8)) ?? ""
    do {
        try PDFExporter.export(title: URL(fileURLWithPath: input).deletingPathExtension().lastPathComponent,
                               body: body, guideTitles: true,
                               to: URL(fileURLWithPath: output))
        print("PDF OK: \(output)")
        exit(0)
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--test-ai"), CommandLine.arguments.count > i + 1 {
    let text = (try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8)) ?? ""
    let provider = Settings.string(.aiProvider, default: "groq")
    let base = provider == "custom"
        ? Settings.string(.aiBaseURL, default: "")
        : (AIRehearsal.providers.first(where: { $0.id == provider })?.baseURL ?? "")
    let model = Settings.string(.aiModel, default: "llama-3.3-70b-versatile")
    let key = SecretsStore.get("aiKey_\(provider)")
    let style = Settings.string(.aiStyle, default: "conferencia")
    let sem = DispatchSemaphore(value: 0)
    AIRehearsal.run(text: text, baseURL: base, apiKey: key, model: model,
                    styleID: style,
                    customPrompt: Settings.string(.aiCustomPrompt, default: "")) { result in
        switch result {
        case .success(let marked): print(marked)
        case .failure(let error): print("ERROR: \(error.localizedDescription)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// Diagnóstico de permisos del seguimiento por voz.
if CommandLine.arguments.contains("--mic-status") {
    import_diag()
    exit(0)
}

func import_diag() {
    let mic: String
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: mic = "autorizado"
    case .denied: mic = "DENEGADO"
    case .restricted: mic = "restringido"
    case .notDetermined: mic = "sin preguntar todavía"
    @unknown default: mic = "?"
    }
    let speech: String
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: speech = "autorizado"
    case .denied: speech = "DENEGADO"
    case .restricted: speech = "restringido"
    case .notDetermined: speech = "sin preguntar todavía"
    @unknown default: speech = "?"
    }
    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    print("micrófono: \(mic)")
    print("reconocimiento de voz: \(speech)")
    print("reconocedor es-ES disponible: \(recognizer?.isAvailable == true)")
    print("on-device: \(recognizer?.supportsOnDeviceRecognition == true)")
}

// Prueba de la actualización automática SIN instalar: descarga el último
// release, lo descomprime y valida el paquete.
if CommandLine.arguments.contains("--test-update") {
    let sem = DispatchSemaphore(value: 0)
    var req = URLRequest(url: URL(string: "https://api.github.com/repos/btoaldas/BtoPrompter/releases/latest")!)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: req) { data, _, _ in
        DispatchQueue.main.async {
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]],
                  let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                  let dl = zip["browser_download_url"] as? String else {
                print("ERROR: no se pudo leer el último release")
                exit(1)
            }
            UpdateChecker.shared.assetURL = URL(string: dl)
            UpdateChecker.shared.downloadAndInstall(dryRun: true) { ok in
                print(UpdateChecker.shared.status ?? "(sin estado)")
                sem.signal()
                exit(ok ? 0 : 1)
            }
        }
    }.resume()
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
