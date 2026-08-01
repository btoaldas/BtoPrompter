import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Barra lateral de la biblioteca: carpetas, discursos, borradores, archivados,
// importación de archivos y acciones por fila (menú contextual).

struct SidebarView: View {
    @EnvironmentObject var model: PrompterModel
    @EnvironmentObject var store: SpeechStore
    @State private var newFolderPrompt = false
    @State private var newFolderName = ""
    @State private var pendingDelete: SpeechDoc? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            importStatusRow
            speechList
        }
        .background(Color.white.opacity(0.04))
        .alert("Nueva carpeta", isPresented: $newFolderPrompt) {
            TextField("Nombre", text: $newFolderName)
            Button("Crear") {
                store.addFolder(newFolderName)
                newFolderName = ""
            }
            Button("Cancelar", role: .cancel) { newFolderName = "" }
        }
        .alert("¿Eliminar \"\(pendingDelete?.title ?? "")\"?", isPresented: .init(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Eliminar", role: .destructive) {
                if let doc = pendingDelete {
                    store.delete(doc.id)
                    if model.selectedID == doc.id { model.selectedID = store.library.speeches.first?.id }
                }
                pendingDelete = nil
            }
            Button("Cancelar", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Esta acción no se puede deshacer. Si prefieres conservarlo, usa Archivar.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("BtoPrompter")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(Theme.accent)
            Spacer()
            Button {
                model.selectedID = store.newSpeech().id
            } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.plain).help("Nuevo discurso")
            Button { newFolderPrompt = true } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.plain).help("Nueva carpeta")
            Button { openImportPanel() } label: { Image(systemName: "square.and.arrow.down") }
                .buttonStyle(.plain).help("Importar archivos (txt, md, pptx, audio)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var importStatusRow: some View {
        if let status = store.importStatus {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(status).font(.system(size: 11)).foregroundColor(.orange)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    private var speechList: some View {
        List {
            Section("Discursos") {
                ForEach(store.speeches(inFolder: "", archived: false)) { doc in
                    row(doc)
                }
            }
            ForEach(store.allFolders, id: \.self) { folder in
                Section {
                    ForEach(store.speeches(inFolder: folder, archived: false)) { doc in
                        row(doc)
                    }
                } header: {
                    HStack {
                        Label(folder, systemImage: "folder")
                        Spacer()
                    }
                    .contextMenu {
                        Button("Eliminar carpeta (los discursos pasan a la raíz)") {
                            store.deleteFolder(folder)
                        }
                    }
                }
            }
            if !store.archivedSpeeches.isEmpty {
                Section("Archivados") {
                    ForEach(store.archivedSpeeches) { doc in
                        row(doc)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func row(_ doc: SpeechDoc) -> some View {
        HStack(spacing: 6) {
            Image(systemName: doc.isArchived ? "archivebox" : (doc.isDraft ? "doc.badge.clock" : "doc.text"))
                .foregroundColor(doc.id == model.selectedID ? Theme.accent : .gray)
                .font(.system(size: 12))
            Text(doc.title.isEmpty ? "Sin título" : doc.title)
                .lineLimit(1)
                .foregroundColor(doc.id == model.selectedID ? Theme.accent : .white)
            Spacer()
            if doc.isDraft {
                Text("borrador")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.25))
                    .cornerRadius(4)
                    .foregroundColor(.orange)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = doc.id }
        .contextMenu {
            Button("Iniciar prompter") {
                model.selectedID = doc.id
                model.startPrompter()
            }
            Button(doc.isDraft ? "Quitar marca de borrador" : "Marcar como borrador") {
                store.update(doc.id) { $0.isDraft.toggle() }
            }
            Menu("Mover a carpeta") {
                Button("(raíz)") { store.update(doc.id) { $0.folder = "" } }
                ForEach(store.allFolders, id: \.self) { f in
                    Button(f) { store.update(doc.id) { $0.folder = f } }
                }
            }
            Button(doc.isArchived ? "Desarchivar" : "Archivar") {
                store.update(doc.id) { $0.isArchived.toggle() }
            }
            Divider()
            Button("Eliminar…", role: .destructive) { pendingDelete = doc }
        }
    }

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        var types: [UTType] = [.plainText, .audio]
        for ext in ["md", "markdown", "pptx", "m4a", "mp3", "wav", "aac", "aiff"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        panel.message = "Importa discursos desde texto, Markdown, PowerPoint o audio (se transcribe)"
        if panel.runModal() == .OK {
            store.importFiles(urls: panel.urls, folder: "")
        }
    }
}
