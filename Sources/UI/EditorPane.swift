import AppKit
import SwiftUI

// Editor del discurso seleccionado: título, cuerpo, ajustes rápidos y arranque.

struct EditorPane: View {
    @EnvironmentObject var model: PrompterModel
    @EnvironmentObject var store: SpeechStore
    @State var showAISheet = false
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
                Text("Atajos en el prompter:  ␣ play/pausa · ← → saltar 10 palabras · ↑ ↓ velocidad · + − letra · [ ] transparencia · R reiniciar · Esc volver aquí")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
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

    private func actionsRow(_ doc: SpeechDoc) -> some View {
        HStack(spacing: 14) {
            Button {
                if let s = NSPasteboard.general.string(forType: .string) {
                    bodyDraft = s
                    draftDocID = doc.id
                    store.update(doc.id) { $0.body = s }
                }
            } label: {
                Label("Pegar", systemImage: "doc.on.clipboard")
            }
            Button {
                bodyDraft = ""
                draftDocID = doc.id
                store.update(doc.id) { $0.body = "" }
            } label: {
                Label("Limpiar", systemImage: "trash")
            }
            Text("Guardado automático ✓")
                .font(.system(size: 10))
                .foregroundColor(.gray)
            Spacer()
            HStack(spacing: 6) {
                Button("−") { model.changeSpeed(-Settings.Limits.wpmStep) }
                Text("\(model.wpm) ppm")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 74)
                Button("+") { model.changeSpeed(+Settings.Limits.wpmStep) }
            }
            .help("Velocidad en palabras por minuto")
            HStack(spacing: 4) {
                Text("Meta").font(.system(size: 11)).foregroundColor(.gray)
                TextField("min", text: .init(
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
                .frame(width: 44)
                Text("min").font(.system(size: 11)).foregroundColor(.gray)
            }
            .help("Duración objetivo: al terminar un ensayo te digo qué velocidad necesitas para cumplirla")
            Button {
                showAISheet = true
            } label: {
                Label(model.aiEnabled ? "Ensayo IA" : "IA…", systemImage: "sparkles")
            }
            .help("Ensayo con IA: marca el ritmo del discurso (pausas, énfasis, velocidades) sin cambiar tus palabras")
            Button {
                model.startPrompter()
            } label: {
                Label("Iniciar", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundColor(.black)
            .disabled(doc.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
