//
//  SongsView.swift
//  scripty
//
//  Songs & Notes for a project — the iPad counterpart of the web app's
//  Songs / Notes screens. Add, edit, rename, delete, insert into the
//  screenplay, share a song by email, and import from a file. Every
//  affordance is gated on the links the server advertised.
//

import SwiftUI
import UniformTypeIdentifiers

struct SongsView: View {
    let model: ScriptModel

    @Environment(\.dismiss) private var dismiss
    @State private var listType: DocumentType

    /// Opens on `listType`, so ⌘⇧S and ⌘⇧D reach songs and notes directly the
    /// way the web app's two menu entries do.
    init(model: ScriptModel, listType: DocumentType = .song) {
        self.model = model
        _listType = State(initialValue: listType)
    }

    @State private var editingDocument: TextDocument?
    @State private var creatingType: DocumentType?
    @State private var renamingDocument: TextDocument?
    @State private var renameTitle = ""
    @State private var sharingDocument: TextDocument?
    @State private var shareEmail = ""
    @State private var showingImporter = false
    /// Presented from the link the document collection advertised.
    @State private var trashLink: HALLink?
    @State private var isLoading = false
    @State private var statusMessage: String?
    /// A finished song export waiting to be shared.
    @State private var exportedFile: ExportButton.ExportedFile?

    /// The import link is advertised on the collection only for editors, so it
    /// doubles as the "can add/import" gate — the same rule the web uses.
    private var canEdit: Bool { model.documentsLinks.contains(.importDocument) }

