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
    @FocusState private var focusedLine: Int?

    /// The device-wide type size, so lyrics in the workspace read at the same
    /// size the writer chose in a song or the screenplay — it is one setting.
    private let settings = PresentationSettings.shared

    /// One per song, made on first expand. Songs nobody opens cost nothing.
    @State private var lyrics: [Int: SongBlockModel] = [:]
    @State private var expanded: Set<Int> = []
    @State private var filter = ""
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
                }
            }
            .listStyle(.plain)
            .environment(\.scriptTextScale, settings.textScale)
            .searchable(text: $filter, prompt: "Filter songs")
            .overlay { emptyState }
            .navigationTitle("All Songs")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
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
        }
    }

    // MARK: - Rows

    private func header(_ song: TextDocument) -> some View {
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
                if let count = lineCount(song) {
                    Text("\(count) \(count == 1 ? "line" : "lines")")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityLabel(song.displayTitle)
        .accessibilityHint(expanded.contains(song.id) ? "Hide lyrics" : "Show lyrics")
        .accessibilityAddTraits(expanded.contains(song.id) ? [.isSelected] : [])
    }

    @ViewBuilder
    private func lines(for song: TextDocument) -> some View {
        if let lyric = lyrics[song.id] {
            if lyric.blocks.isEmpty {
                Text(lyric.isLoading ? "Loading…" : "No lines yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(lyric.blocks) { block in
                SongLineRow(model: lyric, block: block, focusedLine: $focusedLine)
            }
            if lyric.canAddLine {
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
        ToolbarItemGroup(placement: .primaryAction) {
            // Only the songs currently passing the filter, so "expand all"
            // means the same thing the writer can see.
            Button("Expand All") {
                for song in songs { open(song) }
            }
            .disabled(songs.isEmpty)

            Button("Collapse All") {
                expanded.subtract(songs.map(\.id))
            }
            .disabled(expanded.isEmpty)
        }
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
        Task { await lyric.load() }
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

    private func lineCount(_ song: TextDocument) -> Int? {
        guard let lyric = lyrics[song.id], !lyric.isLoading else { return nil }
        return lyric.blocks.count
    }

    private func commitEverything() async {
        for lyric in lyrics.values {
            await lyric.commitAll()
        }
    }
}
