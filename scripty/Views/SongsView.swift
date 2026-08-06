//
//  SongsView.swift
//  scripty
//
//  Songs & Notes for a project — the iPad counterpart of the web app's
//  Songs / Notes screens. Add, edit, rename, delete, archive, insert into the
//  screenplay, email to a collaborator, export, and import from a file. Every
//  affordance is gated on the links the server advertised.
//
//  Edit mode also selects: several documents can be trashed, archived, emailed,
//  or exported as one file, which is what the web list's checkbox column is
//  for. That column used to be the songs list's alone — the services behind it
//  skipped anything that was not a song — and it is not any more. Nothing on
//  this screen now asks which list is showing in order to decide whether an
//  action exists; it asks the rels, and the two lists answer the same.
//
//  What still differs is what genuinely differs: a song is lyric lines with
//  versions and editions behind them, so it opens the block editor and can be
//  exported as a score. A note is prose. Those are the only two places `.song`
//  is still tested for.
//

import SwiftUI
import UniformTypeIdentifiers

/// Mirrors the songs/notes list's sort control on the web. Raw values back an
/// @AppStorage so the choice sticks, as the web's `<select>` does in
/// sessionStorage — under the same `songListSort` / `noteListSort` names.
enum DocumentSort: String, CaseIterable, Identifiable {
    /// The order the writer dragged the list into — what the server stores as
    /// `sortOrder` and returns the collection in.
    case custom
    case lastEdited
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .custom: "Custom order"
        case .lastEdited: "Last edited"
        case .title: "Name A–Z"
        }
    }

    var systemImage: String {
        switch self {
        case .custom: "arrow.up.arrow.down"
        case .lastEdited: "clock"
        case .title: "textformat"
        }
    }

    /// Sorts a list that arrived from the server already in custom order, so
    /// `.custom` is the identity.
    func applied(to documents: [TextDocument]) -> [TextDocument] {
        switch self {
        case .custom:
            return documents
        case .title:
            return documents.sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        case .lastEdited:
            return documents.sorted { lhs, rhs in
                let l = lhs.updatedAt ?? .distantPast
                let r = rhs.updatedAt ?? .distantPast
                if l != r { return l > r }
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
        }
    }
}

/// Which folder the songs (or notes) list is showing.
///
/// `.all` is not "no folder chosen so show everything by accident" — it is the
/// ordinary state of a list, and the one a project with no folders is always in.
enum FolderFilter: Hashable {
    case all
    /// The documents in no folder, which only means something once one exists.
    case unfiled
    case folder(Int)

    func accepts(_ document: TextDocument) -> Bool {
        switch self {
        case .all: return true
        case .unfiled: return document.folderId == nil
        case .folder(let id): return document.folderId == id
        }
    }
}

struct SongsView: View {
    let model: ScriptModel

    /// Where the choice of list is remembered between visits.
    private let options: ScriptViewOptions

    @Environment(\.dismiss) private var dismiss
    /// Which list the picker starts on.
    @State private var listType: DocumentType

    /// A document to open as soon as the list has loaded, which only a tapped
    /// Home Screen widget row ever names. Not `@State`: it is answered once, on
    /// the load this screen opens with, and nothing on screen can set it.
    private let openingId: Int?

    /// The screen that was open above this one when the app was last put down,
    /// if this launch is restoring it. Empty every other time this list opens.
    private let reopening: [OpenEditor]

    /// Opens on the list named, and otherwise on the one this project was last
    /// left on — Songs the first time. Only a route that means a particular
    /// list names one: the Home Screen's two quick actions, a tapped widget
    /// row, and a document changing kind under us.
    ///
    /// Opens the composer along with the list, rather than after a tap on New.
    ///
    /// Only a Control Center button asks for this. The tile is pressed by
    /// someone with a line in their head and nowhere to type it, so landing
    /// them on a list they then have to find a button on spends the moment the
    /// tile exists for. Seeded rather than applied on appear: the sheet is
    /// wanted from the first frame, and a second animation on the way in would
    /// read as the screen changing its mind.
    init(model: ScriptModel, options: ScriptViewOptions, listType: DocumentType? = nil,
         openingId: Int? = nil, creating: Bool = false, reopening: [OpenEditor] = []) {
        self.model = model
        self.options = options
        self.openingId = openingId
        self.reopening = reopening
        let remembered = options.rememberedDocumentList.flatMap(DocumentType.init(rawValue:))
        let opening = listType ?? remembered ?? .song
        _listType = State(initialValue: opening)
        _creatingType = State(initialValue: creating ? opening : nil)
        _printer = State(initialValue: DocumentPrintModel(model: model))
    }

