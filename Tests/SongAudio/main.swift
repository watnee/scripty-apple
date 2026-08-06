//
//  Recordings kept with a song.
//
//  Two things are checked here, and they are the two that would silently break
//  the feature rather than crash it.
//
//  First, the vocabulary: what a recording is called on the wire, what may be
//  done to it, and the fact that `audioFile` — the one href in the API that
//  answers with bytes rather than JSON — is offered to anyone who can open the
//  song, not just to whoever may write it.
//
//  Second, the model that reads it: `SongAudio` has to make sense of what the
//  *server* sends, which is curied (`scripty:audioFile`), optionally missing a
//  duration, and sometimes missing a file name — and it has to turn all of that
//  into the two lines a row draws without ever showing a zero for "unknown".
//

import Foundation

let be = DemoBackend()
var failures = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("  PASS  \(label)") }
    else { failures += 1; print("  FAIL  \(label) \(detail)") }
}

func url(_ p: String) -> URL { URL(string: "https://demo.scripty.local" + p)! }
func json(_ d: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
}
func links(_ o: [String: Any]) -> [String: Any] { o["_links"] as? [String: Any] ?? [:] }
func embedded(_ o: [String: Any]) -> [[String: Any]] {
    guard let e = o["_embedded"] as? [String: Any],
          let first = e.values.first as? [[String: Any]] else { return [] }
    return first
}

/// A multipart body shaped exactly like `APIClient.upload` builds one, so the
/// demo backend's parser is exercised by the same bytes the app sends.
func multipart(fields: [String: String], fileName: String, fileData: Data) -> Data {
    let boundary = APIClient.multipartBoundary
    var body = Data()
    for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
    body.append(Data("Content-Type: audio/mp4\r\n\r\n".utf8))
    body.append(fileData)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
}

func decode(_ object: [String: Any]) -> SongAudio? {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return try? JSONDecoder().decode(SongAudio.self, from: data)
}

// MARK: - The demo backend's side of the contract

