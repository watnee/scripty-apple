//
//  PickedFile.swift
//  scripty
//
//  Reading a file the writer chose in the document picker.
//
//  Every importer in the app — songs and notes, the screenplay, a Scripty
//  archive — used to do this the short way: open a security scope and hand the
//  URL to `Data(contentsOf:)`. That works for a file sitting on the device and
//  fails for one that is not, which is most Word documents: a .docx normally
//  lives in iCloud Drive, OneDrive or Google Drive, and what the picker hands
//  back for those is a placeholder the provider has not materialized yet.
//  Reading it directly throws, and the writer sees "Could not read that file."
//  for a file that is perfectly fine and one tap away.
//
//  So the read goes through NSFileCoordinator, which is what makes the provider
//  fetch the bytes first, and the failure message carries the system's own
//  reason rather than swallowing it.
//
//  What to say about it lives here too — for one file, and for the several a
//  songs or notes import can now be handed at once.
//

import Foundation
import UniformTypeIdentifiers

/// The bytes and identity of a picked file, ready to upload.
struct PickedFile: Sendable {
    let name: String
    let data: Data
    let mimeType: String
}

enum PickedFileReader {

    /// Read the file at a picker-supplied URL.
    ///
    /// Safe to call from a `Task` started in the `fileImporter` callback: the
    /// sandbox extension the picker hands over lives until `stopAccessing…`,
    /// not until the callback returns. The read itself happens off the main
    /// actor, because materializing a file the provider still has to download
    /// can take seconds and freezing the app for them is not an option.
    static func read(_ url: URL) async throws -> PickedFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try await Task.detached(priority: .userInitiated) {
            try readCoordinated(url)
        }.value
        return PickedFile(name: url.lastPathComponent,
                          data: data,
                          mimeType: mimeType(for: url))
    }

    /// What to tell the writer when the read failed, or nil when there is
    /// nothing to tell them.
    ///
    /// The system's reason is included: the three things that actually go wrong
    /// here — the file never downloaded, the provider is signed out, the file
    /// moved — are indistinguishable without it, and "Could not read that file."
    /// on its own leaves nobody anywhere to go.
    ///
    /// Nil for a cancelled read, following the rule every reporting path in the
    /// app follows: leaving the screen mid-read is something the writer did,
    /// not something that went wrong.
    static func readFailureMessage(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        return "Could not read that file. \(error.localizedDescription)"
    }

    /// What to tell the writer when the *picker* failed, or nil when there is
    /// nothing to tell them.
    ///
    /// Cancelling is not a failure and has never been worth a banner — but
    /// `fileImporter` reports a tapped Cancel as `.failure(CocoaError
    /// .userCancelled)`, so a closure that shows every failure greets the
    /// writer with "The operation couldn't be completed." for backing out of a
    /// picker. Anything else is the picker itself refusing, and staying silent
    /// about that leaves a tapped Import button looking like a dud.
    static func pickFailureMessage(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        if (error as? CocoaError)?.code == .userCancelled { return nil }
        return error.localizedDescription
    }

    /// The MIME type the server sorts the format by. It reads the filename too,
    /// so the octet-stream fallback — which is what the formats iOS has never
    /// heard of resolve to — still imports.
    static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    /// The coordinated read. iCloud's own placeholders are asked for
    /// explicitly first: the coordinator waits for a download in flight, and
    /// this is what puts one in flight.
    private nonisolated static func readCoordinated(_ url: URL) throws -> Data {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        if values?.isUbiquitousItem == true {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        var coordinationError: NSError?
        var read: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                       error: &coordinationError) { readable in
            read = Result { try Data(contentsOf: readable) }
        }
        // The accessor not running at all means the coordinator refused, and it
        // fills in the error when it does; the last resort is for the case
        // where it somehow did neither.
        if let read { return try read.get() }
        throw coordinationError ?? CocoaError(.fileReadUnknown)
    }
}

/// What became of a batch of picked files, and what to say about it.
///
/// One file has always spoken for itself: the read failure carries the
/// system's reason, an empty file is named as empty, and what lands opens for
/// writing. None of that scales to a folder of lyrics picked at once — a
/// separate alert per file would have to be dismissed one at a time, and the
/// last one to speak would be the only one the writer sees.
///
/// So a batch counts what landed and names what did not. The names are the
/// only part worth carrying: a writer who imported nine files and lost one
/// needs to know *which* one to go back for, and the reason is nearly always
/// the same for every file that failed.
struct PickedFileTally {
    private(set) var imported = 0
    private(set) var failures: [String] = []

    /// How many names to say before counting the rest. Three is where a
    /// sentence stops being a sentence.
    private static let named = 3

    mutating func recordImport() { imported += 1 }

    mutating func recordFailure(_ fileName: String) { failures.append(fileName) }

    /// What to tell the writer, or nil when nothing was attempted.
    ///
    /// `kind` and `plural` are the caller's word for what it imported — a song
    /// or a note — so the sentence names the thing rather than "files".
    ///
    /// `reason` is the server's own words, and is added only when nothing
    /// landed at all: a list of names with no reason beside it is the one case
    /// where the writer has nowhere to go, and when something did land the
    /// reason for the rest is rarely the last error the model happened to hold.
    func message(kind: String, plural: String, reason: String? = nil) -> String? {
        let landed = "\(imported) \(imported == 1 ? kind : plural)"
        guard !failures.isEmpty else {
            return imported == 0 ? nil : "Imported \(landed)."
        }
        let names = Self.list(failures)
        guard imported > 0 else {
            guard let reason, !reason.isEmpty else { return "Could not import \(names)." }
            return "Could not import \(names). \(reason)"
        }
        return "Imported \(landed). Could not import \(names)."
    }

    /// The file names as a sentence reads them.
    private static func list(_ names: [String]) -> String {
        if names.count <= named {
            guard let last = names.last else { return "" }
            guard names.count > 1 else { return last }
            return names.dropLast().joined(separator: ", ") + " and " + last
        }
        let rest = names.count - named
        return names.prefix(named).joined(separator: ", ")
            + " and \(rest) more"
    }
}
