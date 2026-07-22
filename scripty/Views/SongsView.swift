//
//  SongsView.swift
//  scripty
//
//  Songs & Notes for a project — the iPad counterpart of the web app's
//  Songs / Notes screens. Add, edit, rename, delete, insert into the
//  screenplay, share a song by email, and import from a file. Every
//  affordance is gated on the links the server advertised.
//
//  Edit mode also selects: several songs can be trashed, or exported as a
//  songbook of just those songs, which is what the web list's checkbox column
//  is for. Notes have no checkboxes there and none here.
//

import SwiftUI
import UniformTypeIdentifiers

struct SongsView: View {
    let model: ScriptModel

    @Environment(\.dismiss) private var dismiss
    @State private var listType: DocumentType = .song
    @State private var editingDocument: TextDocument?
    @State private var creatingType: DocumentType?
    @State private var renamingDocument: TextDocument?
    @State private var renameTitle = ""
    @State private var sharingDocument: TextDocument?
    @State private var shareEmail = ""
    /// The finished song export, waiting for the system share sheet.
    @State private var exportedSong: ExportedSong?
    @State private var showingImporter = false
    @State private var showingWorkspace = false
    /// The songs ticked in edit mode, by id. Edit mode is held here rather
    /// than left to the environment so leaving it can drop the selection —
    /// otherwise the actions bar would outlive the ticks that filled it.
    @State private var selection = Set<Int>()
    @State private var editMode: EditMode = .inactive
    @State private var confirmingBulkDelete = false
    /// Presented from the link the document collection advertised.
    @State private var trashLink: HALLink?
    @State private var isLoading = false
    @State private var statusMessage: String?

    /// The import link is advertised on the collection only for editors, so it
    /// doubles as the "can add/import" gate — the same rule the web uses.
    private var canEdit: Bool { model.documentsLinks.contains(.importDocument) }

    private var shown: [TextDocument] {
        listType == .song ? model.songs : model.notes
    }

    /// Selecting several is a song affordance: the bulk delete is advertised
    /// only where there is a song to delete, and the songbook is the only
    /// export a selection can feed.
    private var canSelect: Bool {
        listType == .song && (model.canBulkDeleteDocuments || !model.songbookExportOptions.isEmpty)
    }

