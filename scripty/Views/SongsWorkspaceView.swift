//
//  SongsWorkspaceView.swift
//  scripty
//
//  Every song in the project on one screen — the browser's "edit all on one
//  page".
//
//  The songs list opens one song at a time, which is right when you know which
//  song you want. It is wrong for the job this screen exists for: a lyric that
//  needs a line moved into the song before it, or a phrase changed the same way
//  in four places. That means opening, editing, closing and opening again, and
//  losing your place each time.
//
//  Each song keeps its own model, made when it is first opened and kept
//  afterwards, so collapsing and expanding costs nothing and half-typed lines
//  survive it. Nothing is loaded for a song nobody has opened.
//

import SwiftUI

struct SongsWorkspaceView: View {
    let app: AppModel
    let model: ScriptModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedLine: Int?

    /// The device-wide type size, so lyrics in the workspace read at the same
    /// size the writer chose in a song or the screenplay — it is one setting.
    private let settings = PresentationSettings.shared

    /// Which songs' offline lines have been closed. Per song, and under the
    /// same keys the song editor uses: it is one notice about one lyric, and
    /// closing it in the editor should not leave it standing here.
    private let notices = DismissedNotices.shared

    /// One per song, made on first expand. Songs nobody opens cost nothing.
    @State private var lyrics: [Int: SongBlockModel] = [:]
    /// Whether each opened song is closed to typing. A lock set in the song
    /// editor has to hold here too, or the screen that shows every lyric at
    /// once would be the way around every lock in the project. Read only —
    /// the switch itself stays in the song's own editor, where a writer is
    /// looking at one song and means it. Made beside the lyric, so a song
    /// nobody opened still costs nothing.
    @State private var locks: [Int: SongViewOptions] = [:]
    @State private var expanded: Set<Int> = []
    @State private var filter = ""
    @State private var showingIgnoredWords = false
    /// Set once the saved open set has been restored, so the first restore does
    /// not immediately save the empty starting state back over it.
    @State private var didRestore = false

    /// Which songs were left open, remembered per project. Shared with the web,
    /// which stores the same set under the same key.
    private var openStore: SongWorkspaceOpenState {
        SongWorkspaceOpenState(projectId: model.project.id)
    }

