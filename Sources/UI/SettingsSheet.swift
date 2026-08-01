import AppKit
import AVFoundation
import SwiftUI

// Configuración central de la app: General / Ensayo IA / Acerca de.
// Accesible desde el engranaje del sidebar y el menú BtoPrompter → Configuración (⌘,).

struct SettingsSheet: View {
    @EnvironmentObject var model: PrompterModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralSettingsTab()
                    .tabItem { Label("General", systemImage: "gearshape") }
                VoiceSettingsTab()
                    .tabItem { Label("Voz", systemImage: "waveform.and.mic") }
                DiagnosticsSettingsTab()
                    .tabItem { Label("Diagnóstico", systemImage: "stethoscope") }
                ScrollView {
                    AIConfigForm().padding(16)
                }
                .tabItem { Label("Ensayo IA", systemImage: "sparkles") }
                RemoteTab()
                    .tabItem { Label("Remoto", systemImage: "iphone.radiowaves.left.and.right") }
                AboutTab()
                    .tabItem { Label("Acerca de", systemImage: "info.circle") }
            }
            HStack {
                Spacer()
                Button("Listo") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 680, height: 620)
    }
}

struct GeneralSettingsTab: View {
    @EnvironmentObject var model: PrompterModel
    @ObservedObject private var slideSync = SlideSync.shared

    private var slideSyncStatus: String? { slideSync.status }

    var body: some View {
        Form {
            Section("Lectura") {
                HStack {
                    Text("Velocidad: \(model.wpm) ppm")
                    Slider(value: .init(
                        get: { Double(model.wpm) },
                        set: { model.wpm = Int($0) }
                    ), in: 60...400, step: 10)
                }
                HStack {
                    Text("Letra del prompter: \(Int(model.fontSize)) pt")
                    Slider(value: $model.fontSize, in: 20...72, step: 2)
                }
                HStack {
                    Text("Letra del modo mini: \(Int(model.miniFontSize)) pt")
                    Slider(value: $model.miniFontSize, in: 14...32, step: 2)
                }
                HStack {
                    Text("Opacidad del fondo: \(Int(model.bgOpacity * 100)) %")
                    Slider(value: $model.bgOpacity, in: 0...1)
                }
                Picker("Color del resaltado", selection: $model.accentColorID) {
                    ForEach(Theme.highlights, id: \.id) { h in
                        Text(h.name).foregroundColor(h.color).tag(h.id)
                    }
                }
            }
            Section("Comportamiento") {
                Toggle("Invisible al compartir pantalla (modo espía)", isOn: $model.spyMode)
                Toggle("Los títulos (#, ##) son guías que no se leen", isOn: $model.guideTitles)
                Toggle("Recordar el modo minimalista entre sesiones", isOn: $model.miniMode)
                Toggle("Reproducir automáticamente al entrar al prompter", isOn: $model.autoPlay)
                Toggle("Mantener la pantalla despierta durante el prompter", isOn: $model.keepAwake)
                Toggle("Seguirme por voz (proveedor configurable en la pestaña Voz)", isOn: $model.voiceFollow)
                Toggle("Cronómetro de ensayo: estadísticas y calibración al terminar", isOn: $model.rehearsalStats)
                Stepper(value: $model.countdownSeconds, in: 0...10) {
                    Text(model.countdownSeconds == 0
                         ? "Cuenta regresiva: desactivada"
                         : "Cuenta regresiva: \(model.countdownSeconds) s antes de arrancar")
                }
            }
            Section("Diapositivas automáticas") {
                Toggle("Avanzar la presentación al cruzar una guía \"// Diapositiva N\"", isOn: .init(
                    get: { SlideSync.shared.enabled },
                    set: { SlideSync.shared.enabled = $0 }
                ))
                Picker("Aplicación", selection: .init(
                    get: { SlideSync.shared.targetApp },
                    set: { SlideSync.shared.targetApp = $0 }
                )) {
                    ForEach(SlideSync.targets, id: \.id) { t in
                        Text(t.name).tag(t.id)
                    }
                }
                HStack {
                    Button("Probar avance ahora") {
                        let wasEnabled = SlideSync.shared.enabled
                        SlideSync.shared.enabled = true
                        SlideSync.shared.advanceSlide()
                        SlideSync.shared.enabled = wasEnabled
                    }
                    if let s = slideSyncStatus {
                        Text(s).font(.system(size: 10)).foregroundColor(.red)
                    }
                }
                Text("Requiere la presentación abierta en modo presentación y permiso de Automatización la primera vez. Solo avanza hacia adelante.")
                    .font(.system(size: 10)).foregroundColor(.gray)
            }
            Section("Atajos") {
                Text("Prompter:  ␣ play/pausa · ← → ±10 palabras · ⇧← ⇧→ ±1 palabra · 1–9 ir a sección · ↑ ↓ velocidad · + − letra · [ ] transparencia · M modo mini · R reiniciar · Esc editor")
                    .font(.system(size: 11)).foregroundColor(.gray)
                Text("Globales (desde cualquier app, con el prompter activo):  ⌥⌘P play/pausa · ⌥⌘↑ ⌥⌘↓ velocidad")
                    .font(.system(size: 11)).foregroundColor(.gray)
            }
        }
        .formStyle(.grouped)
    }
}

