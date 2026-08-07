//
//  SongAudioModel.swift
//  scripty
//
//  The recordings kept with one song: reading the list, adding a file, giving
//  a take a name, throwing one away — and fetching the bytes when somebody
//  presses play.
//
//  What may be done here is decided by the links the server sent, not by a
//  flag: a reader who can open the song gets `audioFile` on every take and
//  neither `renameAudio` nor `deleteAudio`, so listening needs no permission
//  to write and the buttons that would fail are never drawn.
//
//  Bytes are fetched whole and written to a file in the caches directory
//  rather than streamed. Three reasons, in order: `AVAudioPlayer` wants a file
//  or a `Data`; the API needs an Authorization header on every request and a
//  streaming player is the one place in AVFoundation where attaching one is
//  awkward; and the recording is capped at 25 MB, so "whole" is a second or
//  two on any connection worth playing audio over. A take fetched once plays
//  again from the file, including with no connection at all.
//

import Foundation
import Observation

@Observable
@MainActor
final class SongAudioModel {
    private let app: AppModel
    /// The recordings collection, from the song document that owns it.
    private let sourceLink: HALLink?

    private(set) var recordings: [SongAudio] = []
    private(set) var links = HALLinks()
    private(set) var isLoading = false
    private(set) var didLoad = false
    /// The take being uploaded, by name, so the list can say what is arriving.
    private(set) var uploading: String?
    private(set) var isWorking = false
    var errorMessage: String?

    /// Where the fetched bytes of each take are on this device.
    private var files: [Int: URL] = [:]
    /// Fetches in flight, so two taps on the same play button make one request.
    private var downloads: [Int: Task<URL, Error>] = [:]

    var canUpload: Bool { links.contains(.uploadAudio) }
    var isEmpty: Bool { recordings.isEmpty }

    init(app: AppModel, document: TextDocument) {
        self.app = app
        self.sourceLink = document.link(.audioRecordings)
    }

    /// Whether this song can hold recordings at all — false for a note, and
    /// for a server too old to have been told about them, in which case
    /// nothing about recordings is drawn anywhere.
    var isAvailable: Bool { sourceLink != nil }

    // MARK: - Reading

    func loadIfNeeded() async {
        guard !didLoad else { return }
        await load()
    }

