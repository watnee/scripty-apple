//
//  SongRecordingsView.swift
//  scripty
//
//  The recordings kept with a song, over the lyric they belong to.
//
//  A sheet rather than a panel under the lines, which is where the browser puts
//  them: a phone's song editor is one column of words and adding a rack of
//  players to the bottom of it would push the writing off the screen. It is
//  glanced at and dismissed, like the version history and the deleted lines.
//
//  One player for the whole list — pressing play on a second take stops the
//  first, because a rack of takes is for comparing them. The scrubber appears
//  only on the take that is loaded, so a list of twelve is twelve names rather
//  than twelve transports.
//
//  What each row offers is what the server said it may: `audioFile` on every
//  take (so a reader can listen and save), `renameAudio` and `deleteAudio` only
//  for someone who may write. Nothing here is drawn from a permission this
//  client worked out for itself.
//

import SwiftUI
import UniformTypeIdentifiers

struct SongRecordingsView: View {
    @State private var model: SongAudioModel
    /// One player for the sheet, and it stops when the sheet closes — a demo
    /// playing on after the screen it belongs to has gone would leave nothing
    /// on screen able to stop it.
    @State private var player = SongAudioPlayer()

    @Environment(\.dismiss) private var dismiss
    @State private var showingImporter = false
    /// The take being renamed, and the name being typed for it.
    @State private var renaming: SongAudio?
    @State private var renameDraft = ""
    /// The take a Delete was pressed on, held until the question is answered.
    @State private var deleting: SongAudio?
    /// A file written out for the share sheet.
    @State private var sharing: SharedRecording?
    @State private var importError: String?

    /// What the picker will take. `audio` covers the formats iOS knows by type;
    /// the extensions beside it are the ones a file from a synced folder can
    /// arrive with no type at all — the server reads the extension for exactly
    /// the same reason.
    private static let audioTypes: [UTType] = {
        var types: [UTType] = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        for suffix in ["m4a", "flac", "ogg", "opus", "caf", "aac"] {
            if let type = UTType(filenameExtension: suffix) {
                types.append(type)
            }
        }
        return types
    }()

    init(app: AppModel, document: TextDocument) {
        _model = State(initialValue: SongAudioModel(app: app, document: document))
    }

    var body: some View {
        NavigationStack {
            List {
                if let uploading = model.uploading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Adding \(uploading)…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(model.recordings) { audio in
                    row(audio)
                }
            }
            .overlay {
                if model.recordings.isEmpty && model.uploading == nil {
                    emptyState
                }
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if model.canUpload {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingImporter = true
                        } label: {
                            Label("Add Recording", systemImage: "plus")
                        }
                        .disabled(model.isWorking)
                    }
                }
            }
            .task { await model.loadIfNeeded() }
            .onDisappear { player.stop() }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: Self.audioTypes,
                          allowsMultipleSelection: false) { result in
                handlePick(result)
            }
            .alert("Rename Recording", isPresented: renamingBinding) {
                TextField("Name", text: $renameDraft)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let audio = renaming {
                        let name = renameDraft
                        Task { await model.rename(audio, to: name) }
                    }
                    renaming = nil
                }
            }
            .alert("Delete Recording?", isPresented: deletingBinding, presenting: deleting) { audio in
                Button("Cancel", role: .cancel) { deleting = nil }
                Button("Delete", role: .destructive) {
                    if player.isCurrent(audio) { player.stop() }
                    Task { await model.delete(audio) }
                    deleting = nil
                }
            } message: { audio in
                // Said plainly, because it is true: there is no trash for a
                // file anywhere in this app.
                Text("“\(audio.displayTitle)” will be deleted from this song. This cannot be undone.")
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? player.errorMessage ?? importError ?? "")
            }
            .sheet(item: $sharing) { shared in
                ShareSheet(items: [shared.url])
            }
        }
    }

    // MARK: - A take

    @ViewBuilder
    private func row(_ audio: SongAudio) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                playButton(audio)
                VStack(alignment: .leading, spacing: 2) {
                    Text(audio.displayTitle)
                        .font(.body)
                    if !audio.subtitle.isEmpty {
                        Text(audio.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if player.isCurrent(audio) {
                scrubber
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .swipeActions(edge: .trailing) {
            if audio.canDelete {
                Button(role: .destructive) {
                    deleting = audio
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            if audio.canRename {
                Button {
                    beginRename(audio)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.indigo)
            }
        }
        .contextMenu {
            Button {
                share(audio)
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            if audio.canRename {
                Button {
                    beginRename(audio)
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
            }
            if audio.canDelete {
                Button(role: .destructive) {
                    deleting = audio
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func playButton(_ audio: SongAudio) -> some View {
        Button {
            Task { await player.toggle(audio, from: model) }
        } label: {
            ZStack {
                if player.loadingId == audio.id {
                    ProgressView()
                } else {
                    Image(systemName: player.isPlaying(audio) ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        // The row is a whole button's worth of tap target on its own, so this
        // one says what it is rather than leaving VoiceOver to read the glyph.
        .accessibilityLabel(player.isPlaying(audio) ? "Pause \(audio.displayTitle)"
                                                    : "Play \(audio.displayTitle)")
    }

    /// Where in the take we are, and a way to move it. Drawn only under the
    /// loaded take — see the note at the top of the file.
    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(
                get: { player.currentTime },
                set: { player.seek(to: $0) }
            ), in: 0...max(player.duration, 0.1))
            HStack {
                Text(Self.clock(player.currentTime))
                Spacer()
                Text(Self.clock(player.duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Recordings", systemImage: "waveform")
        } description: {
            Text(model.canUpload
                 ? "Add the demo, the voice memo, whatever this song sounds like."
                 : "Nothing has been added to this song yet.")
        } actions: {
            if model.canUpload {
                Button("Add Recording") { showingImporter = true }
            }
        }
    }

    // MARK: - Doing things

    private func beginRename(_ audio: SongAudio) {
        renameDraft = audio.displayTitle
        renaming = audio
    }

    /// Hands the take to the system share sheet, fetching the bytes first if
    /// this device has not already got them.
    private func share(_ audio: SongAudio) {
        Task {
            do {
                let url = try await model.fileURL(for: audio)
                sharing = SharedRecording(url: url)
            } catch {
                guard !error.isCancelledRequest else { return }
                importError = error.localizedDescription
            }
        }
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    let picked = try await PickedFileReader.read(url)
                    await model.upload(picked)
                } catch {
                    importError = PickedFileReader.readFailureMessage(error)
                }
            }
        case .failure(let error):
            importError = PickedFileReader.pickFailureMessage(error)
        }
    }

    // MARK: - Bindings

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    /// One alert for three sources of trouble — the list, the player and the
    /// picker — because they are never up at once and each says its own piece.
    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil || player.errorMessage != nil || importError != nil },
            set: { presented in
                if !presented {
                    model.errorMessage = nil
                    player.errorMessage = nil
                    importError = nil
                }
            })
    }

    /// `0:47`, the same clock the recording's own duration is written in.
    private static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A recording written out for the share sheet. Identifiable so `sheet(item:)`
/// can carry it, the way an export does.
private struct SharedRecording: Identifiable {
    let url: URL
    var id: String { url.path }
}
