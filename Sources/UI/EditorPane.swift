import AppKit
import SwiftUI

// Editor del discurso seleccionado: título, cuerpo, ajustes rápidos y arranque.

struct EditorPane: View {
    @EnvironmentObject var model: PrompterModel
    @EnvironmentObject var store: SpeechStore
    @State var showAISheet = false
    @ObservedObject private var speechPlayback = SpeechPlayback.shared
    // Borrador local del cuerpo: el TextEditor NUNCA escribe directo al store.
    // Evita que el buffer vacío del NSTextView pise un discurso al cambiar de
    // selección (pérdida de datos observada con el binding directo).
    @State private var bodyDraft: String = ""
    @State private var draftDocID: UUID? = nil

    private var titleBinding: Binding<String> {
        Binding(
            get: { store.speech(model.selectedID)?.title ?? "" },
            set: { v in if let id = model.selectedID { store.update(id) { $0.title = v } } }
        )
    }

    private var bodyBinding: Binding<String> {
        Binding(
            get: { bodyDraft },
            set: { v in
                bodyDraft = v
                // Solo persiste si el borrador pertenece al documento visible.
                if let id = model.selectedID, id == draftDocID {
                    store.update(id) { $0.body = v }
                }
            }
        )
    }

    private func syncDraft() {
        if let doc = store.speech(model.selectedID) {
            bodyDraft = doc.body
            draftDocID = doc.id
        } else {
            bodyDraft = ""
            draftDocID = nil
        }
    }

