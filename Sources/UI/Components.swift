import SwiftUI

// Componentes reutilizables de la interfaz.

struct ControlButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 17
    var color: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(color)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// Cuenta regresiva antes de reproducir: número gigante sobre el contenido.
struct CountdownOverlay: View {
    @EnvironmentObject var model: PrompterModel
    let number: Int
    let compact: Bool

    var body: some View {
        Text("\(max(1, number))")
            .font(.system(size: compact ? 34 : 120, weight: .black, design: .rounded))
            .foregroundColor(Theme.accent)
            .shadow(color: .black.opacity(0.8), radius: 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(compact ? 0.35 : 0.45))
            .contentShape(Rectangle())
            .onTapGesture { model.pause() }
            .help("Toca (o espacio) para cancelar")
    }
}

// Resultado del cronómetro de ensayo al terminar el guion.
struct RehearsalResultOverlay: View {
    @EnvironmentObject var model: PrompterModel
    let result: PrompterModel.RehearsalResult

    private var timeText: String {
        let s = Int(result.seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("🏁 Fin del ensayo")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text("Leíste \(result.words) palabras en \(timeText) — ritmo real \(result.effectiveWpm) ppm")
                .font(.system(size: 13))
            if let target = result.targetMinutes, let suggested = result.suggestedWpm {
                Text(String(format: "Meta: %.1f min → necesitas %d ppm", target, suggested))
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }
            HStack(spacing: 10) {
                Button("Calibrar a mi ritmo (\(result.effectiveWpm) ppm)") {
                    model.wpm = min(max(60, result.effectiveWpm), 400)
                    model.rehearsalResult = nil
                }
                if let suggested = result.suggestedWpm {
                    Button("Usar ritmo de la meta (\(suggested) ppm)") {
                        model.wpm = suggested
                        model.rehearsalResult = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Cerrar") { model.rehearsalResult = nil }
            }
        }
        .padding(20)
        .background(Color.black.opacity(0.92))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.5)))
        .shadow(radius: 16)
    }
}

// Acción secundaria de la barra del editor: solo icono, con ayuda emergente.
// Tamaño fijo para que la fila no cambie de ancho ni recorte etiquetas.
struct IconAction: View {
    let symbol: String
    let help: String
    var tinted: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(tinted ? Theme.accent : .primary)
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .help(help)
    }
}

// Botón compacto de más/menos para los pasos de velocidad.
struct StepperButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
    }
}

struct SpyToggle: View {
    @EnvironmentObject var model: PrompterModel
    // En ventanas estrechas se deja solo el ojo: el texto completo se
    // recortaba y quedaba ilegible.
    var compact: Bool = false

    var body: some View {
        Button {
            model.spyMode.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.spyMode ? "eye.slash.fill" : "eye.fill")
                if !compact {
                    Text(model.spyMode ? "Invisible al compartir" : "VISIBLE al compartir")
                        .font(.system(size: 11, weight: .semibold))
                        .fixedSize()
                }
            }
            .foregroundColor(model.spyMode ? Theme.spyOn : Theme.spyOff)
        }
        .buttonStyle(.plain)
        .help(model.spyMode
              ? "Invisible al compartir pantalla. Púlsalo para hacerla visible."
              : "VISIBLE al compartir pantalla. Púlsalo para ocultarla en Zoom, Teams y capturas.")
    }
}
