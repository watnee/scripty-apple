//
//  Reading a picked file
//
//  Importing a Word document into a song, a note or a screenplay begins here,
//  and it used to end here too: the read was a bare `Data(contentsOf:)`, which
//  fails outright on a file the Files provider has not materialized — the usual
//  state of a .docx kept in iCloud Drive or OneDrive. What the writer got back
//  was "Could not read that file." with nothing to act on.
//
//  A coordinated read cannot be provoked from a command-line suite: there is no
//  provider here to hand back a placeholder. What can be pinned is everything
//  around it — that an ordinary file still reads, that a file that genuinely is
//  not there fails with the system's reason attached rather than swallowed, and
//  that the MIME types the server sorts formats by are the ones it looks for.
//
//  Run via Tests/run.sh.
//

import Foundation

var failures = 0

func check(_ label: String, _ actual: some Equatable, _ expected: some Equatable) {
    if "\(actual)" == "\(expected)" {
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label) — expected \(expected), got \(actual)")
    }
}

func expect(_ label: String, _ condition: Bool) {
    if condition {
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)")
    }
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("picked-file-checks-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

func write(_ name: String, _ bytes: Data) -> URL {
    let url = scratch.appendingPathComponent(name)
    try? bytes.write(to: url)
    return url
}

@MainActor
func run() async {
    print("MIME types the server sorts by")
    do {
        // The server's extractor keys off `wordprocessingml.document` and
        // `application/msword`, plus the filename. If these drift, a Word file
        // arrives as raw bytes and the writer imports the zip as their lyric.
        let docx = scratch.appendingPathComponent("Lyrics.docx")
        expect("a .docx says wordprocessingml.document",
               PickedFileReader.mimeType(for: docx).contains("wordprocessingml.document"))
        let doc = scratch.appendingPathComponent("Lyrics.doc")
        check("a .doc says msword",
              PickedFileReader.mimeType(for: doc), "application/msword")
        let text = scratch.appendingPathComponent("Lyrics.txt")
        check("plain text says text/plain",
              PickedFileReader.mimeType(for: text), "text/plain")
        // Fountain and MusicXML are formats iOS has never heard of. They fall
        // back rather than resolving to something wrong, and the server reads
        // the filename for them.
        let fountain = scratch.appendingPathComponent("Draft.fountain")
        check("an unknown extension falls back",
              PickedFileReader.mimeType(for: fountain), "application/octet-stream")
    }

    print("")
    print("Reading a file that is there")
    do {
        let url = write("Song.txt", Data("first line\nsecond line".utf8))
        do {
            let picked = try await PickedFileReader.read(url)
            check("keeps the filename", picked.name, "Song.txt")
            check("carries the bytes",
                  String(data: picked.data, encoding: .utf8) ?? "", "first line\nsecond line")
            check("carries the type", picked.mimeType, "text/plain")
        } catch {
            failures += 1
            print("  FAIL  a plain local file should read — \(error)")
        }
    }

    print("")
    print("Reading a file that is not")
    do {
        let missing = scratch.appendingPathComponent("Nowhere.docx")
        do {
            _ = try await PickedFileReader.read(missing)
            failures += 1
            print("  FAIL  a missing file should throw")
        } catch {
            print("  PASS  a missing file throws")
            let message = PickedFileReader.readFailureMessage(error) ?? ""
            expect("the message still opens with the plain sentence",
                   message.hasPrefix("Could not read that file."))
            // The whole point of the rewrite: the writer is told *why*. The
            // system names the file it could not open, so that is what proves
            // the reason survived rather than being swallowed.
            expect("the message carries the system's reason",
                   message.contains("Nowhere.docx") && message.count > "Could not read that file.".count)
        }
        // Leaving the screen mid-read is not news. Every reporting path in the
        // app drops a cancellation rather than alarming the writer with one.
        expect("a cancelled read says nothing",
               PickedFileReader.readFailureMessage(CancellationError()) == nil)
    }

    print("")
    print("Backing out of the picker is not a failure")
    do {
        // `fileImporter` reports a tapped Cancel as a `.failure`, so every
        // importer that shows each failure greeted the writer with "The
        // operation couldn't be completed." for changing their mind.
        expect("a tapped Cancel says nothing",
               PickedFileReader.pickFailureMessage(CocoaError(.userCancelled)) == nil)
        expect("nor does an abandoned pick",
               PickedFileReader.pickFailureMessage(CancellationError()) == nil)
        // A picker that genuinely refused still has to be heard, or a tapped
        // Import button looks like a dud.
        let refused = PickedFileReader.pickFailureMessage(CocoaError(.fileReadNoSuchFile))
        expect("a real refusal is still reported", refused != nil)
        expect("and carries the system's own reason", refused?.isEmpty == false)
    }

    print("")
    print("An empty file is read, not refused")
    do {
        // Emptiness is the caller's to report — every importer says "That file
        // is empty." rather than passing zero bytes to the server, which would
        // come back as a bare import failure.
        let url = write("Blank.docx", Data())
        do {
            let picked = try await PickedFileReader.read(url)
            expect("reads as zero bytes", picked.data.isEmpty)
        } catch {
            failures += 1
            print("  FAIL  an empty file should still read — \(error)")
        }
    }
}

await run()

print("")
if failures == 0 {
    print("Picked-file checks passed.")
    exit(0)
} else {
    print("\(failures) picked-file check(s) FAILED.")
    exit(1)
}
