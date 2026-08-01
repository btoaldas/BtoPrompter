import SwiftUI

// Raíz de la interfaz: decide entre biblioteca/editor y prompter.
struct ContentView: View {
    @EnvironmentObject var model: PrompterModel
    @EnvironmentObject var store: SpeechStore

    var body: some View {
        ZStack {
            Color.black
                .opacity(model.mode == .editing ? Theme.editorBackgroundOpacity : model.bgOpacity)
                .ignoresSafeArea()
            if model.mode == .editing {
                LibraryView()
            } else {
                PrompterView()
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet()
                .environmentObject(model)
        }
    }
}

struct LibraryView: View {
    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 340)
            EditorPane()
                .frame(minWidth: 420, maxWidth: .infinity)
        }
    }
}