    private var songs: [TextDocument] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.songs }
        return model.songs.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(songs) { song in
                    Section {
                        if expanded.contains(song.id) {
                            lines(for: song)
                        }
                    } header: {
                        header(song)
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            // Same single-spacing rule as the song editor: without this the
            // list pads every lyric line up to its default minimum row height,
            // and a verse reads double-spaced.
            .environment(\.defaultMinListRowHeight, 1)
            .environment(\.scriptTextScale, settings.textScale)
            .searchable(text: $filter, prompt: "Filter songs")
            .overlay { emptyState }
            .navigationTitle("All Songs")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .sheet(isPresented: $showingIgnoredWords) {
                SpellcheckWordsView()
            }
            // Leaving flushes every song that was opened: a line half-typed in
            // the third song down is no less precious than one in the first.
            .task {
                await model.loadDocuments()
                restoreOpenSongs()
            }
            // Remembered per project. Guarded on the restore having happened, so
            // the empty starting set never overwrites what was saved.
            .onChange(of: expanded) { _, ids in
                guard didRestore else { return }
                openStore.save(ids)
            }
            // The connection came back: every open lyric may be holding lines
            // written while it was down, or showing the offline copy — the
            // sweep pushes the one and replaces the other.
            .onChange(of: app.connectivity.isOnline) { _, online in
                guard online else { return }
                Task { await syncOpenLyrics() }
            }
            // Backgrounding persists every half-typed line before the system
            // decides how much longer this process runs; the foreground is a
            // second chance for anything still held.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background, .inactive:
                    Task {
                        for lyric in lyrics.values {
                            await lyric.flushPendingCommits()
                        }
                    }
                case .active:
                    if app.connectivity.isOnline {
                        Task { await syncOpenLyrics() }
                    }
                @unknown default:
                    break
                }
            }
            // A lyric that reloaded — from the server, or from a newer cached
            // copy — is a new situation, so whatever was closed about the old
            // one stops applying.
            .onChange(of: offlineStamps) { old, new in
                for id in Set(old.keys).union(new.keys) where old[id] != new[id] {
                    notices.situationChanged(DismissedNotices.offlineCopyKey(songId: id))
                }
            }
        }
    }

    // MARK: - Offline notices

    private func offlineKey(_ song: TextDocument) -> String {
        DismissedNotices.offlineCopyKey(songId: song.id)
    }

    private func offlineState(_ savedAt: Date) -> String {
        DismissedNotices.offlineCopyState(savedAt: savedAt)
    }

    private func dismissOffline(_ song: TextDocument, savedAt: Date) {
        withAnimation(.snappy(duration: 0.2)) {
            notices.dismiss(offlineKey(song), state: offlineState(savedAt))
        }
    }

    /// Every open lyric's stale-copy stamp, by song. Watched as one value
    /// rather than row by row: a row that has stopped being offline is a row
    /// that is no longer on screen to notice it, and its dismissal still has to
    /// be retired.
    private var offlineStamps: [Int: String] {
        lyrics.compactMapValues { $0.offlineCopySavedAt.map(offlineState) }
    }

    private func syncOpenLyrics() async {
        for lyric in lyrics.values
        where lyric.hasUnsavedChanges || lyric.isShowingOfflineCopy {
            await lyric.syncHeldWork()
        }
    }

    // MARK: - Rows

    private func header(_ song: TextDocument) -> some View {
        HStack(spacing: 8) {
            Button {
                toggle(song)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.contains(song.id) ? 90 : 0))
                    Text(song.displayTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    // Why this song's lines will not take a keystroke. The
                    // switch is in the song's own editor, so all this has to
                    // do is answer the question.
                    if isLocked(song) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isLocked(song)
                                ? "\(song.displayTitle), locked"
                                : song.displayTitle)
            .accessibilityHint(expanded.contains(song.id) ? "Hide lyrics" : "Show lyrics")
            .accessibilityAddTraits(expanded.contains(song.id) ? [.isSelected] : [])
            if canReorder {
                reorderMenu(song)
            }
        }
        .textCase(nil)
    }

    /// The web puts a drag handle on every song here, beside the one on every
    /// lyric line, so ordering the songs and ordering their lines read as the
    /// same gesture. Each song is a `Section` in this list, and sections do not
    /// take `.onMove` — so the ordering is offered as the move the web's handle
    /// also answers to, one slot at a time, which is the half of it that works
    /// on touch anyway.
    private func reorderMenu(_ song: TextDocument) -> some View {
        let at = songs.firstIndex { $0.id == song.id }
        return Menu {
            Button {
                move(song, by: -1)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(at == 0)
            Button {
                move(song, by: 1)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(at == songs.count - 1)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Reorder \(song.displayTitle)")
    }

    @ViewBuilder
    private func lines(for song: TextDocument) -> some View {
        if let lyric = lyrics[song.id] {
            // The same honesty the song editor's banner gives: an out-of-date
            // lyric must not look current — and the same ✕, since a writer who
            // has read it should be able to get the row back.
            if let savedAt = lyric.offlineCopySavedAt,
               !notices.isDismissed(offlineKey(song), state: offlineState(savedAt)) {
                HStack(spacing: 6) {
                    Label("Offline — lyrics saved "
                          + savedAt.formatted(.relative(presentation: .named)),
                          systemImage: "wifi.slash")
                    Spacer(minLength: 0)
                    NoticeCloseButton { dismissOffline(song, savedAt: savedAt) }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                // `.ignore` rather than `.combine`, so the close button comes
                // through as a named action instead of being swallowed.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Offline. Showing the lyrics saved on this device "
                                    + savedAt.formatted(.relative(presentation: .named)) + ".")
                .accessibilityAction(named: "Dismiss") { dismissOffline(song, savedAt: savedAt) }
            }
            if lyric.blocks.isEmpty {
                Text(lyric.isLoading ? "Loading…" : "No lines yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // No Add Line button here, unlike the single-song editor. This
            // screen stacks every song in the project, so a button under each
            // one repeats down the whole list and reads as part of the next
            // song's verse. Return at the end of a line makes the next line,
            // which is how a lyric is written anyway.
            ForEach(lyric.blocks) { block in
                SongLineRow(model: lyric,
                            block: block,
                            isLocked: isLocked(song),
                            focusedLine: $focusedLine)
            }
            if lyric.canAddLine, !isLocked(song) {
                Button {
                    Task {
                        if let created = await lyric.appendLine() { focusedLine = created }
                    }
                } label: {
                    Label("Add Line", systemImage: "plus")
                        .font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.songs.isEmpty {
            ContentUnavailableView(
                "No Songs Yet",
                systemImage: "music.note",
                description: Text("Create a song and it will show up here alongside the rest."))
        } else if songs.isEmpty {
            ContentUnavailableView.search(text: filter)
        }
    }

    /// Where the writing on this screen currently lives, read across every song
    /// that has been opened. Same precedence as the song editor's badge —
    /// refused beats retrying — but taken over the whole workspace, because a
    /// verse held back in the fourth song down is as unsaved as one in the
    /// first, and nothing else here would say so while that song is collapsed.
    private var cloudState: CloudSyncState? {
        guard !app.isDemo else { return nil }
        if !app.connectivity.isOnline { return .offline }
        if lyrics.values.contains(where: \.hasFailedSaves) { return .failed }
        return lyrics.values.contains(where: \.hasUnsavedChanges) ? .holding : .synced
    }

    /// Lines still kept on this device, counted across every open song.
    private var heldLineCount: Int {
        lyrics.values.reduce(0) { $0 + $1.unsavedBlockIds.count }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") {
                Task {
                    await commitEverything()
                    dismiss()
                }
            }
        }
        // Beside the way out, where the song editor and the screenplay keep it:
        // leaving is the moment a writer wonders whether their words are
        // anywhere but here.
        if let cloud = cloudState {
            ToolbarItem(placement: .topBarLeading) {
                CloudSyncBadge(state: cloud, heldCount: heldLineCount)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // "Expand"/"Collapse" rather than the "Expand All"/"Collapse All" these
        // were: the badge has to fit beside them, and with Done, a badge and
        // both words spelled out the iPhone bar is one item over what it will
        // draw — it then drops one, and not the same one twice: one launch
        // loses Collapse All, the next loses the badge. A badge that is only
        // sometimes there is worse than no badge. The two words each buy back
        // the room, and the "All" they lose is the part the buttons never
        // needed: every song on screen is what this screen is.
        ToolbarItemGroup(placement: .primaryAction) {
            // Only the songs currently passing the filter, so "expand all"
            // means the same thing the writer can see.
            Button {
                for song in songs { open(song) }
            } label: {
                Label("Expand All", systemImage: "rectangle.expand.vertical")
            }
            .labelStyle(.iconOnly)
            .disabled(songs.isEmpty)

            Button {
                expanded.subtract(songs.map(\.id))
            } label: {
                Label("Collapse All", systemImage: "rectangle.compress.vertical")
            }
            .labelStyle(.iconOnly)
            .disabled(expanded.isEmpty)
        }
        // Every song at once is where a field of red squiggles is hardest to
        // read past, so the switch belongs here as much as anywhere.
        ToolbarItem(placement: .secondaryAction) {
            SpellingMenu(showingIgnoredWords: $showingIgnoredWords)
        }
    }

    // MARK: - Ordering

    /// Only where the server said the songs may be rearranged, and only with
    /// more than one of them on screen to rearrange.
    private var canReorder: Bool { model.canReorderDocuments && songs.count > 1 }

    /// Moves a song one slot among the ones the filter is showing, then saves
    /// the whole list — songs the filter hid keep the places they held, since
    /// they are not on screen to have been moved past.
    private func move(_ song: TextDocument, by delta: Int) {
        guard canReorder, let rearranged = songs.moving(song, by: delta) else { return }
        let merged = model.songs.merging(shown: rearranged)
        Task { await model.reorderDocuments(merged) }
    }

    // MARK: - Opening and closing

    private func toggle(_ song: TextDocument) {
        if expanded.contains(song.id) {
            expanded.remove(song.id)
            // Collapsing is not leaving: flush what was typed, but keep the
            // model so opening it again is instant and loses nothing.
            if let lyric = lyrics[song.id] {
                Task { await lyric.commitAll() }
            }
        } else {
            open(song)
        }
    }

    private func open(_ song: TextDocument) {
        expanded.insert(song.id)
        guard lyrics[song.id] == nil else { return }
        let lyric = SongBlockModel(app: app, document: song)
        lyrics[song.id] = lyric
        // No edition named: this screen always reads the default lyric, which
        // is the one a song-level lock covers.
        locks[song.id] = SongViewOptions(documentId: song.id)
        Task { await lyric.load() }
    }

    /// Whether this song is closed to typing. A song not yet opened has no
    /// stored answer here and needs none — nothing of it is on screen to type
    /// into.
    private func isLocked(_ song: TextDocument) -> Bool {
        locks[song.id]?.isEditingLocked ?? false
    }

    /// Reopens the songs left open last time. Runs after the documents load so
    /// a remembered id that no longer names a song is simply dropped rather than
    /// opening an empty section.
    private func restoreOpenSongs() {
        let saved = openStore.load()
        for song in model.songs where saved.contains(song.id) {
            open(song)
        }
        didRestore = true
    }

    private func commitEverything() async {
        for lyric in lyrics.values {
            await lyric.commitAll()
        }
    }
}