    @State private var editingDocument: TextDocument?
    @State private var creatingType: DocumentType?
    @State private var renamingDocument: TextDocument?
    @State private var renameTitle = ""
    @State private var sharingDocument: TextDocument?
    @State private var shareEmail = ""
    /// The finished song export, waiting for the system share sheet.
    @State private var exportedSong: ExportedSong?
    /// Printing, for a row, for the ticked rows, and for the whole list. One
    /// printer for the three so a download in flight holds all of them.
    @State private var printer: DocumentPrintModel
    @State private var showingImporter = false
    @State private var showingWorkspace = false
    /// The songs ticked in edit mode, by id. Edit mode is held here rather
    /// than left to the environment so leaving it can drop the selection —
    /// otherwise the actions bar would outlive the ticks that filled it.
    @State private var selection = Set<Int>()
    @State private var editMode: EditMode = .inactive
    @State private var confirmingBulkDelete = false
    /// Emailing the ticked songs asks for the address in its own alert: the
    /// single-song one keys off `sharingDocument`, and there is no one
    /// document here to hang it on.
    @State private var promptingBulkShare = false
    /// Presented from the link the document collection advertised.
    @State private var trashLink: HALLink?
    @State private var archiveLink: HALLink?
    @State private var isLoading = false
    @State private var statusMessage: String?
    @State private var searchText = ""
    /// Which folder the list is narrowed to, if any.
    ///
    /// A filter rather than a set of sections. Sections would have to appear and
    /// disappear as folders are made and removed, which is the shape that
    /// proved to diff unreliably in this very List; and they would cut the one
    /// draggable run of rows into several, so an order could only be changed
    /// within a folder. Narrowing keeps one list and one arrangement, and it is
    /// what the web's chips do above the same rows.
    @State private var folderFilter: FolderFilter = .all
    /// The name being typed for a new folder, and the row it will be made for —
    /// nil when the folder is being made on its own rather than to file a song.
    @State private var namingFolder = false
    @State private var folderName = ""
    @State private var filingDocument: TextDocument?
    /// The folder being renamed, and the folder a confirmation is asking about
    /// removing. Both nil the rest of the time.
    @State private var renamingFolder: TextDocumentFolder?
    @State private var deletingFolder: TextDocumentFolder?
    // Songs and notes sort independently, as they do on the web — they are two
    // lists that happen to share a screen.
    //
    // Deliberate divergence: the web defaults to "Last edited" and this
    // defaults to the writer's own order. The client has only ever shown the
    // list in that order, so defaulting to anything else would look like the
    // songs had scrambled themselves on upgrade.
    @AppStorage("songListSort") private var songSort = DocumentSort.custom
    @AppStorage("noteListSort") private var noteSort = DocumentSort.custom

    /// The import link is advertised on the collection only for editors, so it
    /// doubles as the "can add/import" gate — the same rule the web uses.
    private var canEdit: Bool { model.documentsLinks.contains(.importDocument) }

    /// Whichever list is on screen sorts and searches on its own terms.
    private var sortBinding: Binding<DocumentSort> {
        listType == .song ? $songSort : $noteSort
    }

    private var sortMode: DocumentSort {
        listType == .song ? songSort : noteSort
    }

    private var shown: [TextDocument] {
        let all = listType == .song ? model.songs : model.notes
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = query.isEmpty
            ? all
            : all.filter { $0.displayTitle.lowercased().contains(query) }
        // A search runs inside the folder showing, as it does on the web: the
        // folder is where you are, the search is what you are looking for.
        return sortMode.applied(to: matching.filter(folderFilter.accepts))
    }

    /// This list's folders. Songs and notes keep their own, so the picker never
    /// offers a heading the list on screen could not use.
    private var listFolders: [TextDocumentFolder] { model.folders(for: listType) }

    /// The folder the list is narrowed to, or nil for All and for the unfiled.
    private var activeFolder: TextDocumentFolder? {
        guard case .folder(let id) = folderFilter else { return nil }
        return listFolders.first { $0.id == id }
    }

    /// Whether folders are worth showing at all: there is one, or this reader
    /// could make one. A view-only collaborator on a project with no folders
    /// sees nothing about them anywhere.
    private var showsFolders: Bool { !listFolders.isEmpty || model.canCreateFolder }

    /// Rows can be put in a new order wherever the server advertised the link,
    /// whatever the list is currently sorted or searched down to — as on the
    /// web, where "cards can be reordered from any sort mode".
    ///
    /// What that costs is handled at the other end, in `save(_:)`: the rows on
    /// screen are merged back into the full list before it is sent, and the
    /// sort flips to "Custom order" so what was saved is what stays on screen.
    private var canReorder: Bool { model.canReorderDocuments }

    /// Whether there is anything a selection could be used for.
    ///
    /// No longer a question about which list is on screen. The bulk rels are
    /// advertised for a project with any document in it, and each list has its
    /// own collection export — so a writer ticking three notes has exactly the
    /// three things to do with them that a writer ticking three songs has.
    private var canSelect: Bool {
        model.canBulkDeleteDocuments
            || model.canBulkArchiveDocuments
            || !exportOptions.isEmpty
    }

    /// The collection export belonging to the list on screen: the songbook, or
    /// the same file made of notes.
    private var exportOptions: [ScriptModel.ExportOption] {
        model.collectionExportOptions(for: listType)
    }

    /// Everything the list on screen holds, before any search narrows it —
    /// which is what the collection export and the collection print both act
    /// on, as they do on the web.
    private var shownListDocuments: [TextDocument] {
        listType == .song ? model.songs : model.notes
    }

    /// How many documents the list on screen holds, before any search narrows
    /// it. The controls that need "is there more than one of these?" ask this
    /// rather than `shown`, so searching down to a single row cannot take a
    /// control away mid-search.
    private var shownListCount: Int { shownListDocuments.count }

    /// The word for what this list holds, for the sentences that need it.
    private var kindWord: String { listType == .song ? "song" : "note" }
    private var kindWordPlural: String { listType == .song ? "songs" : "notes" }

    /// "3 songs" / "1 note" — the phrase most of the copy below is built from.
    private func counted(_ n: Int) -> String {
        "\(n) \(n == 1 ? kindWord : kindWordPlural)"
    }

    /// The selection in list order, so a songbook of it reads in the order the
    /// writer arranged rather than the order rows happened to be tapped.
    private var selectedDocuments: [TextDocument] {
        shown.filter { selection.contains($0.id) }
    }

    /// Its own property rather than inline in `body`: with the search and sort
    /// on it, leaving the list in the body puts the view past what the type
    /// checker will attempt ("unable to type-check this expression in
    /// reasonable time" — nothing about lists or about search).
    private var list: some View {
        List(selection: $selection) {
            recentSection
            Section {
                ForEach(shown) { document in
                    row(for: document)
                }
                .onMove { source, destination in
                    // Guarded inside rather than conditionally attached: a
                    // plain closure keeps the list's content type unambiguous,
                    // and a view-only collaborator reaches edit mode for the
                    // selection without being able to rearrange anything.
                    moveDocuments(from: source, to: destination)
                }
            } header: {
                // Named only when there is a shortcut strip above it to be
                // told apart from. The section itself is always there, so the
                // rows keep their identity as the strip comes and goes.
                if showsRecent {
                    Text(listType == .song ? "All Songs" : "All Notes")
                }
            }
        }
    }