    func load() async {
        guard let sourceLink else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let collection: HALCollection<SongAudio> = try await app.client.fetch(from: sourceLink)
            adopt(collection)
            didLoad = true
            errorMessage = nil
        } catch APIError.forbidden {
            // The same shape the editions list takes: someone who may not see
            // them sees none rather than an alert.
            recordings = []
            didLoad = true
        } catch {
            // Opened alongside a song that may itself be an offline copy, so a
            // device with no route says nothing here — the offline strip over
            // the lyrics is already saying it.
            if error.isRetryableAPIError, !app.connectivity.isOnline { return }
            report(error)
        }
    }

    // MARK: - Writing

    /// Adds a file the writer picked. The duration is measured here, since
    /// nothing on the server decodes audio; a file iOS cannot open still
    /// uploads, it just arrives without one.
    /// The server's ceiling on one take, in bytes — `app.song-audio-max-bytes`,
    /// 25 MiB. Held here as well because a file this size has already been read
    /// into memory by the time it reaches this method, and sending it only to
    /// be refused costs the writer the whole upload before it says so.
    static let maxBytes = 25 * 1024 * 1024

    /// And the server's `MAX_PER_SONG`. Both limits were prose — a comment at
    /// the top of this file and a sentence in the help — with nothing in the
    /// client enforcing either.
    static let maxTakes = 50

    @discardableResult
    func upload(_ file: PickedFile) async -> Bool {
        guard let link = links[.uploadAudio] else { return false }
        guard !isWorking else { return false }
        // Checked after the read rather than before it: a document picker hands
        // back a URL whose provider may not have materialised the file yet, so
        // its size is not reliably knowable until `PickedFile` has read it.
        // What this saves is the upload, which is the slow part.
        guard file.data.count <= Self.maxBytes else {
            errorMessage = "That recording is too large. The limit is 25 MB."
            return false
        }
        guard recordings.count < Self.maxTakes else {
            errorMessage = "This song already has \(Self.maxTakes) recordings."
            return false
        }
        isWorking = true
        uploading = file.name
        defer {
            isWorking = false
            uploading = nil
        }
        var fields = ["title": Self.titleFromFileName(file.name)]
        if let milliseconds = await Self.durationMilliseconds(of: file) {
            fields["durationMs"] = String(milliseconds)
        }
        do {
            _ = try await app.client.upload(SongAudio.self, to: link,
                                            fields: fields,
                                            fileName: file.name,
                                            fileData: file.data,
                                            mimeType: file.mimeType)
            await load()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func rename(_ audio: SongAudio, to title: String) async -> Bool {
        guard let link = audio.link(.renameAudio) else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await act {
            let updated: SongAudio = try await self.app.client.fetch(
                from: link, method: "PUT", body: RenameSongAudioCommand(title: trimmed))
            if let index = self.recordings.firstIndex(where: { $0.id == updated.id }) {
                self.recordings[index] = updated
            }
        }
    }

    /// Throws a recording away, bytes and all. There is no trash for a file —
    /// the screen asks first, because nothing here can bring one back.
    @discardableResult
    func delete(_ audio: SongAudio) async -> Bool {
        guard let link = audio.link(.deleteAudio) else { return false }
        return await act {
            let collection: HALCollection<SongAudio> = try await self.app.client.fetch(
                from: link, method: "DELETE")
            self.adopt(collection)
            self.forgetFile(for: audio.id)
        }
    }

    // MARK: - The bytes

    /// The take as a file on this device, fetching it the first time.
    ///
    /// The name on disk is the writer's own, so a share sheet offers "Chorus
    /// idea, 2am.m4a" rather than a number — and it is placed in a directory of
    /// its own per recording, since two takes may well share a name.
    func fileURL(for audio: SongAudio) async throws -> URL {
        if let existing = files[audio.id], FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }
        if let inFlight = downloads[audio.id] {
            return try await inFlight.value
        }
        guard let link = audio.fileLink else { throw APIError.notFound }
        let client = app.client
        let task = Task<URL, Error> {
            let data = try await client.data(for: link)
            return try Self.write(data, named: audio.suggestedFileName, id: audio.id)
        }
        downloads[audio.id] = task
        defer { downloads[audio.id] = nil }
        let url = try await task.value
        files[audio.id] = url
        return url
    }

    /// Whether this take is already on the device, so a screen can offer to
    /// share it without a spinner appearing first.
    func hasLocalFile(for audio: SongAudio) -> Bool {
        guard let url = files[audio.id] else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Plumbing

    private func act(_ work: @escaping () async throws -> Void) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func adopt(_ collection: HALCollection<SongAudio>) {
        recordings = collection.items
        links = collection.links
    }

    private func forgetFile(for id: Int) {
        if let url = files.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    private func report(_ error: Error) {
        // Nothing cancelled is ever shown — see `isCancelledRequest`.
        guard !error.isCancelledRequest else { return }
        app.handle(error)
        errorMessage = error.localizedDescription
    }

    /// The name a file suggests for itself, with the extension taken off —
    /// what the server would call it anyway, sent so the two never disagree.
    private static func titleFromFileName(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// Caches, not Documents: this is a copy of something the server holds, and
    /// the system is welcome to reclaim it when the device is short of room.
    private nonisolated static func write(_ data: Data, named name: String, id: Int) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("song-audio", isDirectory: true)
            .appendingPathComponent(String(id), isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent(safeFileName(name))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A name the file system will take. Only the two characters that cannot
    /// appear in one are touched, so what the writer called the take survives.
    private nonisolated static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "recording" : cleaned
    }

    /// How long the file plays, asked of AVFoundation off the main actor.
    /// Best effort: a format iOS cannot open answers nil, and the recording
    /// simply arrives with no duration on it.
    private nonisolated static func durationMilliseconds(of file: PickedFile) async -> Int? {
        await SongAudioDuration.measure(data: file.data, fileName: file.name)
    }
}
