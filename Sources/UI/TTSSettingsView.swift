import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Configuración de la lectura en voz alta: motor, modelo, voz, claves por
// proveedor y gestión de voces locales instalables.
struct TTSSettingsView: View {
    @ObservedObject private var playback = SpeechPlayback.shared

    @State private var provider: TTSProviderID = SpeechPlayback.shared.currentProvider
    @State private var model = ""
    @State private var voice = ""
    @State private var key = ""
    @State private var cloudConsent = Settings.bool(.ttsCloudConsent, default: false)
    @State private var systemVoice = Settings.string(.ttsVoiceIdentifier, default: "")
    @State private var rate = Settings.double(.ttsRate, default: 0.5)
    @State private var localVoices: [LocalVoice] = TTSEngines.installedLocalVoices()
    @State private var localVoiceID = Settings.string(.ttsLocalVoiceID, default: "")
    @State private var piperPath = TTSEngines.piperPath
    @State private var remoteVoices: [(id: String, label: String)] = []
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Motor de lectura") {
                Picker("Proveedor", selection: $provider) {
                    ForEach(TTSProviderID.allCases) { p in
                        Text(p.name).tag(p)
                    }
                }
                .onChange(of: provider) { newValue in
                    Settings.set(newValue.rawValue, .ttsProvider)
                    loadProviderState(newValue)
                }
                Text(provider.privacyNote)
                    .font(.system(size: 10)).foregroundColor(.secondary)
                HStack {
                    Text("Ritmo")
                    Slider(value: $rate, in: 0.30...0.68, step: 0.01)
                        .onChange(of: rate) { Settings.set($0, .ttsRate) }
                    Button(playback.speaking ? "Detener" : "Probar voz") {
                        if playback.speaking { playback.stop() }
                        else { playback.speak("Hola, soy la voz de lectura de BtoPrompter. Así sonará tu discurso.") }
                    }
                }
                if let status = playback.status {
                    Text(status).font(.system(size: 10))
                        .foregroundColor(status.hasPrefix("Generando") ? .orange : .red)
                }
            }

            switch provider {
            case .appleSystem:
                Section("Voz del sistema") {
                    Picker("Voz", selection: $systemVoice) {
                        Text("Automática según el idioma").tag("")
                        ForEach(SpeechPlayback.availableVoices, id: \.identifier) { v in
                            Text("\(v.name) — \(v.language)").tag(v.identifier)
                        }
                    }
                    .onChange(of: systemVoice) { Settings.set($0, .ttsVoiceIdentifier) }
                    Text("Voces instaladas en macOS. Puedes añadir más en Ajustes del Sistema → Accesibilidad → Contenido hablado.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            case .piperLocal:
                localVoicesSection
            default:
                cloudSection
            }
        }
        .formStyle(.grouped)
        .onAppear { loadProviderState(provider) }
    }

    // MARK: Voces locales

    private var localVoicesSection: some View {
        Section("Voces locales instaladas") {
            if localVoices.isEmpty {
                Text("Todavía no hay voces locales. Añade un modelo Piper (.onnx) entrenado con la voz que quieras.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                Picker("Voz", selection: $localVoiceID) {
                    ForEach(localVoices) { v in
                        Text(v.name).tag(v.id)
                    }
                }
                .onChange(of: localVoiceID) { Settings.set($0, .ttsLocalVoiceID) }
            }
            HStack {
                Button {
                    addLocalVoice()
                } label: {
                    Label("Añadir voz (.onnx)", systemImage: "plus.circle")
                }
                if let selected = localVoices.first(where: { $0.id == localVoiceID }) {
                    Button("Quitar \(selected.name)", role: .destructive) {
                        TTSEngines.removeLocalVoice(selected)
                        localVoices = TTSEngines.installedLocalVoices()
                        localVoiceID = localVoices.first?.id ?? ""
                        Settings.set(localVoiceID, .ttsLocalVoiceID)
                    }
                    .font(.system(size: 11))
                }
            }
            HStack {
                TextField("Ruta del motor Piper", text: $piperPath)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: piperPath) { TTSEngines.piperPath = $0 }
                Button("Detectar") {
                    piperPath = TTSEngines.autodetectPiper() ?? ""
                    TTSEngines.piperPath = piperPath
                }
            }
            Text("Las voces locales se generan en este Mac: el texto nunca sale del equipo.")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func addLocalVoice() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let onnx = UTType(filenameExtension: "onnx") {
            panel.allowedContentTypes = [onnx]
        }
        panel.message = "Elige el modelo de voz Piper (.onnx). Se copiará a BtoPrompter."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Nombre de la voz"
        alert.informativeText = "Con qué nombre quieres verla en la lista."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = url.deletingPathExtension().lastPathComponent
        alert.accessoryView = field
        alert.addButton(withTitle: "Añadir")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let voice = try TTSEngines.installLocalVoice(from: url, name: field.stringValue)
            localVoices = TTSEngines.installedLocalVoices()
            localVoiceID = voice.id
            Settings.set(localVoiceID, .ttsLocalVoiceID)
        } catch {
            testResult = "No se pudo instalar la voz: \(error.localizedDescription)"
        }
    }

    // MARK: Proveedores de nube

    private var cloudSection: some View {
        Section(provider.name) {
            Toggle("Autorizo enviar el texto del discurso a este proveedor", isOn: $cloudConsent)
                .onChange(of: cloudConsent) { Settings.set($0, .ttsCloudConsent) }
            SecureField("API key de \(provider.name)", text: $key)
                .textFieldStyle(.roundedBorder)
                .onChange(of: key) { newValue in
                    if let name = provider.secretName {
                        SecretsStore.set(newValue.trimmingCharacters(in: .whitespaces), for: name)
                    }
                }
            if !provider.availableModels.isEmpty {
                Picker("Modelo", selection: $model) {
                    ForEach(provider.availableModels, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: model) { UserDefaults.standard.set($0, forKey: provider.modelKey) }
            }
            if provider == .elevenLabs {
                Picker("Voz", selection: $voice) {
                    Text("Predeterminada").tag("")
                    ForEach(remoteVoices, id: \.id) { v in Text(v.label).tag(v.id) }
                }
                .onChange(of: voice) { UserDefaults.standard.set($0, forKey: provider.voiceKey) }
                Button("Actualizar lista de voces") { loadRemoteVoices() }
                    .font(.system(size: 11))
            } else if !provider.suggestedVoices.isEmpty {
                Picker("Voz", selection: $voice) {
                    ForEach(provider.suggestedVoices, id: \.id) { v in Text(v.label).tag(v.id) }
                }
                .onChange(of: voice) { UserDefaults.standard.set($0, forKey: provider.voiceKey) }
            }
            HStack(spacing: 8) {
                Button {
                    testKey()
                } label: {
                    if testing { ProgressView().controlSize(.small) }
                    else { Label("Probar clave", systemImage: "checkmark.seal") }
                }
                .disabled(key.isEmpty || testing)
                if let url = provider.docsURL {
                    Link("Obtener clave", destination: url).font(.system(size: 11))
                }
            }
            if let testResult {
                Text(testResult)
                    .font(.system(size: 10))
                    .foregroundColor(testResult.hasPrefix("✓") ? .green : .red)
            }
        }
    }

    private func loadProviderState(_ p: TTSProviderID) {
        model = p.configuredModel
        voice = p.configuredVoice
        key = p.secretName.map { SecretsStore.get($0) } ?? ""
        testResult = nil
        localVoices = TTSEngines.installedLocalVoices()
        if localVoiceID.isEmpty { localVoiceID = localVoices.first?.id ?? "" }
        if p == .elevenLabs { loadRemoteVoices() }
    }

    private func loadRemoteVoices() {
        TTSEngines.fetchElevenLabsVoices { list in
            DispatchQueue.main.async { remoteVoices = list }
        }
    }

    private func testKey() {
        testing = true
        testResult = nil
        TTSEngines.validate(provider: provider, apiKey: key) { result in
            DispatchQueue.main.async {
                testing = false
                switch result {
                case .success: testResult = "✓ Clave válida"
                case .failure(let e): testResult = "✗ \(e.localizedDescription)"
                }
            }
        }
    }
}
