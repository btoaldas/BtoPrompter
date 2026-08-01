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

struct SpyToggle: View {
    @EnvironmentObject var model: PrompterModel

    var body: some View {
        Button {
            model.spyMode.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.spyMode ? "eye.slash.fill" : "eye.fill")
                Text(model.spyMode ? "Invisible al compartir" : "VISIBLE al compartir")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(model.spyMode ? Theme.spyOn : Theme.spyOff)
        }
        .buttonStyle(.plain)
        .help("Con el ojo tachado, la ventana NO aparece en Zoom/Teams ni en capturas de pantalla")
    }
}
