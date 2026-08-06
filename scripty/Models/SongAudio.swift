//
//  SongAudio.swift
//  scripty
//
//  A recording kept with a song: the voice memo the tune was first sung into,
//  the demo the band sent back, the reference track being chased.
//
//  Everything here describes the file. The file itself is behind the
//  `audioFile` link, so a song's list of takes costs the same whether they are
//  phone memos or full mixes, and nothing is fetched until somebody presses
//  play.
//

import Foundation

struct SongAudio: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var documentId: Int?
    /// What the writer calls this take, which is not always what the file is
    /// called — "Chorus idea, 2am" says something `voice-memo-4.m4a` does not.
    var title: String?
    var fileName: String?
    var contentType: String?
    var byteSize: Int?
    /// How long it plays, or nil when nobody could measure it. Nothing on the
    /// server decodes audio, so this is whatever the uploading client said.
    var durationMs: Int?
    var sortOrder: Int?
    var createdAt: Date?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, documentId, title, fileName, contentType, byteSize, durationMs, sortOrder, createdAt
        case links = "_links"
    }

    var displayTitle: String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let name = (fileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Recording" : name
    }

    /// The bytes — to play, to save, or to hand to a share sheet.
    var fileLink: HALLink? { link(.audioFile) }

    var canRename: Bool { hasLink(.renameAudio) }
    var canDelete: Bool { hasLink(.deleteAudio) }

    var duration: Duration? {
        guard let durationMs, durationMs > 0 else { return nil }
        return .milliseconds(durationMs)
    }

    /// `0:47`, and `1:02:13` for the take that turned into a jam. Empty when
    /// the uploader could not measure it, which every screen draws as a gap
    /// rather than as a zero.
    var durationText: String {
        guard let durationMs, durationMs > 0 else { return "" }
        let total = Int((Double(durationMs) / 1000).rounded())
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    var sizeText: String {
        guard let byteSize, byteSize > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    /// The line under the name: how long it plays and how big it is, with
    /// whichever of the two is known.
    var subtitle: String {
        [durationText, sizeText].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What to call the file when it is written to disk for a share sheet.
    /// Falls back to the writer's name for it, since a recording uploaded by
    /// something that sent no file name still has one of those.
    var suggestedFileName: String {
        let name = (fileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return displayTitle + "." + (Self.extensions[contentType ?? ""] ?? "m4a")
    }

    /// The extension to give a file the server described only by type. Short
    /// on purpose: it is the fallback for a name that has gone missing, not a
    /// second copy of the server's table.
    private static let extensions: [String: String] = [
        "audio/mpeg": "mp3",
        "audio/mp4": "m4a",
        "audio/x-m4a": "m4a",
        "audio/wav": "wav",
        "audio/x-wav": "wav",
        "audio/aiff": "aiff",
        "audio/flac": "flac",
        "audio/ogg": "ogg"
    ]
}

/// The new name for a recording. The file is untouched — only what the writer
/// calls it changes.
struct RenameSongAudioCommand: Encodable {
    var title: String
}