struct VoiceSettingsTab: View {
    @EnvironmentObject var model: PrompterModel
    @ObservedObject private var appleModels = AppleSpeechModelManager.shared
    @ObservedObject private var speechPlayback = SpeechPlayback.shared

    @State private var primary: VoiceProviderID
    @State private var firstFallback: VoiceProviderID
    @State private var failover: Bool
    @State private var cloudConsent: Bool
    @State private var language: String
    @State private var autoDownloadApple: Bool
    @State private var sensitivity: Double
    @State private var maxJump: Int
    @State private var confirmJumps: Bool
    @State private var ttsVoiceIdentifier: String
    @State private var ttsRate: Double

    init() {
        let initialPrimary = VoiceProviderID(
            rawValue: Settings.string(.voiceProvider, default: VoiceProviderID.appleLocal.rawValue)
        ) ?? .appleLocal
        _primary = State(initialValue: initialPrimary)
        let savedFallback = Settings.string(.voiceFailoverOrder, default: "")
            .split(separator: ",").first.flatMap { VoiceProviderID(rawValue: String($0)) }
        let initialFallback = savedFallback.flatMap { $0 == initialPrimary ? nil : $0 }
            ?? VoiceProviderID.allCases.first(where: { $0 != initialPrimary })
            ?? .appleCloud
        _firstFallback = State(initialValue: initialFallback)
        _failover = State(initialValue: Settings.bool(.voiceFailoverEnabled, default: true))
        _cloudConsent = State(initialValue: Settings.bool(.voiceCloudConsent, default: false))
        _language = State(initialValue: Settings.string(.voiceLanguage, default: "es-EC"))
        _autoDownloadApple = State(initialValue: Settings.bool(.voiceAutoDownloadAppleModel, default: true))
        _sensitivity = State(initialValue: Settings.double(.voiceMatchSensitivity, default: 0.76))
        _maxJump = State(initialValue: Settings.int(.voiceMaxJump, default: 60))
        _confirmJumps = State(initialValue: Settings.bool(.voiceConfirmLargeJumps, default: true))
        _ttsVoiceIdentifier = State(initialValue: Settings.string(.ttsVoiceIdentifier, default: ""))
        _ttsRate = State(initialValue: Settings.double(
            .ttsRate, default: Double(AVSpeechUtteranceDefaultSpeechRate)))
    }

