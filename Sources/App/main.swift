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

// Comprobación de la invisibilidad al compartir pantalla. Necesita interfaz,
// así que arranca la app en segundo plano y sale con el resultado.
if CommandLine.arguments.contains("--test-sharing") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        // Dos intentos: una ventana ajena puede taparnos justo en el momento
        // de la captura (Finder, notificaciones) y dar un falso negativo.
        let first = MainActor.assumeIsolated { SelfTest.runSharingCheck() }
        if first {
            exit(0)
        }
        print("(reintento en 2 s: pudo taparnos otra ventana)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let second = MainActor.assumeIsolated { SelfTest.runSharingCheck() }
            exit(second ? 0 : 1)
        }
    }
    app.run()
}

// Composición sin interfaz: junta cámara y pantalla de una carpeta de
// grabación y exporta el MP4. Prueba reproducible del editor completo.
if let i = CommandLine.arguments.firstIndex(of: "--test-compose"), CommandLine.arguments.count > i + 2 {
    let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 2])
    guard let sources = CompositionBuilder.sources(inFolder: folder) else {
        print("ERROR: la carpeta no tiene cámara + pantalla + sync.json")
        exit(1)
    }
    print("desfase aplicado: \(Int(sources.offsetSeconds * 1000)) ms")
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            // El proyecto sale de project.json si existe; el tercer argumento
            // opcional (índice de preset) monta un proyecto de un solo tramo.
            var project = VideoProjectStore.load(folder: folder, duration: 0)
            if CommandLine.arguments.count > i + 3,
               let idx = Int(CommandLine.arguments[i + 3]),
               idx >= 0, idx < SegmentLayout.presets.count {
                project = VideoProject()
                project.layouts = [SegmentLayout.presets[idx].layout]
                print("preset: \(SegmentLayout.presets[idx].name)")
            } else {
                print("tramos: \(project.layouts.count) (cortes en \(project.cuts))")
            }
            let built = try await CompositionBuilder.build(sources, extraLayers: project.extraLayers,
                                                           audioLayers: project.audioLayers,
                                                           micVolume: project.micVolume,
                                                           screenAudioVolume: project.screenAudioVolume)
            project.duration = built.duration
            CompositionParameters.shared.project = project.sanitized()
            CompositionExporter.export(composition: built.composition, video: built.video,
                                       audioMix: built.audioMix,
                                       to: out, progress: { _ in }) { result in
                switch result {
                case .success(let url):
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    print("OK: \(url.path) (\(size / 1024) KB)")
                    exit(0)
                case .failure(let error):
                    print("ERROR: \(error.localizedDescription)")
                    exit(1)
                }
            }
        } catch {
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
        sem.signal()
    }
    RunLoop.main.run()
}

// Prueba aislada del micrófono con cancelación de eco.
//   --test-mic-clean <salida.m4a> <segundos>
if let i = CommandLine.arguments.firstIndex(of: "--test-mic-clean"), CommandLine.arguments.count > i + 2 {
    setbuf(stdout, nil)
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let secs = Double(CommandLine.arguments[i + 2]) ?? 5
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let rec = VoiceIsolatedRecorder()
    DispatchQueue.main.async {
        let cancel = !CommandLine.arguments.contains("--sin-aec")
        let ok = rec.start(to: out, cancelEcho: cancel)
        print("cancelación de eco: \(cancel ? "SÍ" : "no")")
        print("arranque: \(ok ? "OK" : "FALLÓ") \(rec.lastError ?? "")")
        guard ok else { exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
            rec.stop()
            let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            print("archivo: \(size ?? 0) bytes")
            if let e = rec.lastError { print("último error: \(e)") }
            exit(0)
        }
    }
    app.run()
}

// Subtítulos desde el AUDIO de una grabación (sin teleprompter).
//   --test-transcribe <carpeta-de-grabación>
if let i = CommandLine.arguments.firstIndex(of: "--test-transcribe"), CommandLine.arguments.count > i + 1 {
    let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
    guard let audio = SubtitleTranscriber.bestAudioSource(inFolder: folder) else {
        print("ERROR: no hay audio en esa carpeta")
        exit(1)
    }
    print("audio: \(audio.lastPathComponent)")
    setbuf(stdout, nil)   // sin buffer: la salida se ve aunque el proceso siga vivo
    // El permiso de reconocimiento necesita una app real para poder mostrar
    // su diálogo la primera vez.
    let transcribeApp = NSApplication.shared
    transcribeApp.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            SubtitleTranscriber.shared.transcribe(url: audio) { result in
                switch result {
                case .success(let chunks):
                    print(SubtitleBuilder.toSRT(chunks))
                    exit(0)
                case .failure(let error):
                    print("ERROR: \(error.localizedDescription)")
                    exit(1)
                }
            }
        }
    }
    transcribeApp.run()
}