func checkBackend() async {
    // The seeded workspace has one song; find it rather than assuming an id.
    let documents = json(await be.respond(method: "GET",
                                          url: url("/api/document?projectId=1&type=SONG"),
                                          body: nil).1)
    guard let song = embedded(documents).first,
          let songId = song["id"] as? Int else {
        check("the seeded workspace has a song to hang recordings off", false)
        return
    }

    check("a song advertises its recordings",
          links(song)["audioRecordings"] != nil)

    // A note does not: there is nothing to hear in one, and a client that drew
    // the row anyway would offer an upload the server refuses.
    let notes = json(await be.respond(method: "GET",
                                      url: url("/api/document?projectId=1&type=NOTES"),
                                      body: nil).1)
    if let note = embedded(notes).first {
        check("a note does not", links(note)["audioRecordings"] == nil)
    }

    let empty = await be.respond(method: "GET",
                                 url: url("/api/song/audio?documentId=\(songId)"), body: nil)
    check("the collection answers before anything is in it", empty.status == 200)
    check("and offers the upload", links(json(empty.1))["uploadAudio"] != nil)
    check("with nothing in it yet", embedded(json(empty.1)).isEmpty)

    // Add one.
    let bytes = Data(repeating: 7, count: 2048)
    let created = await be.respond(
        method: "POST",
        url: url("/api/song/audio?documentId=\(songId)"),
        body: multipart(fields: ["title": "Chorus idea, 2am", "durationMs": "91000"],
                        fileName: "voice-memo-4.m4a", fileData: bytes))
    check("uploading answers 201", created.status == 201, "got \(created.status)")
    let audio = json(created.1)
    let audioId = audio["id"] as? Int ?? -1
    check("the take keeps the name it was given",
          audio["title"] as? String == "Chorus idea, 2am")
    check("and the file name it arrived under",
          audio["fileName"] as? String == "voice-memo-4.m4a")
    check("the type is read from the extension",
          audio["contentType"] as? String == "audio/mp4")
    check("the size is what was sent", audio["byteSize"] as? Int == 2048)
    check("the duration is the one the uploader measured",
          audio["durationMs"] as? Int == 91000)

    check("a take offers its bytes", links(audio)["audioFile"] != nil)
    check("and the two writes", links(audio)["renameAudio"] != nil
          && links(audio)["deleteAudio"] != nil)

    // The bytes come back as bytes — the one route that answers with something
    // other than JSON.
    let file = await be.respond(method: "GET",
                                url: url("/api/song/audio/\(audioId)/file?documentId=\(songId)"),
                                body: nil)
    check("the file comes back whole", file.status == 200 && file.data == bytes,
          "\(file.status), \(file.data.count) bytes")

    // A file that is not audio is refused with a sentence, not a crash.
    let refused = await be.respond(
        method: "POST",
        url: url("/api/song/audio?documentId=\(songId)"),
        body: multipart(fields: [:], fileName: "lyrics.pdf", fileData: bytes))
    check("a file that is not audio is refused", refused.status == 400,
          "got \(refused.status)")

    // Renaming leaves the file alone.
    let renamed = await be.respond(
        method: "PUT",
        url: url("/api/song/audio/\(audioId)?documentId=\(songId)"),
        body: Data(#"{"title":"Verse 2 hum"}"#.utf8))
    check("renaming answers with the take", renamed.status == 200)
    check("under its new name", json(renamed.1)["title"] as? String == "Verse 2 hum")
    check("with the same file behind it",
          json(renamed.1)["fileName"] as? String == "voice-memo-4.m4a")

    // A recording is only ever reachable through the song that holds it.
    let elsewhere = await be.respond(
        method: "GET", url: url("/api/song/audio/\(audioId)/file?documentId=99999"), body: nil)
    check("another song's id finds nothing", elsewhere.status == 404,
          "got \(elsewhere.status)")

    // Deleting answers with what is left, and takes the bytes with it.
    let deleted = await be.respond(
        method: "DELETE",
        url: url("/api/song/audio/\(audioId)?documentId=\(songId)"), body: nil)
    check("deleting answers with the rest", deleted.status == 200)
    check("and there is nothing left", embedded(json(deleted.1)).isEmpty)
    let gone = await be.respond(method: "GET",
                                url: url("/api/song/audio/\(audioId)/file?documentId=\(songId)"),
                                body: nil)
    check("the bytes are gone too", gone.status == 404, "got \(gone.status)")
}

// MARK: - The model that reads it

func checkModel() {
    // What the deployed server sends: curied rels, and a duration.
    let fromServer: [String: Any] = [
        "id": 3,
        "documentId": 12,
        "title": "Chorus idea, 2am",
        "fileName": "voice-memo-4.m4a",
        "contentType": "audio/mp4",
        "byteSize": 3_145_728,
        "durationMs": 91_000,
        "_links": [
            "self": ["href": "/api/song/audio/3?documentId=12"],
            "scripty:audioFile": ["href": "/api/song/audio/3/file?documentId=12"],
            "scripty:renameAudio": ["href": "/api/song/audio/3?documentId=12"],
            "scripty:deleteAudio": ["href": "/api/song/audio/3?documentId=12"],
        ],
    ]
    guard let take = decode(fromServer) else {
        check("a curied recording decodes", false)
        return
    }
    check("a curied audioFile resolves", take.fileLink != nil)
    check("a curied renameAudio resolves", take.canRename)
    check("a curied deleteAudio resolves", take.canDelete)
    check("the duration reads as a clock", take.durationText == "1:31",
          "got \(take.durationText)")
    check("the two facts sit on one line",
          take.subtitle.hasPrefix("1:31 · "), "got \(take.subtitle)")

    // What a reader gets: the bytes, and neither write.
    let readOnly: [String: Any] = [
        "id": 4, "title": "Band demo",
        "_links": ["scripty:audioFile": ["href": "/api/song/audio/4/file?documentId=12"]],
    ]
    let heard = decode(readOnly)
    check("a reader can still play a take", heard?.fileLink != nil)
    check("but cannot rename it", heard?.canRename == false)
    check("or delete it", heard?.canDelete == false)

    // A take nobody could measure, uploaded by something that sent no name.
    let bare: [String: Any] = ["id": 5, "contentType": "audio/mpeg"]
    let unknown = decode(bare)
    check("an unmeasured take shows no duration", unknown?.durationText == "")
    check("and no line under its name", unknown?.subtitle == "")
    check("it still has something to be called",
          unknown?.displayTitle == "Recording", "got \(unknown?.displayTitle ?? "nil")")
    check("and something to be saved as",
          unknown?.suggestedFileName == "Recording.mp3",
          "got \(unknown?.suggestedFileName ?? "nil")")

    // An hour-long jam reads in hours, not in 87 minutes.
    let long = decode(["id": 6, "durationMs": 3_723_000])
    check("a long take reads in hours", long?.durationText == "1:02:03",
          "got \(long?.durationText ?? "nil")")

    // The title the writer typed wins over the file's own name.
    let named = decode(["id": 7, "title": "  ", "fileName": "take-3.wav"])
    check("a blank name falls back to the file's",
          named?.displayTitle == "take-3.wav", "got \(named?.displayTitle ?? "nil")")
}

// MARK: - Across a relaunch

/// The signed-out workspace is the writer's only copy, and a recording is the
/// part of it that is *not* in the workspace document — the bytes go to a file
/// of their own beside it. So this drops the backend on the floor and opens a
/// second one on the same store, the way a relaunch does, and asks for both
/// halves back: the description from the snapshot, the sound from the file.
///
/// The failure it is here to catch is silent. `Snapshot` names every store by
/// hand, so one forgotten there still compiles — it just stops surviving
/// relaunches, and nobody finds out until a demo is gone.
func checkRelaunch() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("scripty-song-audio-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let bytes = Data((0..<4096).map { UInt8($0 % 251) })
    var songId = -1
    var audioId = -1

    do {
        let first = DemoBackend(store: LocalWorkspaceStore(directory: directory))
        let documents = json(await first.respond(
            method: "GET", url: url("/api/document?projectId=1&type=SONG"), body: nil).1)
        songId = embedded(documents).first?["id"] as? Int ?? -1
        let created = json(await first.respond(
            method: "POST", url: url("/api/song/audio?documentId=\(songId)"),
            body: multipart(fields: ["title": "Band demo"],
                            fileName: "demo.mp3", fileData: bytes)).1)
        audioId = created["id"] as? Int ?? -1
        check("a take is added in the first session", audioId > 0)
    }

    let second = DemoBackend(store: LocalWorkspaceStore(directory: directory))
    let listed = embedded(json(await second.respond(
        method: "GET", url: url("/api/song/audio?documentId=\(songId)"), body: nil).1))
    check("the take written last session is still there",
          listed.contains { $0["id"] as? Int == audioId },
          "got \(listed.compactMap { $0["title"] as? String })")
    check("under the name it was given",
          listed.first?["title"] as? String == "Band demo")

    let file = await second.respond(
        method: "GET", url: url("/api/song/audio/\(audioId)/file?documentId=\(songId)"), body: nil)
    check("and it still plays — the bytes came back off disk",
          file.status == 200 && file.data == bytes,
          "\(file.status), \(file.data.count) bytes")

    // Deleting it takes the file with it, rather than leaving a megabyte
    // behind for a take nothing lists any more.
    _ = await second.respond(method: "DELETE",
                             url: url("/api/song/audio/\(audioId)?documentId=\(songId)"), body: nil)
    let third = DemoBackend(store: LocalWorkspaceStore(directory: directory))
    let gone = await third.respond(
        method: "GET", url: url("/api/song/audio/\(audioId)/file?documentId=\(songId)"), body: nil)
    check("a deleted take stays deleted across a relaunch", gone.status == 404,
          "got \(gone.status)")
}

await checkBackend()
await checkRelaunch()
checkModel()

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("all checks passed")