    var body: some View {
        Form {
            Section("Seguimiento") {
                Toggle("Activar seguimiento por voz", isOn: $model.voiceFollow)
                Picker("Proveedor principal", selection: $primary) {
                    ForEach(VoiceProviderID.allCases) { provider in
                        Text(provider.name).tag(provider)
                    }
                }
                Toggle("Cambiar automáticamente a un respaldo si falla", isOn: $failover)
                Picker("Primer respaldo", selection: $firstFallback) {
                    ForEach(VoiceProviderID.allCases.filter { $0 != primary }) { provider in
                        Text(provider.name).tag(provider)
                    }
                }
                .disabled(!failover)
                HStack {
                    Circle()
                        .fill(model.voiceActive ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(model.voiceStatus ?? model.voiceProviderState.label)
                        .font(.system(size: 11))
                        .foregroundColor(model.voiceStatus != nil || model.voiceProviderState.isFailure
                                         ? .orange : .secondary)
                    Spacer()
                    Button("Permisos…") { VoiceTracker.shared.requestPermissions { _ in } }
                }
                Text("El respaldo omite automáticamente proveedores sin autorización o sin API key. Nunca escucha con dos motores a la vez.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            Section("Apple local") {
                Picker("Idioma", selection: $language) {
                    Text("Español — Ecuador").tag("es-EC")
                    Text("Español — España").tag("es-ES")
                    Text("Español — México").tag("es-MX")
                    Text("Español — Estados Unidos").tag("es-US")
                    Text("English — United States").tag("en-US")
                }
                Toggle("Descargar el modelo automáticamente cuando haga falta",
                       isOn: $autoDownloadApple)
                HStack {
                    Text("Modelo de dictado: \(appleModels.status)")
                        .font(.system(size: 11))
                    Spacer()
                    if appleModels.busy {
                        Button("Pausar") { appleModels.cancel() }
                    } else {
                        Button("Descargar / continuar") { appleModels.download() }
                    }
                    Button("Comprobar") { appleModels.refresh() }
                }
                if appleModels.busy || appleModels.progress > 0 && appleModels.progress < 1 {
                    ProgressView(value: appleModels.progress)
                }
                Text("El modelo lo administra macOS y permanece instalado para próximos usos. Apple local no envía tu audio fuera del Mac.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            Section("Proveedores externos") {
                Toggle("Autorizo enviar mi voz en vivo al proveedor que yo elija",
                       isOn: $cloudConsent)
                Text("Sin esta autorización, BtoPrompter usa únicamente alternativas locales. Las claves se guardan en este Mac y nunca se escriben en los logs.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                ForEach(VoiceProviderID.allCases.filter { $0.secretName != nil }) { provider in
                    if let secretName = provider.secretName {
                        VStack(alignment: .leading, spacing: 3) {
                            SecureField("API key de \(provider.name)", text: Binding(
                                get: { SecretsStore.get(secretName) },
                                set: { SecretsStore.set($0, for: secretName) }
                            ))
                            Text("\(provider.defaultModel) · \(provider.privacyNote)")
                                .font(.system(size: 9)).foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section("Lectura en voz alta (TTS local)") {
                Picker("Voz", selection: $ttsVoiceIdentifier) {
                    Text("Automática según el idioma").tag("")
                    ForEach(SpeechPlayback.availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) — \(voice.language)").tag(voice.identifier)
                    }
                }
                HStack {
                    Text("Ritmo")
                    Slider(value: $ttsRate, in: 0.30...0.68, step: 0.01)
                    Button(speechPlayback.speaking ? "Detener" : "Probar") {
                        if speechPlayback.speaking { speechPlayback.stop() }
                        else { speechPlayback.speak("Hola. Esta es la voz de lectura de BtoPrompter.") }
                    }
                }
                Text("Usa voces instaladas en macOS y no envía el discurso a internet. En el editor, el botón de altavoz lee o detiene el discurso completo.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            Section("Seguridad de alineación") {
                HStack {
                    Text("Confianza mínima: \(Int(sensitivity * 100)) %")
                    Slider(value: $sensitivity, in: 0.55...0.95, step: 0.01)
                }
                Stepper("Salto máximo: \(maxJump) palabras", value: $maxJump,
                        in: 10...200, step: 5)
                Toggle("Confirmar saltos grandes antes de mover el guion", isOn: $confirmJumps)
                Text("Las frases repetidas siempre esperan palabras de contexto únicas y el seguimiento nunca retrocede por sí solo.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            normalizeFallback(for: primary)
            appleModels.refresh()
        }
        .onChange(of: primary) { value in
            Settings.set(value.rawValue, .voiceProvider)
            normalizeFallback(for: value)
            VoiceTracker.shared.restartIfRunning()
        }
        .onChange(of: failover) { Settings.set($0, .voiceFailoverEnabled) }
        .onChange(of: firstFallback) { value in
            Settings.set(value.rawValue, .voiceFailoverOrder)
        }
        .onChange(of: cloudConsent) { value in
            Settings.set(value, .voiceCloudConsent)
            VoiceTracker.shared.restartIfRunning()
        }
        .onChange(of: language) { value in
            Settings.set(value, .voiceLanguage)
            appleModels.refresh()
            VoiceTracker.shared.restartIfRunning()
        }
        .onChange(of: autoDownloadApple) { Settings.set($0, .voiceAutoDownloadAppleModel) }
        .onChange(of: sensitivity) { Settings.set($0, .voiceMatchSensitivity) }
        .onChange(of: maxJump) { Settings.set($0, .voiceMaxJump) }
        .onChange(of: confirmJumps) { Settings.set($0, .voiceConfirmLargeJumps) }
        .onChange(of: ttsVoiceIdentifier) { Settings.set($0, .ttsVoiceIdentifier) }
        .onChange(of: ttsRate) { Settings.set($0, .ttsRate) }
    }

    private func normalizeFallback(for provider: VoiceProviderID) {
        guard firstFallback == provider,
              let replacement = VoiceProviderID.allCases.first(where: { $0 != provider }) else { return }
        firstFallback = replacement
        Settings.set(replacement.rawValue, .voiceFailoverOrder)
    }
}

struct DiagnosticsSettingsTab: View {
    @ObservedObject private var speakingProfile = SpeakingProfileStore.shared
    @State private var enabled = Settings.bool(.diagnosticsEnabled, default: false)
    @State private var recordAudio = Settings.bool(.diagnosticsRecordAudio, default: false)
    @State private var includeScript = Settings.bool(.diagnosticsIncludeScript, default: true)
    @State private var retentionDays = Settings.int(.diagnosticsRetentionDays, default: 14)
    @State private var maxMegabytes = Settings.int(.diagnosticsMaxMegabytes, default: 500)
    @State private var profileEnabled = Settings.bool(.speechProfileEnabled, default: false)
    @State private var profileMinimum = Settings.int(.speechProfileMinimumSessions, default: 3)
    @State private var shareProfileWithAI = Settings.bool(.speechProfileShareWithAI, default: false)
    @State private var showDeleteConfirmation = false
    @State private var showResetProfileConfirmation = false

    var body: some View {
        Form {
            Section("Registro local") {
                Toggle("Guardar eventos detallados de seguimiento", isOn: $enabled)
                Toggle("Grabar solo mi voz durante el prompter", isOn: $recordAudio)
                Toggle("Guardar una copia del guion junto al diagnóstico", isOn: $includeScript)
                    .disabled(!enabled)
                if recordAudio {
                    Label("Grabación activa cuando el micrófono escucha. Los archivos quedan únicamente en este Mac.",
                          systemImage: "record.circle")
                        .font(.system(size: 10)).foregroundColor(.orange)
                }
                Text("Se registran proveedor, transcripciones parciales y decisiones de avance. Las API keys y tokens se ocultan.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            Section("Límites automáticos") {
                Stepper("Conservar sesiones: \(retentionDays) días", value: $retentionDays,
                        in: 1...90)
                Stepper("Espacio máximo: \(maxMegabytes) MB", value: $maxMegabytes,
                        in: 50...5_000, step: 50)
                Text("El log operativo rota a 2 MB. Las sesiones más antiguas se eliminan primero al superar estos límites.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            Section("Mi forma de hablar") {
                Toggle("Aprender localmente mi ritmo y estilo de expresión",
                       isOn: $profileEnabled)
                Stepper("Ensayos mínimos antes de usar el perfil: \(profileMinimum)",
                        value: $profileMinimum, in: 1...20)
                    .disabled(!profileEnabled)
                Toggle("Autorizo incluir este resumen al usar Ensayo con IA",
                       isOn: $shareProfileWithAI)
                    .disabled(!profileEnabled)
                Text(speakingProfile.summary)
                    .font(.system(size: 11, weight: .semibold))
                if !speakingProfile.stylePrompt.isEmpty {
                    Text(speakingProfile.stylePrompt)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Copiar perfil") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(speakingProfile.stylePrompt, forType: .string)
                    }
                    .disabled(speakingProfile.stylePrompt.isEmpty)
                    Button("Reiniciar perfil…", role: .destructive) {
                        showResetProfileConfirmation = true
                    }
                    .disabled(speakingProfile.profile.sessionCount == 0)
                }
                Text("El aprendizaje guarda únicamente estadísticas en este Mac. Compartirlas con la IA requiere el permiso separado de arriba y solo ocurre al pulsar Ensayo con IA.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            Section("Archivos") {
                HStack {
                    Button("Abrir carpeta de diagnóstico") {
                        NSWorkspace.shared.open(VoiceDiagnostics.shared.directoryURL)
                    }
                    Button("Eliminar sesiones…", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
                Text(VoiceDiagnostics.shared.directoryURL.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onChange(of: enabled) { Settings.set($0, .diagnosticsEnabled) }
        .onChange(of: recordAudio) { Settings.set($0, .diagnosticsRecordAudio) }
        .onChange(of: includeScript) { Settings.set($0, .diagnosticsIncludeScript) }
        .onChange(of: retentionDays) { Settings.set($0, .diagnosticsRetentionDays) }
        .onChange(of: maxMegabytes) { Settings.set($0, .diagnosticsMaxMegabytes) }
        .onChange(of: profileEnabled) { Settings.set($0, .speechProfileEnabled) }
        .onChange(of: profileMinimum) { Settings.set($0, .speechProfileMinimumSessions) }
        .onChange(of: shareProfileWithAI) { Settings.set($0, .speechProfileShareWithAI) }
        .alert("¿Eliminar todas las sesiones de diagnóstico?",
               isPresented: $showDeleteConfirmation) {
            Button("Cancelar", role: .cancel) {}
            Button("Eliminar", role: .destructive) {
                VoiceDiagnostics.shared.deleteAllSessions()
            }
        } message: {
            Text("Se borrarán grabaciones, transcripciones y eventos locales. Esta acción no se puede deshacer.")
        }
        .alert("¿Reiniciar tu perfil local?", isPresented: $showResetProfileConfirmation) {
            Button("Cancelar", role: .cancel) {}
            Button("Reiniciar", role: .destructive) { speakingProfile.reset() }
        } message: {
            Text("Se borrarán las estadísticas aprendidas de tus ensayos. Las grabaciones de diagnóstico no se modificarán.")
        }
    }
}

struct RemoteTab: View {
    @ObservedObject private var remote = RemoteControl.shared

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { Settings.bool(.remoteEnabled, default: false) },
            set: { on in
                Settings.set(on, .remoteEnabled)
                if on { remote.start() } else { remote.stop() }
            }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            Toggle("Activar control remoto desde el teléfono", isOn: enabledBinding)
                .toggleStyle(.switch)
            Text("Abre la dirección en tu iPhone (misma red Wi-Fi) y tendrás play/pausa, velocidad y saltos en la mano. Protegido con un código en la dirección; solo funciona en tu red local.")
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if remote.running, let url = remote.url {
                if let qr = Self.qrImage(url) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 150, height: 150)
                        .background(Color.white)
                        .cornerRadius(8)
                }
                Text(url)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                Text("Escanea el QR con la cámara del iPhone")
                    .font(.system(size: 10)).foregroundColor(.gray)
            } else if let status = remote.status {
                Text(status).font(.system(size: 11)).foregroundColor(.red)
            }
            Spacer()
        }
        .padding(16)
    }

    private static func qrImage(_ string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

struct AboutTab: View {
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)
            Text("BtoPrompter")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Versión \(checker.currentVersion)")
                .foregroundColor(.gray)
            Text("Teleprompter invisible al compartir pantalla.\nCódigo abierto bajo licencia MIT.")
                .multilineTextAlignment(.center)
                .font(.system(size: 12))
                .foregroundColor(.gray)
            HStack(spacing: 12) {
                Button {
                    checker.check()
                } label: {
                    if checker.checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Buscar actualizaciones", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                if checker.latestURL != nil {
                    Button {
                        checker.applyUpdate()
                    } label: {
                        if checker.installing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(checker.autoInstall ? "Actualizar ahora" : "Descargar",
                                  systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(checker.installing)
                }
            }
            Toggle("Instalar actualizaciones automáticamente (sin abrir el navegador)", isOn: .init(
                get: { checker.autoInstall },
                set: { checker.autoInstall = $0 }
            ))
            .font(.system(size: 11))
            if let status = checker.status {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(status.contains("✓") ? .green : .orange)
            }
            Link("github.com/btoaldas/BtoPrompter",
                 destination: URL(string: "https://github.com/btoaldas/BtoPrompter")!)
                .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