    /// The handful edited most recently, repeated at the top.
    ///
    /// The list is the writer's own arrangement, and the song being worked on
    /// this week is as likely to sit at the bottom of it as the top. These are
    /// shortcuts to the same rows below, not a reordering of them: the
    /// arrangement is left exactly as it was dragged.
    @ViewBuilder
    private var recentSection: some View {
        if showsRecent {
            Section("Recently Edited") {
                ForEach(recentDocuments) { recent in
                    Button {
                        editingDocument = recent.document
                    } label: {
                        recentRow(recent.document)
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    private func recentRow(_ document: TextDocument) -> some View {
        HStack(spacing: 8) {
            Text(document.displayTitle)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let updated = document.updatedAt {
                Text(updated.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// Whether the strip earns the room it takes.
    ///
    /// Not while searching, which is already the shortcut. Not in edit mode: a
    /// second copy of a row that cannot be ticked or dragged would be a trap
    /// laid in the one mode that is about ticking and dragging. Not under "Last
    /// edited", where it would repeat the first rows of the list word for word.
    /// And not for a list short enough that nothing in it is far away.
    private var showsRecent: Bool {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty
            && !editMode.isEditing
            && sortMode != .lastEdited
            && shown.count > Self.recentCount * 2
            && !recentDocuments.isEmpty
    }

    /// The same handful, by the same rule, that the script's Songs menu offers —
    /// of whichever list is on screen, since a writer with thirty notes is in
    /// the same position as one with thirty songs.
    private var recentDocuments: [RecentDocument] {
        (listType == .song ? model.songs : model.notes)
            .mostRecentlyEdited(limit: Self.recentCount)
            .map(RecentDocument.init)
    }

    /// Short: the strip is a glance, not a second list. Three rows is about
    /// what a writer holds in mind as "what I have been working on".
    private static let recentCount = 3

    /// The list under its Songs/Notes picker.
    ///
    /// Its own property because this body was already at the type checker's
    /// limit: folding the `.safeAreaBar` into the chain below tipped it over
    /// ("unable to type-check this expression in reasonable time"), the same
    /// ceiling `sortPicker` was pulled out to stay under.
    private var listWithPicker: some View {
        list
            .overlay { emptyState }
            .safeAreaBar(edge: .top) { picker }
            .safeAreaBar(edge: .bottom, spacing: 0) { newDocumentBar }
    }

    /// The list with its chrome, and everything that watches it.
    ///
    /// Split out of `body` for the same reason `listWithPicker` and
    /// `sortPicker` were pulled out before it: the single chain was already at
    /// the type checker's limit, and the folder filter's own watchers tipped it
    /// over — "unable to type-check this expression in reasonable time", an
    /// error that names the whole body and nothing in particular. The sheets,
    /// covers and alerts stay in `body`.
    private var listScreen: some View {
        listWithPicker
            .navigationTitle("Songs & Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task {
                // A list a quick action named is as much a statement of intent
                // as one the picker was tapped over to, so it is remembered the
                // same way — the picker's own change never fires for it.
                options.rememberDocumentList(listType.rawValue)
                await reload()
                openRequestedDocument()
                reopenRememberedScreen()
            }
            .refreshable { await reload() }
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: listType == .song ? "Search songs" : "Search notes")
            // Songs and notes are two lists, so a selection made in one has no
            // meaning in the other — nor does a search for a title that only
            // exists in the one being left. The choice itself is kept, so the
            // next trip to this screen opens where this one ended.
            .onChange(of: listType) { _, type in
                selection.removeAll()
                searchText = ""
                // Songs and notes keep separate folders, so the one that was
                // showing does not exist over here. Back to the whole list,
                // which is the only filter both lists always have.
                folderFilter = .all
                options.rememberDocumentList(type.rawValue)
            }
            // A row that has just left the screen must not stay ticked: the
            // bar counts a selection the writer can no longer see, and acting
            // on it would move songs they are not looking at. Same reasoning as
            // the list change above.
            .onChange(of: folderFilter) { _, _ in
                selection.removeAll()
            }
            // A folder can be removed from under the filter — by the menu here,
            // or by a collaborator between two loads. Showing a folder that is
            // gone means showing an empty list with no way back to the full one.
            .onChange(of: model.documentFolders) { _, _ in
                if case .folder(let id) = folderFilter,
                   !listFolders.contains(where: { $0.id == id }) {
                    folderFilter = .all
                }
            }
            // Which of the two lists is showing is the first rung of the record,
            // and the picker is the only thing that moves it once this screen is
            // up — the script view set it on the way in and does not hear about
            // this. The editor or workspace over the list is the rung above.
            .remembersOpenEditor(.songsAndNotes(listType), atDepth: 0,
                                 isEnabled: !model.app.isEphemeralDemo)
            .remembersOpenEditor(openEditor, atDepth: 1,
                                 isEnabled: !model.app.isEphemeralDemo)
            .onChange(of: editMode) { _, mode in
                if !mode.isEditing { selection.removeAll() }
            }
            // The Edit button is only offered above one row, so a list that
            // drops to one — the last delete of a selection, or the last
            // archive — takes away the only way out of the mode it is still
            // in. Leaving on its behalf is the whole of the fix.
            .onChange(of: shownListCount) { _, count in
                if count <= 1 { editMode = .inactive }
            }
            .environment(\.editMode, $editMode)
    }

    var body: some View {
        NavigationStack {
            listScreen
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
            .sheet(item: $archiveLink) { link in
                ArchiveView(
                    app: model.app,
                    source: link,
                    // An unarchived document rejoins the list behind us, at the
                    // end of it.
                    onChanged: { await model.loadDocuments() },
                    // Opening one dismisses the archive first, so the editor
                    // arrives over the list rather than three sheets deep.
                    onOpen: { editingDocument = $0 })
            }
            // The editors and the workspace are covers, not sheets: writing a
            // song is the task, so it gets the screen rather than a card with
            // the list showing around it. Each of them carries its own Done
            // button — the drag is the only way out a cover takes away, and
            // none of them relied on it. The trash, the archive and the share
            // sheet stay sheets: those are glanced at and dismissed.
            .fullScreenCover(item: $creatingType) { type in
                SongEditorView(model: model, document: nil, type: type)
            }
            .sheet(item: $exportedSong) { export in
                ShareSheet(items: [export.url])
            }
            // Whichever list the button was pressed on. The two workspaces
            // share a shape and nothing else: a song pane is a stack of lyric
            // lines, a note pane is one field of prose.
            .fullScreenCover(isPresented: $showingWorkspace) {
                if listType == .song {
                    SongsWorkspaceView(app: model.app, model: model)
                } else {
                    NotesWorkspaceView(app: model.app, model: model)
                }
            }
            .fullScreenCover(item: $editingDocument) { document in
                // A song is lyric lines on the server, so it opens the line
                // editor — where reordering, tinting and editions mean
                // something. A note is plain text and keeps the plain editor.
                // Either editor can send its document into the script, and a
                // send that lands takes this list down with it, the way the
                // rows' own insert does — to reveal the screenplay it changed.
                if document.kind == .song, document.hasLink(.songBlocks) {
                    SongBlockEditorView(app: model.app, document: document,
                                        scriptModel: model,
                                        onInserted: { dismiss() })
                } else {
                    SongEditorView(model: model, document: document, type: document.kind,
                                   onInserted: { dismiss() })
                }
            }
            .alert("Rename", isPresented: renameBinding) {
                TextField("Title", text: $renameTitle)
                Button("Cancel", role: .cancel) { renamingDocument = nil }
                Button("Save") { commitRename() }
            }
            .alert(filingDocument == nil ? "New Folder" : "File in a New Folder",
                   isPresented: $namingFolder) {
                TextField("Folder name", text: $folderName)
                Button("Cancel", role: .cancel) { filingDocument = nil }
                Button("Add") { commitNewFolder() }
            } message: {
                Text(listType == .song
                     ? "A name to group some of your songs under."
                     : "A name to group some of your notes under.")
            }
            .alert("Rename Folder", isPresented: folderRenameBinding) {
                TextField("Folder name", text: $folderName)
                Button("Cancel", role: .cancel) { renamingFolder = nil }
                Button("Save") { commitFolderRename() }
            }
            // A confirmation whose whole job is to say what removing a folder
            // does *not* do — losing a night's work to a tap on a menu is the
            // only thing anybody would fear here, and it does not happen.
            .alert("Remove Folder", isPresented: folderDeleteBinding) {
                Button("Cancel", role: .cancel) { deletingFolder = nil }
                Button("Remove", role: .destructive) {
                    if let folder = deletingFolder { deleteFolder(folder) }
                    deletingFolder = nil
                }
            } message: {
                Text("Remove “\(deletingFolder?.displayName ?? "")”. "
                     + "Everything in it stays in the list.")
            }
            .alert("Email this \(kindWord)", isPresented: shareBinding) {
                TextField("Recipient email", text: $shareEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) { sharingDocument = nil }
                Button("Send") { commitShare() }
            } message: {
                Text(listType == .song
                     ? "Send the lyrics to a collaborator."
                     : "Send the note to a collaborator.")
            }
            .alert("Email \(counted(selection.count))", isPresented: $promptingBulkShare) {
                TextField("Recipient email", text: $shareEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Send") { commitBulkShare() }
            } message: {
                Text(listType == .song
                     ? "Send the lyrics to a collaborator in one message."
                     : "Send the notes to a collaborator in one message.")
            }
            .alert(listType == .song ? "Delete Songs" : "Delete Notes",
                   isPresented: $confirmingBulkDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { bulkDelete() }
            } message: {
                Text("Move \(counted(selection.count)) to the trash. "
                     + "They can be restored from there.")
            }
            .alert("Songs & Notes",
                   isPresented: Binding(get: { statusMessage != nil },
                                        set: { if !$0 { statusMessage = nil } })) {
                Button("OK", role: .cancel) { statusMessage = nil }
            } message: {
                Text(statusMessage ?? "")
            }
            // Its own alert rather than the status one above: a print reports
            // through the same place from every screen that offers it.
            .documentPrintPresentation(printer)
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
                HStack(spacing: 6) {
                    if let updated = document.updatedAt {
                        Text("Edited \(updated.formatted(date: .abbreviated, time: .shortened))")
                    }
                    // Where this one is filed, said on the row rather than only
                    // in the folder control — so the unnarrowed list still
                    // shows the arrangement instead of hiding it behind a menu.
                    // Left out while a single folder is showing, where every
                    // row would carry the same word.
                    if activeFolder == nil, let folder = document.folderName, !folder.isEmpty {
                        Label(folder, systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .trailing) {
            // Delete stays first so a full swipe keeps meaning delete.
            if document.hasLink(.delete) {
                Button(role: .destructive) {
                    Task { await model.deleteDocument(document) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            if document.hasLink(.archive) {
                // Between Delete and Rename by weight: it removes the row like
                // a delete, but loses nothing, so it is not destructive-tinted.
                Button {
                    archive(document)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.orange)
            }
            if document.hasLink(.update) {
                Button {
                    renameTitle = document.title ?? ""
                    renamingDocument = document
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
        .contextMenu {
            // Ordering without a drag, which is what the web's arrow keys are
            // for. Offered on the row itself rather than only in edit mode: a
            // song that belongs one place higher is two taps from here, where
            // dragging it means entering edit mode and holding it steady past
            // the rows in between.
            if canReorder, shown.count > 1 {
                let at = shown.firstIndex { $0.id == document.id }
                Button {
                    move(document, by: -1)
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(at == 0)
                Button {
                    move(document, by: 1)
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(at == shown.count - 1)
            }
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
            folderMenu(for: document)
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
            // Beside the export menu rather than in it, as the screenplay's
            // toolbar keeps the two apart — printing is an errand, not a format.
            DocumentPrintButton(printer: printer, document: document)
            if document.hasLink(.archive) {
                // Not destructive: archiving keeps the document whole and is
                // one tap from undone. It sits above Delete because it is the
                // gentler of the two ways to clear a finished song off the list.
                Button {
                    archive(document)
                } label: {
                    Label("Archive", systemImage: "archivebox")
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

    /// Where one row can be filed.
    ///
    /// Offered whenever the server said this document may be moved, even with
    /// no folder to move it into: "New Folder…" is here, and making the first
    /// folder from the song that needs it is the gesture the whole feature
    /// starts with. Without that, a writer with no folders would find nothing
    /// on the row and have to guess that the bar above the list was the way in.
    @ViewBuilder
    private func folderMenu(for document: TextDocument) -> some View {
        if document.hasLink(.moveToFolder), !listFolders.isEmpty || model.canCreateFolder {
            Menu {
                ForEach(listFolders) { folder in
                    Button {
                        file(document, into: folder)
                    } label: {
                        // A checkmark rather than a disabled row: the one it is
                        // already in is worth showing, and worth showing as the
                        // answer to "where is this?".
                        Label(folder.displayName,
                              systemImage: document.folderId == folder.id ? "checkmark" : "folder")
                    }
                }
                if document.folderId != nil {
                    Divider()
                    Button {
                        file(document, into: nil)
                    } label: {
                        Label("Remove from Folder", systemImage: "tray")
                    }
                }
                if model.canCreateFolder {
                    Divider()
                    Button {
                        filingDocument = document
                        folderName = ""
                        namingFolder = true
                    } label: {
                        Label("New Folder…", systemImage: "folder.badge.plus")
                    }
                }
            } label: {
                Label("Folder", systemImage: "folder")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if shown.isEmpty {
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                // The list has rows, they just do not match — say so rather
                // than claiming the project has no songs.
                ContentUnavailableView.search(text: searchText)
            } else if isLoading {
                ProgressView()
            } else if folderFilter != .all {
                // Not "No Songs": the project has plenty, this folder is simply
                // empty — which for a folder made a moment ago is the ordinary
                // first state rather than anything wrong.
                ContentUnavailableView(
                    activeFolder.map { "Nothing in \($0.displayName)" } ?? "Nothing Unfiled",
                    systemImage: "folder",
                    description: Text(activeFolder == nil
                        ? "Every \(kindWord) here is in a folder."
                        : "Use Folder on a \(kindWord) to file it here."))
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

    /// The primary action of this screen, named and under the thumb — the same
    /// pill the projects list starts a screenplay from, and for the same
    /// reasons: the toolbar "+" it replaces was a glyph in the corner furthest
    /// from the hand, and on iPhone it was competing with Import for the two
    /// slots that toolbar ever shows.
    ///
    /// Follows the picker above it, so it says "New Song" over the songs and
    /// "New Note" over the notes — the list on screen is the one being added to.
    ///
    /// Hidden in edit mode, where the list is answering which songs to delete
    /// or export and starting a new one is not an answer to it, and hidden
    /// altogether for a view-only collaborator, who has no create link to use.
    @ViewBuilder
    private var newDocumentBar: some View {
        if canEdit, !editMode.isEditing {
            Button {
                creatingType = listType
            } label: {
                Label(listType == .song ? "New Song" : "New Note", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            // No background of its own: mounted with `.safeAreaBar`, so the
            // button already floats on Liquid Glass and a fill under it would
            // draw a second, flatter surface on top of that one.
        }
    }

    /// The folder the list is showing, and the way to any other.
    ///
    /// In the bar with the Songs/Notes picker rather than as a row in the List,
    /// for the reason spelled out on `folderFilter`: a control whose presence
    /// depends on how many folders there are proved to come and go unreliably
    /// as a List section, and the bar is rebuilt whole every time.
    ///
    /// Hidden in edit mode: the bar's job there is the selection, and changing
    /// which rows are on screen under a half-made selection is how ticks go
    /// missing.
    @ViewBuilder
    private var folderBar: some View {
        if showsFolders, !editMode.isEditing {
            Menu {
                Picker("Folder", selection: $folderFilter) {
                    Label(listType == .song ? "All Songs" : "All Notes",
                          systemImage: "tray.full").tag(FolderFilter.all)
                    if !listFolders.isEmpty {
                        Label("Unfiled", systemImage: "tray").tag(FolderFilter.unfiled)
                        // The count is the server's, and it counts the whole
                        // list — so it stays honest while a search narrows what
                        // is actually on screen.
                        ForEach(listFolders) { folder in
                            Label("\(folder.displayName) (\(folder.documentCount ?? 0))",
                                  systemImage: "folder").tag(FolderFilter.folder(folder.id))
                        }
                    }
                }
                if model.canCreateFolder {
                    Divider()
                    Button {
                        filingDocument = nil
                        folderName = ""
                        namingFolder = true
                    } label: {
                        Label("New Folder…", systemImage: "folder.badge.plus")
                    }
                }
                if let folder = activeFolder {
                    if folder.canRename {
                        Button {
                            folderName = folder.displayName
                            renamingFolder = folder
                        } label: {
                            Label("Rename “\(folder.displayName)”", systemImage: "pencil")
                        }
                    }
                    if folder.canDelete {
                        Button(role: .destructive) {
                            deletingFolder = folder
                        } label: {
                            Label("Remove “\(folder.displayName)”", systemImage: "folder.badge.minus")
                        }
                    }
                }
            } label: {
                Label(folderBarTitle, systemImage: "folder")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .padding(.bottom, 8)
        }
    }

    /// What the folder control says it is showing.
    private var folderBarTitle: String {
        switch folderFilter {
        case .all: return listType == .song ? "All Songs" : "All Notes"
        case .unfiled: return "Unfiled"
        case .folder: return activeFolder?.displayName ?? "Folder"
        }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            Picker("Type", selection: $listType) {
                Text("Songs").tag(DocumentType.song)
                Text("Notes").tag(DocumentType.notes)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            folderBar
            // The web list's "Edit all on one page" button, kept beside the
            // list's own controls as the web keeps it beside search and sort.
            // The same door exists in the toolbar's overflow, but a button
            // folded behind "…" is one most writers never meet. In the bar
            // rather than a List row: a section whose presence hangs on the
            // song count proved to come and go unreliably as the list diffed
            // itself, and the bar is rebuilt whole every time.
            //
            // Same gate as the toolbar item: only with more than one — a
            // workspace of a single document is the editor with extra steps.
            // Offered on either list now; a page of every note is as useful as
            // a page of every song, and for the same reason.
            if shownListCount > 1 {
                Button {
                    showingWorkspace = true
                } label: {
                    Label("Edit All on One Page", systemImage: "rectangle.stack")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .padding(.bottom, 8)
            }
        }
        // No background: mounted with `.safeAreaBar`, which supplies the glass.
    }

    /// Its own property rather than inline in the toolbar: a Picker in a
    /// toolbar builder is what tips this view past what the type checker will
    /// attempt, as it did in the projects sidebar.
    private var sortPicker: some View {
        Picker(selection: sortBinding) {
            ForEach(DocumentSort.allCases) { mode in
                Label(mode.label, systemImage: mode.systemImage).tag(mode)
            }
        } label: {
            Label("Sort", systemImage: sortMode.systemImage)
        }
        .pickerStyle(.menu)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        // Edit mode is worth entering when there is an order to change or a
        // selection to make, and either way only with more than one row.
        // Gated on the whole list rather than on `shown`, like the sort picker
        // below: searching down to a single row used to take away the only
        // control that leaves edit mode, and strand the list in it.
        if (canReorder || canSelect) && shownListCount > 1 {
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
                if model.canBulkArchiveDocuments {
                    // No confirmation, unlike the bulk delete: nothing is lost
                    // and the archive puts any of it back in one tap.
                    Button {
                        bulkArchive()
                    } label: {
                        Label("Archive \(selection.count)", systemImage: "archivebox")
                    }
                }
                if model.canBulkShareDocuments {
                    Button {
                        shareEmail = ""
                        promptingBulkShare = true
                    } label: {
                        Label("Email \(selection.count)", systemImage: "envelope")
                    }
                }
                // Filing the ticked rows. No "New Folder…" here, unlike the row
                // menu: naming a folder needs an alert, and an alert over a bar
                // holding a live selection is where selections go to die.
                if model.canBulkMoveDocuments, !listFolders.isEmpty {
                    Menu {
                        ForEach(listFolders) { folder in
                            Button {
                                fileSelection(into: folder)
                            } label: {
                                Label(folder.displayName, systemImage: "folder")
                            }
                        }
                        Divider()
                        Button {
                            fileSelection(into: nil)
                        } label: {
                            Label("Remove from Folder", systemImage: "tray")
                        }
                    } label: {
                        Label("Folder \(selection.count)", systemImage: "folder")
                    }
                }
                Spacer()
                let exports = model.collectionExportOptions(
                    for: listType, ids: selectedDocuments.map(\.id))
                if !exports.isEmpty {
                    Menu {
                        ForEach(exports) { option in
                            Button(option.label) { exportCollection(option, of: selectedDocuments) }
                        }
                    } label: {
                        Label("Export \(selection.count)…", systemImage: "square.and.arrow.up")
                    }
                }
                // The ticked rows on paper, one document per sheet — the same
                // file the export menu's PDF would hand over, sent to the
                // printer instead. Beside Export rather than inside it, as
                // everywhere else in the app.
                //
                // The count is in the label to match its four siblings, though
                // none of them actually says it: this bar draws every Label
                // icon-only whatever its style. The printer glyph beside the
                // share glyph is what a writer sees, and the two read as the
                // pair they are.
                if model.collectionPrintOption(
                        for: listType, ids: selectedDocuments.map(\.id)) != nil {
                    Button {
                        printSelection()
                    } label: {
                        Label("Print \(selection.count)…", systemImage: "printer")
                    }
                    .disabled(printer.isPrinting)
                }
            }
        }
        // Nothing to put in an order until there are two of them. Gated on the
        // whole list rather than on `shown`, so searching down to one row
        // cannot take the control away mid-search.
        if shownListCount > 1 {
            ToolbarItem(placement: .secondaryAction) {
                sortPicker
            }
        }
        // Every song — or every note — on one screen, for the edits that span
        // several of them. Only with more than one: a workspace of a single
        // document is just the editor with extra steps.
        if shownListCount > 1 {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingWorkspace = true
                } label: {
                    Label("Edit All on One Page", systemImage: "rectangle.stack")
                }
            }
        }
        // The whole list in one file — the songbook, or the same thing made of
        // notes. Exporting is a read, so this is offered to a view-only
        // collaborator too. Each list advertises its own, so whichever is on
        // screen is what comes down.
        if !exportOptions.isEmpty {
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    ForEach(exportOptions) { option in
                        Button(option.label) { exportCollection(option) }
                    }
                } label: {
                    Label(listType == .song ? "Export All Songs…" : "Export All Notes…",
                          systemImage: "square.and.arrow.up.on.square")
                }
            }
        }
        // The same gathering, on paper. Next to the export menu and outside it,
        // and a read like the export, so a view-only collaborator is offered it
        // too.
        if model.collectionPrintOption(for: listType) != nil {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    printer.print(all: shownListDocuments, of: listType,
                                  named: collectionName())
                } label: {
                    Label(listType == .song ? "Print All Songs…" : "Print All Notes…",
                          systemImage: "printer")
                }
                .disabled(printer.isPrinting)
            }
        }
        if canEdit {
            // No "+" alongside it: adding a song is already offered, named, by
            // the bar under the list, which is on screen whenever this toolbar
            // is. A glyph saying the same thing in the far corner is one
            // control too many, and on iPhone it cost Import its slot.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
            if let archived = model.archivedDocumentsLink {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        archiveLink = archived
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
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

    // MARK: - Where the writer was

    /// What is open over this list, as the restore record spells it.
    ///
    /// Creating and renaming are left out: a half-named new song has nothing
    /// stored to reopen, and an app that came back up on an empty editor would
    /// look like it had lost the one that was there.
    private var openEditor: OpenEditor? {
        if let editingDocument { return .document(id: editingDocument.id, uid: editingDocument.uid) }
        if showingWorkspace { return .songWorkspace }
        return nil
    }

    /// Reopens whatever was over this list when the app was last put down.
    ///
    /// The script view claimed the record and handed the rest of it down, so
    /// there is nothing to guard against reopening twice: a list opened by hand
    /// is given an empty path. A song deleted since is not found and the list
    /// simply stays on screen, which is where the writer would have to go anyway.
    private func reopenRememberedScreen() {
        switch reopening.first {
        case .document(let id, let uid):
            editingDocument = model.documents.rememberedOne(id: id, uid: uid)
        case .songWorkspace:
            // Same gate the toolbar button has: a workspace needs more than one
            // document to stack — of whichever list is being restored onto.
            guard shownListCount > 1 else { return }
            showingWorkspace = true
        default:
            break
        }
    }

    // MARK: - Actions

    private func reload() async {
        isLoading = true
        await model.loadDocuments()
        // After the documents, not beside them: the folder collection is
        // reached through a link the document collection carries, so there is
        // nothing to follow until that has landed.
        await model.loadDocumentFolders()
        isLoading = false
    }

    /// Files one row, or takes it out of its folder.
    private func file(_ document: TextDocument, into folder: TextDocumentFolder?) {
        Task {
            if await model.moveDocument(document, to: folder) == false {
                statusMessage = model.errorMessage
                    ?? "Could not move \"\(document.displayTitle)\"."
            }
        }
    }

    /// Files the ticked rows. The selection is dropped either way, as the bulk
    /// archive drops it: on success those rows may have left the folder being
    /// shown, and on failure the list came back from the server.
    private func fileSelection(into folder: TextDocumentFolder?) {
        let ids = selectedDocuments.map(\.id)
        let count = ids.count
        selection.removeAll()
        Task {
            if await model.bulkMoveDocuments(ids, to: folder) == false {
                statusMessage = model.errorMessage
                    ?? "Could not move \(counted(count))."
            }
        }
    }

    /// Makes the folder just named, and files the row it was named for.
    ///
    /// The two halves are one gesture from the writer's side — "put this in a
    /// new folder called Act One" — so a create that lands and a move that does
    /// not still leaves the folder made, which is the half worth keeping.
    private func commitNewFolder() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = filingDocument
        filingDocument = nil
        guard !name.isEmpty else { return }
        Task {
            guard let folder = await model.createFolder(named: name, for: listType) else {
                statusMessage = model.errorMessage ?? "Could not add that folder."
                return
            }
            if let document {
                if await model.moveDocument(document, to: folder) == false {
                    statusMessage = model.errorMessage
                        ?? "Could not move \"\(document.displayTitle)\"."
                    return
                }
            }
            // Straight to what was just made: naming a folder is a statement
            // about where the writer wants to be looking.
            folderFilter = .folder(folder.id)
        }
    }

    private func commitFolderRename() {
        guard let folder = renamingFolder else { return }
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingFolder = nil
        guard !name.isEmpty else { return }
        Task {
            if await model.renameFolder(folder, to: name) == false {
                statusMessage = model.errorMessage ?? "Could not rename that folder."
            }
        }
    }

    /// Removes a folder. What it held stays in the list, so the filter has to
    /// come off it — those rows are still there, just not under this name.
    private func deleteFolder(_ folder: TextDocumentFolder) {
        folderFilter = .all
        Task {
            if await model.deleteFolder(folder) == false {
                statusMessage = model.errorMessage ?? "Could not remove that folder."
            }
        }
    }

    /// Opens the document a widget row was tapped for, once the list holding
    /// it is in hand.
    ///
    /// A row naming a song since deleted — or one the account has lost access
    /// to — leaves the list open on the right half rather than reporting
    /// anything. The widget draws a snapshot of what the app last saw, so it
    /// going stale is ordinary, and the list is where its writer was heading.
    private func openRequestedDocument() {
        guard let openingId,
              let document = model.documents.first(where: { $0.id == openingId })
        else { return }
        listType = document.kind == .song ? .song : .notes
        editingDocument = document
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
        var rearranged = shown
        rearranged.move(fromOffsets: source, toOffset: destination)
        save(rearranged)
    }

    /// One slot up or down — the arrow keys the web's drag handle answers, and
    /// the route to an order that needs neither edit mode nor a steady drag.
    private func move(_ document: TextDocument, by delta: Int) {
        guard let rearranged = shown.moving(document, by: delta) else { return }
        save(rearranged)
    }

    /// Saves the rows on screen as the writer's own order.
    ///
    /// Two things have to happen before the sequence is the whole truth. The
    /// rows on screen may be a search narrowed down to a handful, so they are
    /// merged back into the full list rather than sent as if the rest had gone
    /// away. And the list may have been sorted by title or by date, in which
    /// case the arrangement being saved is that sort with one row moved — so
    /// the sort flips to "Custom order", exactly as the web's `<select>` does
    /// after a drop, rather than leaving the list to snap back and hide what
    /// was just saved.
    private func save(_ rearranged: [TextDocument]) {
        guard canReorder else { return }
        let all = listType == .song ? model.songs : model.notes
        let merged = sortMode.applied(to: all).merging(shown: rearranged)
        sortBinding.wrappedValue = .custom
        Task { await model.reorderDocuments(merged) }
    }

    private func archive(_ document: TextDocument) {
        Task {
            if await model.archiveDocument(document) == false {
                statusMessage = model.errorMessage
                    ?? "Could not archive \"\(document.displayTitle)\"."
            }
        }
    }

    /// Archives the ticked rows. The selection is dropped either way, for the
    /// same reason the bulk delete drops it: on success those rows have left
    /// the list, and on failure the list came back from the server, so keeping
    /// ids that may no longer be on screen would leave the bar counting
    /// phantoms.
    private func bulkArchive() {
        let ids = selectedDocuments.map(\.id)
        let count = ids.count
        selection.removeAll()
        Task {
            if await model.bulkArchiveDocuments(ids) {
                statusMessage = "Archived \(counted(count))."
            } else {
                statusMessage = model.errorMessage
                    ?? "Could not archive those \(kindWordPlural)."
            }
        }
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

    /// The file is named after the project, not after any one document, since
    /// that is what it holds — unless the writer picked exactly one, where its
    /// own title says more than "Project Songs" would.
    ///
    /// Shared with the print of the same gathering, so a job in the printer
    /// queue is called what the download would have been called.
    private func collectionName(of selected: [TextDocument] = []) -> String {
        if selected.count == 1 { return selected[0].displayTitle }
        let suffix = listType == .song ? " Songs" : " Notes"
        return model.project.displayTitle.isEmpty
            ? kindWordPlural
            : model.project.displayTitle + suffix
    }

    private func exportCollection(_ option: ScriptModel.ExportOption,
                                  of selected: [TextDocument] = []) {
        let name = collectionName(of: selected)
        Task {
            do {
                let url = try await model.downloadExport(option, named: name)
                exportedSong = ExportedSong(url: url)
            } catch {
                statusMessage = "Could not export the \(kindWordPlural)."
            }
        }
    }

    /// The ticked rows on paper. The selection is kept, unlike the bulk actions
    /// that change the list: nothing has moved, and a writer who has just
    /// printed three songs may well want to email the same three.
    private func printSelection() {
        printer.print(selected: selectedDocuments, of: listType,
                      named: collectionName(of: selectedDocuments))
    }

    /// Trashes the ticked rows. The selection is dropped either way: on
    /// success those rows are gone, and on failure the list has been reloaded
    /// from the server, so keeping ids that may no longer be on screen would
    /// leave the bottom bar counting phantoms.
    private func bulkDelete() {
        let ids = selectedDocuments.map(\.id)
        let count = ids.count
        selection.removeAll()
        Task {
            if await model.bulkDeleteDocuments(ids) {
                statusMessage = "Moved \(counted(count)) to the trash."
            } else {
                statusMessage = model.errorMessage
                    ?? "Could not delete those \(kindWordPlural)."
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
                : (model.errorMessage ?? "Could not email that \(kindWord).")
        }
    }

    /// Emails the ticked rows. The count reported back is the server's, not
    /// the selection's: an id it declines is not sent, and saying "emailed 3"
    /// when two went would be a lie about someone's inbox.
    private func commitBulkShare() {
        let email = shareEmail.trimmingCharacters(in: .whitespaces)
        let chosen = selectedDocuments.map(\.id)
        guard !email.isEmpty, !chosen.isEmpty else { return }
        Task {
            guard let sent = await model.bulkShareDocuments(chosen, email: email) else {
                statusMessage = model.errorMessage
                    ?? "Could not email those \(kindWordPlural)."
                return
            }
            statusMessage = "Emailed \(counted(sent)) to \(email)."
            editMode = .inactive
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                let picked: PickedFile
                do {
                    picked = try await PickedFileReader.read(url)
                } catch {
                    if let message = PickedFileReader.readFailureMessage(error) {
                        statusMessage = message
                    }
                    return
                }
                // The server answers an empty upload with a plain refusal, and
                // "could not import" for a file that simply has nothing in it
                // sends the writer looking for a fault in the format.
                guard !picked.data.isEmpty else {
                    statusMessage = "That file is empty."
                    return
                }
                let created = await model.importDocument(
                    fileName: picked.name, data: picked.data,
                    type: listType, mimeType: picked.mimeType)
                if let created {
                    editingDocument = created
                } else {
                    statusMessage = model.errorMessage ?? "Could not import that file."
                }
            }
        case .failure(let error):
            // One rule for all three importers — see `pickFailureMessage`.
            if let message = PickedFileReader.pickFailureMessage(error) {
                statusMessage = message
            }
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

    private var folderRenameBinding: Binding<Bool> {
        Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })
    }

    private var folderDeleteBinding: Binding<Bool> {
        Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })
    }
}

/// `sheet(item:)` needs an Identifiable selection for the create flow.
extension DocumentType: Identifiable {
    var id: String { rawValue }
}

/// One row of the shortcut strip.
///
/// Its own identity, and a String where the list's selection is a `Set<Int>`,
/// because the song it points at appears again in the list below: two rows of
/// one List may not share an id, and a shortcut is not a thing to tick for a
/// bulk delete — that is what its row in the list proper is for.
private struct RecentDocument: Identifiable {
    let document: TextDocument
    var id: String { "recent-\(document.id)" }
}

/// A downloaded song file, presented to the share sheet by identity so the
/// sheet opens only once the export has actually landed on disk.
private struct ExportedSong: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