// Traducción de subtítulos con la IA configurada: prueba reproducible.
//   --test-translate <archivo.srt> <código-idioma>
if let i = CommandLine.arguments.firstIndex(of: "--test-translate"), CommandLine.arguments.count > i + 2 {
    let srtPath = CommandLine.arguments[i + 1]
    let lang = CommandLine.arguments[i + 2]
    guard let content = try? String(contentsOfFile: srtPath, encoding: .utf8) else {
        print("ERROR: no se pudo leer \(srtPath)")
        exit(1)
    }
    let chunks = SubtitleBuilder.parseSRT(content)
    guard !chunks.isEmpty else {
        print("ERROR: el SRT no tiene bloques válidos")
        exit(1)
    }
    guard let config = SubtitleAI.ProviderConfig.current() else {
        print("ERROR: sin proveedor de IA configurado (Ajustes → Ensayo IA)")
        exit(1)
    }
    let name = SubtitleAI.languages.first(where: { $0.code == lang })?.name ?? lang
    let sem = DispatchSemaphore(value: 0)
    SubtitleAI.translate(chunks, to: name, config: config) { result in
        switch result {
        case .success(let translated):
            print(SubtitleBuilder.toSRT(translated))
        case .failure(let error):
            print("ERROR: \(error.localizedDescription)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--test-pptx"), CommandLine.arguments.count > i + 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    print(SpeechStore.extractPPTX(url) ?? "ERROR: no se pudo extraer texto")
    exit(0)
}

// Genera un estilo de ensayo a partir del diagnóstico real, con la IA.
if CommandLine.arguments.contains("--test-style") {
    let combined = SessionAnalyzer.combinedReport(limit: 5)
    guard !combined.reports.isEmpty else {
        print("ERROR: no hay sesiones analizables")
        exit(1)
    }
    print("--- evidencia local ---")
    print(combined.text)
    var evidence = combined.text
    let profile = SpeakingProfileStore.shared
    if !profile.stylePrompt.isEmpty { evidence += "\n\n" + profile.stylePrompt }
    let provider = Settings.string(.aiProvider, default: "groq")
    let base = provider == "custom"
        ? Settings.string(.aiBaseURL, default: "")
        : (AIRehearsal.providers.first(where: { $0.id == provider })?.baseURL ?? "")
    let key = SecretsStore.get("aiKey_\(provider)")
    let model = Settings.string(.aiModel, default: "llama-3.3-70b-versatile")
    let sem = DispatchSemaphore(value: 0)
    AIRehearsal.buildSpeakerStyle(evidence: evidence, baseURL: base,
                                  apiKey: key, model: model) { result in
        switch result {
        case .success(let text): print("\n--- estilo redactado por la IA ---\n" + text)
        case .failure(let error): print("ERROR: \(error.localizedDescription)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// Prueba de un motor TTS: genera audio y lo guarda, sin abrir la interfaz.
if let i = CommandLine.arguments.firstIndex(of: "--test-tts"), CommandLine.arguments.count > i + 2 {
    let providerID = CommandLine.arguments[i + 1]
    let outPath = CommandLine.arguments[i + 2]
    guard let provider = TTSProviderID(rawValue: providerID) else {
        print("ERROR: proveedor desconocido. Opciones: " +
              TTSProviderID.allCases.map(\.rawValue).joined(separator: ", "))
        exit(1)
    }
    let text = CommandLine.arguments.count > i + 3
        ? CommandLine.arguments[i + 3]
        : "Hola, esta es una prueba de la voz de BtoPrompter."
    let sem = DispatchSemaphore(value: 0)
    TTSEngines.synthesize(text: text, provider: provider) { result in
        switch result {
        case .success(let data):
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("OK \(provider.name): \(data.count) bytes → \(outPath)")
        case .failure(let error):
            print("ERROR \(provider.name): \(error.localizedDescription)")
        }
        sem.signal()
    }
    sem.wait()
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

// Diagnóstico del permiso de Accesibilidad (control del ordenador).
if CommandLine.arguments.contains("--ax-status") {
    print("ruta del binario: \(Bundle.main.bundlePath)")
    print("autorizado en Accesibilidad: \(AXIsProcessTrusted())")
    print("control del ordenador activado: \(Settings.bool(.remoteComputerControl, default: false))")
    exit(AXIsProcessTrusted() ? 0 : 1)
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
