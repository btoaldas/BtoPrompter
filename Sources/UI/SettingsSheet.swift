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
            }
            Section("Comportamiento") {
                Toggle("Invisible al compartir pantalla (modo espía)", isOn: $model.spyMode)
                Toggle("Los títulos (#, ##) son guías que no se leen", isOn: $model.guideTitles)
                Toggle("Recordar el modo minimalista entre sesiones", isOn: $model.miniMode)
            }
            Section("Atajos") {
                Text("Prompter:  ␣ play/pausa · ← → ±10 palabras · ↑ ↓ velocidad · + − letra · [ ] transparencia · M modo mini · R reiniciar · Esc editor")
                    .font(.system(size: 11)).foregroundColor(.gray)
                Text("Globales (desde cualquier app, con el prompter activo):  ⌥⌘P play/pausa · ⌥⌘↑ ⌥⌘↓ velocidad")
                    .font(.system(size: 11)).foregroundColor(.gray)
            }
        }
        .formStyle(.grouped)
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
                        checker.openDownload()
                    } label: {
                        Label("Descargar", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
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