    /// The selection in list order, so a songbook of it reads in the order the
    /// writer arranged rather than the order rows happened to be tapped.
    private var selectedDocuments: [TextDocument] {
        shown.filter { selection.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                ForEach(shown) { document in
                    row(for: document)
                }
                .onMove { source, destination in
                    // Edit mode is only reachable when reordering is allowed
                    // (the toolbar gates its button on the same rule), so this
                    // is guarded rather than conditionally attached — a plain
                    // closure keeps the list's content type unambiguous.
                    guard model.canReorderDocuments else { return }
                    moveDocuments(from: source, to: destination)
                }
            }
            .overlay { emptyState }
            .safeAreaInset(edge: .top) { picker }
            .navigationTitle("Songs & Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await reload() }
            .refreshable { await reload() }
            // Songs and notes are two lists, so a selection made in one has no
            // meaning in the other.
            .onChange(of: listType) { _, _ in selection.removeAll() }
            .onChange(of: editMode) { _, mode in
                if !mode.isEditing { selection.removeAll() }
            }
            .environment(\.editMode, $editMode)
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
            .sheet(item: $exportedSong) { export in
                ShareSheet(items: [export.url])
            }
            .sheet(isPresented: $showingWorkspace) {
                SongsWorkspaceView(app: model.app, model: model)
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
            .alert("Delete Songs", isPresented: $confirmingBulkDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { bulkDelete() }
            } message: {
                Text("Move \(selection.count) \(selection.count == 1 ? "song" : "songs") "
                     + "to the trash. They can be restored from there.")
            }
            .alert("Songs & Notes",
                   isPresented: Binding(get: { statusMessage != nil },
                                        set: { if !$0 { statusMessage = nil } })) {
                Button("OK", role: .cancel) { statusMessage = nil }
            } message: {
                Text(statusMessage ?? "")
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
            if document.hasLink(.duplicate) {
                Button {
                    duplicate(document)
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
            }
            if document.hasLink(.changeType) {
                // Only ever a swap between the two kinds the picker shows, so
                // it reads as one action rather than a type menu.
                let other: DocumentType = document.kind == .song ? .notes : .song
                Button {
                    changeType(document, to: other)
                } label: {
                    Label(other == .song ? "Make a Song" : "Make a Note",
                          systemImage: other == .song ? "music.note" : "note.text")
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
            let exports = model.songExportOptions(for: document)
            if !exports.isEmpty {
                Menu {
                    ForEach(exports) { option in
                        Button(option.label) { exportSong(document, option) }
                    }
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
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
        // Edit mode is worth entering when there is an order to change or a
        // selection to make, and either way only with more than one row.
        if (model.canReorderDocuments || canSelect) && shown.count > 1 {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        // What the selection can be done to, shown only once something is
        // ticked — an empty bar under a list nobody is selecting from is noise.
        if editMode.isEditing && !selection.isEmpty {
            ToolbarItemGroup(placement: .bottomBar) {
                if model.canBulkDeleteDocuments {
                    Button(role: .destructive) {
                        confirmingBulkDelete = true
                    } label: {
                        Label("Delete \(selection.count)", systemImage: "trash")
                    }
                }
                Spacer()
                let exports = model.songbookExportOptions(for: selectedDocuments.map(\.id))
                if !exports.isEmpty {
                    Menu {
                        ForEach(exports) { option in
                            Button(option.label) { exportSongbook(option, of: selectedDocuments) }
                        }
                    } label: {
                        Label("Export \(selection.count)…", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        // Every song on one screen, for the edits that span several of them.
        // Only where the songs are, and only with more than one — a workspace
        // of a single song is just the editor with extra steps.
        if listType == .song, model.songs.count > 1 {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingWorkspace = true
                } label: {
                    Label("Edit All on One Page", systemImage: "rectangle.stack")
                }
            }
        }
        // The whole songbook in one file. Exporting is a read, so this is
        // offered to a view-only collaborator too, and only while the songs
        // are on screen — the notes list has no songbook to take away.
        if listType == .song, !model.songbookExportOptions.isEmpty {
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    ForEach(model.songbookExportOptions) { option in
                        Button(option.label) { exportSongbook(option) }
                    }
                } label: {
                    Label("Export All Songs…", systemImage: "square.and.arrow.up.on.square")
                }
            }
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

    private func duplicate(_ document: TextDocument) {
        Task {
            if await model.duplicateDocument(document) == nil {
                statusMessage = model.errorMessage ?? "Could not duplicate \"\(document.displayTitle)\"."
            }
        }
    }

    private func changeType(_ document: TextDocument, to type: DocumentType) {
        Task {
            if await model.changeDocumentType(document, to: type) {
                // It has left the list we are looking at, so follow it over
                // rather than leaving the writer staring at an empty row.
                listType = type
            } else {
                statusMessage = model.errorMessage
                    ?? "Could not turn \"\(document.displayTitle)\" into a \(type == .song ? "song" : "note")."
            }
        }
    }

    private func moveDocuments(from source: IndexSet, to destination: Int) {
        var reordered = shown
        reordered.move(fromOffsets: source, toOffset: destination)
        Task { await model.reorderDocuments(reordered) }
    }

    private func exportSong(_ document: TextDocument, _ option: ScriptModel.ExportOption) {
        Task {
            do {
                let url = try await model.downloadExport(option, named: document.displayTitle)
                exportedSong = ExportedSong(url: url)
            } catch {
                statusMessage = "Could not export \"\(document.displayTitle)\"."
            }
        }
    }

    /// The songbook is named after the project, not after any one song, since
    /// that is what the file holds — unless the writer picked a single song,
    /// where its own title says more than "Project Songs" would.
    private func exportSongbook(_ option: ScriptModel.ExportOption,
                                of selected: [TextDocument] = []) {
        let project = model.project.displayTitle.isEmpty ? "songs" : model.project.displayTitle + " Songs"
        let name = selected.count == 1 ? selected[0].displayTitle : project
        Task {
            do {
                let url = try await model.downloadExport(option, named: name)
                exportedSong = ExportedSong(url: url)
            } catch {
                statusMessage = "Could not export the songs."
            }
        }
    }

    /// Trashes the ticked songs. The selection is dropped either way: on
    /// success those rows are gone, and on failure the list has been reloaded
    /// from the server, so keeping ids that may no longer be on screen would
    /// leave the bottom bar counting phantoms.
    private func bulkDelete() {
        let ids = selectedDocuments.map(\.id)
        let count = ids.count
        selection.removeAll()
        Task {
            if await model.bulkDeleteDocuments(ids) {
                statusMessage = "Moved \(count) \(count == 1 ? "song" : "songs") to the trash."
            } else {
                statusMessage = model.errorMessage ?? "Could not delete those songs."
            }
        }
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
        // A score imports as its lyric, so it belongs in the picker beside the
        // document formats. `musicxml` and `mxl` are declared in Info.plist —
        // iOS knows neither — so unlike the others these resolve.
        for ext in ["fountain", "fdx", "docx", "doc", "musicxml", "mxl"] {
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

/// A downloaded song file, presented to the share sheet by identity so the
/// sheet opens only once the export has actually landed on disk.
private struct ExportedSong: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
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
