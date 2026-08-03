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
