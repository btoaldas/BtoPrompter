import AppKit

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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
