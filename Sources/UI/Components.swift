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