    private var shown: [TextDocument] {
        listType == .song ? model.songs : model.notes
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown) { document in
                    row(for: document)
                }
            }
            .overlay { emptyState }
            .safeAreaInset(edge: .top) { picker }
            .navigationTitle("Songs & Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await reload() }
            .refreshable { await reload() }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: importTypes,
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .sheet(item: $trashLink) { link in
                TrashView<DeletedDocument, DeletedDocumentRow>(
                    app: model.app,
                    source: link,
                    title: "Deleted Songs & Notes",
                    emptyMessage: "Songs and notes you delete can be restored from here.",
                    // A restored document rejoins the list behind us.
                    onChanged: { await model.loadDocuments() }) { document in
                        DeletedDocumentRow(document: document)
                    }
            }
            .sheet(item: $creatingType) { type in
                SongEditorView(model: model, document: nil, type: type)
            }
            .sheet(item: $editingDocument) { document in
                // A song is lyric lines on the server, so it opens the line
                // editor — where reordering, tinting and editions mean
                // something. A note is plain text and keeps the plain editor.
                if document.kind == .song, document.hasLink(.songBlocks) {
                    SongBlockEditorView(app: model.app, document: document)
                } else {
                    SongEditorView(model: model, document: document, type: document.kind)
                }
            }
            .alert("Rename", isPresented: renameBinding) {
                TextField("Title", text: $renameTitle)
                Button("Cancel", role: .cancel) { renamingDocument = nil }
                Button("Save") { commitRename() }
            }
            .alert("Email this song", isPresented: shareBinding) {
                TextField("Recipient email", text: $shareEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) { sharingDocument = nil }
                Button("Send") { commitShare() }
            } message: {
                Text("Send the lyrics to a collaborator.")
            }
            .alert("Songs & Notes",
                   isPresented: Binding(get: { statusMessage != nil },
                                        set: { if !$0 { statusMessage = nil } })) {
                Button("OK", role: .cancel) { statusMessage = nil }
            } message: {
                Text(statusMessage ?? "")
            }
            // A sheet rather than a fourth alert on this view: a failed export
            // is reported through statusMessage above, because more than one
            // alert on a view stops the others — and the sheets — presenting.
            .sheet(item: $exportedFile) { file in
                ShareSheet(items: [file.url])
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for document: TextDocument) -> some View {
        Button {
            editingDocument = document
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(document.displayTitle)
                    .font(.headline)
                if let preview = document.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let updated = document.updatedAt {
                    Text("Edited \(updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .trailing) {
            if document.hasLink(.delete) {
                Button(role: .destructive) {
                    Task { await model.deleteDocument(document) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if document.hasLink(.insert) {
                Button {
                    insert(document)
                } label: {
                    Label("Insert into Script", systemImage: "text.insert")
                }
            }
            if document.hasLink(.update) {
                Button {
                    renameTitle = document.title ?? ""
                    renamingDocument = document
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
            if document.hasLink(.shareEmail) {
                Button {
                    shareEmail = ""
                    sharingDocument = document
                } label: {
                    Label("Email…", systemImage: "envelope")
                }
            }
            // Only songs are advertised export links, so notes show no
            // submenu at all rather than an empty one.
            let exports = model.songExportOptions(for: document)
            if !exports.isEmpty {
                Menu {
                    ForEach(exports) { option in
                        Button(option.label) { export(document, as: option) }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
            if document.hasLink(.delete) {
                Button(role: .destructive) {
                    Task { await model.deleteDocument(document) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if shown.isEmpty {
            if isLoading {
                ProgressView()
            } else {
                ContentUnavailableView(
                    listType == .song ? "No Songs" : "No Notes",
                    systemImage: listType == .song ? "music.note.list" : "note.text",
                    description: Text(canEdit
                        ? "Add \(listType == .song ? "a song" : "a note") to get started."
                        : "Nothing here yet."))
            }
        }
    }

    private var picker: some View {
        Picker("Type", selection: $listType) {
            Text("Songs").tag(DocumentType.song)
            Text("Notes").tag(DocumentType.notes)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        if canEdit {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                Button {
                    creatingType = listType
                } label: {
                    Label(listType == .song ? "New Song" : "New Note", systemImage: "plus")
                }
            }
            if let trash = model.documentsLinks[.trash] {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        trashLink = trash
                    } label: {
                        Label("Deleted Songs & Notes", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func reload() async {
        isLoading = true
        await model.loadDocuments()
        isLoading = false
    }

    private func insert(_ document: TextDocument) {
        Task {
            let count = await model.insertDocument(document)
            if let count, count > 0 {
                dismiss()   // reveal the updated screenplay
            } else if count == 0 {
                statusMessage = "Nothing to insert from \"\(document.displayTitle)\"."
            } else {
                statusMessage = model.errorMessage
            }
        }
    }

    private func commitRename() {
        guard let document = renamingDocument else { return }
        let title = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingDocument = nil
        guard !title.isEmpty else { return }
        Task { await model.renameDocument(document, title: title) }
    }

    private func commitShare() {
        guard let document = sharingDocument else { return }
        let email = shareEmail.trimmingCharacters(in: .whitespaces)
        sharingDocument = nil
        guard !email.isEmpty else { return }
        Task {
            let ok = await model.shareDocument(document, email: email)
            statusMessage = ok
                ? "Emailed \"\(document.displayTitle)\" to \(email)."
                : (model.errorMessage ?? "Could not email that song.")
        }
    }

    /// Downloads one song in one format and hands it to a share sheet. Named
    /// for the song rather than the project, so several songs exported from
    /// one screenplay stay tellable apart in Files.
    private func export(_ document: TextDocument, as option: ScriptModel.ExportOption) {
        Task {
            do {
                let url = try await model.export(option, named: document.displayTitle)
                exportedFile = ExportButton.ExportedFile(url: url)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let name = url.lastPathComponent
                let mime = url.mimeType
                Task {
                    let created = await model.importDocument(
                        fileName: name, data: data, type: listType, mimeType: mime)
                    if let created {
                        editingDocument = created
                    } else {
                        statusMessage = model.errorMessage ?? "Could not import that file."
                    }
                }
            } catch {
                statusMessage = "Could not read that file."
            }
        case .failure:
            break   // user cancelled or picker error; nothing to report
        }
    }

    private var importTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .pdf, .rtf]
        for ext in ["fountain", "fdx", "docx", "doc"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingDocument != nil }, set: { if !$0 { renamingDocument = nil } })
    }

    private var shareBinding: Binding<Bool> {
        Binding(get: { sharingDocument != nil }, set: { if !$0 { sharingDocument = nil } })
    }
}

/// `sheet(item:)` needs an Identifiable selection for the create flow.
extension DocumentType: Identifiable {
    var id: String { rawValue }
}

private extension URL {
    var mimeType: String {
        if let type = UTType(filenameExtension: pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