    var body: some View {
        if let doc = store.speech(model.selectedID) {
            VStack(spacing: 10) {
                headerRow(doc)
                editorArea(doc)
                actionsRow(doc)
                Text("En el prompter:  ␣ play/pausa · ← → ±10 palabras · ⇧← ⇧→ ±1 · 1–9 secciones · ↑ ↓ velocidad · + − letra · [ ] transparencia · M mini · R reiniciar · Esc volver")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .onAppear { syncDraft() }
            .onReceive(model.$selectedID.removeDuplicates()) { _ in syncDraft() }
            .onReceive(store.$library) { _ in
                // Cambios externos al documento visible (p. ej. Ensayo IA) refrescan el borrador.
                if let doc = store.speech(model.selectedID), doc.id == draftDocID,
                   doc.body != bodyDraft {
                    bodyDraft = doc.body
                }
            }
            .sheet(isPresented: $showAISheet) {
                AISheet().environmentObject(model)
            }
        } else {
            emptyState
        }
    }

    private func headerRow(_ doc: SpeechDoc) -> some View {
        HStack {
            TextField("Título del discurso", text: titleBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Spacer()
            Toggle("Borrador", isOn: .init(
                get: { doc.isDraft },
                set: { v in store.update(doc.id) { $0.isDraft = v } }
            ))
            .toggleStyle(.checkbox)
            .help("Marca este discurso como borrador")
            Toggle("Títulos = guía", isOn: $model.guideTitles)
                .toggleStyle(.checkbox)
                .help("Los títulos (#, ##) se ven en azul pero el karaoke NO los lee — sirven de referencia, ej. \"Diapositiva 1\". Las líneas que empiezan con // siempre son guía.")
            SpyToggle()
        }
    }

    private func editorArea(_ doc: SpeechDoc) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: bodyBinding)
                .id(doc.id)   // NSTextView nuevo por documento: sin buffers cruzados
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
            if doc.body.isEmpty {
                Text("Pega aquí tu discurso… Soporta Markdown (# títulos, - viñetas) y guías: las líneas que empiezan con // se ven en el prompter pero no se leen (ej: // Diapositiva 1)")
                    .foregroundColor(.gray)
                    .padding(.top, 8)
                    .padding(.leading, 6)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Barra de acciones

    // Piezas reutilizables: la fila se arma en tres densidades y se elige la
    // que quepa, para que al estrechar la ventana no se recorte ningún control.
    private func toolIcons(_ doc: SpeechDoc) -> some View {
        HStack(spacing: 3) {
            IconAction(symbol: "doc.on.clipboard", help: "Pegar el portapapeles") {
                if let s = NSPasteboard.general.string(forType: .string) {
                    bodyDraft = s
                    draftDocID = doc.id
                    store.update(doc.id) { $0.body = s }
                }
            }
            IconAction(symbol: "trash", help: "Vaciar el discurso") {
                bodyDraft = ""
                draftDocID = doc.id
                store.update(doc.id) { $0.body = "" }
            }
            IconAction(symbol: speechPlayback.speaking ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       help: speechPlayback.speaking ? "Detener la lectura" : "Escuchar el discurso") {
                if speechPlayback.speaking { speechPlayback.stop() }
                else { speechPlayback.speak(doc.body) }
            }
            IconAction(symbol: "doc.richtext", help: "Exportar a PDF") { exportPDF(doc) }
            IconAction(symbol: "sparkles", help: "Ensayo con IA: marca el ritmo sin cambiar tus palabras",
                       tinted: model.aiEnabled) { showAISheet = true }
        }
    }

    private func speedControl(showUnit: Bool) -> some View {
        HStack(spacing: 2) {
            StepperButton(symbol: "minus") { model.changeSpeed(-Settings.Limits.wpmStep) }
            Text("\(model.wpm)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 30)
            StepperButton(symbol: "plus") { model.changeSpeed(+Settings.Limits.wpmStep) }
            if showUnit {
                Text("ppm").font(.system(size: 10)).foregroundColor(.secondary).fixedSize()
            }
        }
        .help("Velocidad de lectura en palabras por minuto")
    }

    private func targetControl(_ doc: SpeechDoc, showUnit: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "target").font(.system(size: 10)).foregroundColor(.secondary)
            TextField("—", text: .init(
                get: {
                    guard let t = doc.targetMinutes else { return "" }
                    return t == t.rounded() ? String(Int(t)) : String(format: "%.1f", t)
                },
                set: { v in
                    let parsed = Double(v.replacingOccurrences(of: ",", with: "."))
                    store.update(doc.id) { $0.targetMinutes = parsed }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 38)
            if showUnit {
                Text("min").font(.system(size: 10)).foregroundColor(.secondary).fixedSize()
            }
        }
        .help("Duración objetivo del discurso: al terminar el ensayo te digo qué velocidad necesitas")
    }

    private func startButton(_ doc: SpeechDoc, compact: Bool) -> some View {
        Button {
            model.startPrompter()
        } label: {
            if compact {
                Image(systemName: "play.fill").frame(width: 22)
            } else {
                Label("Iniciar", systemImage: "play.fill").fixedSize()
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .foregroundColor(.black)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(doc.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Iniciar el prompter (⌘⏎)")
    }

    private func actionsRow(_ doc: SpeechDoc) -> some View {
        ViewThatFits(in: .horizontal) {
            // Completa
            HStack(spacing: 8) {
                toolIcons(doc)
                Divider().frame(height: 18)
                speedControl(showUnit: true)
                targetControl(doc, showUnit: true)
                Spacer(minLength: 6)
                Text("Guardado ✓").font(.system(size: 10))
                    .foregroundColor(.secondary).fixedSize()
                startButton(doc, compact: false)
            }
            // Sin la nota de guardado
            HStack(spacing: 10) {
                toolIcons(doc)
                Divider().frame(height: 18)
                speedControl(showUnit: true)
                targetControl(doc, showUnit: true)
                Spacer(minLength: 6)
                startButton(doc, compact: false)
            }
            // Sin unidades escritas
            HStack(spacing: 8) {
                toolIcons(doc)
                speedControl(showUnit: false)
                targetControl(doc, showUnit: false)
                Spacer(minLength: 4)
                startButton(doc, compact: false)
            }
            // Mínima: todo en iconos
            HStack(spacing: 6) {
                toolIcons(doc)
                speedControl(showUnit: false)
                Spacer(minLength: 2)
                startButton(doc, compact: true)
            }
        }
        .frame(height: 28)
    }

    private func exportPDF(_ doc: SpeechDoc) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (doc.title.isEmpty ? "Discurso" : doc.title) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PDFExporter.export(title: doc.title, body: doc.body,
                                   guideTitles: model.guideTitles, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            store.importStatus = "Error al exportar PDF: \(error.localizedDescription)"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 40))
                .foregroundColor(.gray)
            Text("Selecciona un discurso o crea uno nuevo")
                .foregroundColor(.gray)
            Button("Nuevo discurso") {
                model.selectedID = store.newSpeech().id
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundColor(.black)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
