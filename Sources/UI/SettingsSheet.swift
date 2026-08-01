import AppKit
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
        .frame(width: 520, height: 480)
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
                Toggle("Seguirme por voz: avanzar escuchándome (local, pide micrófono)", isOn: $model.voiceFollow)
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
