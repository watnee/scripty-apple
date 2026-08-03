//
//  main.swift
//  Tests/Cancellation
//
//  What a cancelled request is allowed to do to the writer.
//
//  Cancellation is not a failure. It is what happens when a screen is left
//  mid-load, when a keystroke supersedes the debounce counting down behind the
//  last one, when the sync poll is stopped on the way to the background — all
//  of it this app's own doing, none of it news. Read as a network failure it
//  reaches the writer as "Couldn't reach the server (cancelled)" over a script
//  that was loading perfectly well, and recruits the whole offline apparatus —
//  the stale copy, the banner over it — on the strength of a connection that
//  was never in trouble.
//
//  Every case here drives a real ScriptModel against a real APIClient over a
//  real socket, so the cancellations are genuine Swift task cancellations
//  travelling the genuine error path. Nothing is stubbed.
//

import Foundation

// MARK: - Harness

// Line-buffer stdout so a run that is killed — by the harness watchdog, or by
// hand — still shows which case it had reached.
_ = setvbuf(stdout, nil, _IOLBF, 0)

var failures = 0

func check(_ label: String, _ condition: Bool) {
    print(condition ? "  PASS  \(label)" : "  FAIL  \(label)")
    if !condition { failures += 1 }
}

func checkEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    let ok = actual == expected
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)\n          expected: \(expected)\n          actual:   \(actual)")
    if !ok { failures += 1 }
}

func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
    try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}

// MARK: - A server that can be watched

/// The smallest HTTP server that can answer the two questions this suite asks:
/// *did that request arrive?* and *what happens while one is still open?*
///
/// A closed port is enough for the other network suites, because they only care
/// that a request failed. Here the difference between a request the client sent
/// and a request the client cancelled on its own doorstep is the whole point,
/// and only something listening can tell them apart.
final class TestServer: @unchecked Sendable {
    private let socketFD: Int32
    let port: UInt16

    private let lock = NSLock()
    private var _requests: [String] = []
    /// While true, connections are accepted and then left open unanswered —
    /// a request in flight, for as long as the case needs one.
    private var _hangs = false
    /// How long to hold a request before answering it. A stand-in for the
    /// round trip a real server costs, which is the window a cancellation has
    /// to land in — answered instantly, nothing can be interrupted.
    private var _answersAfter: TimeInterval = 0

    /// Every request line seen so far, newest last, as "METHOD path".
    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var hangs: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _hangs }
        set { lock.lock(); _hangs = newValue; lock.unlock() }
    }

    var answersAfter: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _answersAfter }
        set { lock.lock(); _answersAfter = newValue; lock.unlock() }
    }

    init() {
        // Every member is settled from locals before any closure sees `self`:
        // the socket calls below all take closures, and Swift will not let one
        // capture a half-built object.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // any free port; asked for below
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        withUnsafePointer(to: &address) {
            _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(fd, 16)

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }

        socketFD = fd
        port = UInt16(bigEndian: bound.sin_port)

        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                // A thread per connection, because one of them is deliberately
                // left hanging: served in turn, that connection would hold up
                // every case after it.
                Thread.detachNewThread { self?.serve(client) }
            }
        }
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    private func serve(_ client: Int32) {
        // Writes to a socket the far side has already abandoned must not
        // become a signal: SIGPIPE takes the whole suite down, and abandoned
        // requests are this suite's subject matter.
        var yes: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        guard let text = readRequest(client) else { close(client); return }
        if let line = text.split(separator: "\r\n").first {
            let parts = line.split(separator: " ")
            if parts.count >= 2 {
                lock.lock()
                _requests.append("\(parts[0]) \(parts[1])")
                lock.unlock()
            }
        }
        // Held open and unanswered: the client is left with a request in
        // flight, which is the only state a cancellation can interrupt.
        if hangs {
            Thread.sleep(forTimeInterval: 30)
            close(client)
            return
        }
        let wait = answersAfter
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        let body = Data(answer(to: text).utf8)
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: application/hal+json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        _ = Data(head.utf8).withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        _ = body.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        // Half-close, then wait for the client to hang up before the socket
        // goes away. close() straight after write() races the client's read
        // of the answer — and if anything it sent is still unread on this
        // side, becomes a reset that destroys the answer in flight. The
        // client sees "the network connection was lost" over a server that
        // answered, once in a few hundred requests, only under load: the
        // shape of every flake this suite has had. The timeout keeps a
        // client that never hangs up from pinning this thread.
        shutdown(client, SHUT_WR)
        var linger = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &linger, socklen_t(MemoryLayout<timeval>.size))
        var drain = [UInt8](repeating: 0, count: 1024)
        while read(client, &drain, drain.count) > 0 {}
        close(client)
    }

    /// Reads the whole request: line, headers, and as much body as the
    /// headers promise. The single read() this used to be answered whatever
    /// fit in the first segment — usually everything, but a request split
    /// across segments (a PUT's body travels separately from its headers)
    /// was answered half-read, and the bytes still in the socket turned the
    /// close below into a reset. Nil when the connection opened and died
    /// without a byte, which URLSession's speculative connections do.
    private func readRequest(_ client: Int32) -> String? {
        var received = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var headerLength: Int?
        var bodyLength = 0
        while true {
            if let headerLength, received.count >= headerLength + bodyLength { break }
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            received.append(contentsOf: buffer[0..<count])
            if headerLength == nil, let end = headerEnd(in: received) {
                headerLength = end
                bodyLength = contentLength(in: received[0..<end]) ?? 0
            }
        }
        guard !received.isEmpty else { return nil }
        return String(decoding: received, as: UTF8.self)
    }

    /// The index just past the blank line ending the headers, if it has
    /// arrived yet.
    private func headerEnd(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4)
        where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i + 4
        }
        return nil
    }

    private func contentLength(in header: ArraySlice<UInt8>) -> Int? {
        let head = String(decoding: header, as: UTF8.self)
        for line in head.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// One block for a PUT, the collection for anything else. Enough for the
    /// paths this suite walks; nothing here inspects the rest.
    private func answer(to request: String) -> String {
        if request.hasPrefix("PUT") { return savedBlockJSON }
        if request.contains("/song-blocks") {
            return request.contains("/editions/") ? secondEditionJSON : firstEditionJSON
        }
        return blocksJSON
    }

    func reset() {
        lock.lock(); _requests = []; lock.unlock()
    }

    /// Suspends until at least `count` requests have arrived, or gives up at
    /// the deadline. A fixed sleep here is a bet on machine load: a request
    /// crosses the loopback in milliseconds on a quiet machine and in whole
    /// tenths of a second on a busy one, so the cases wait on the arrival
    /// itself and keep a ceiling only for a request that truly never comes.
    func received(_ count: Int, within deadline: TimeInterval = 10) async -> Bool {
        let cutoff = Date().addingTimeInterval(deadline)
        while requests.count < count {
            if Date() >= cutoff { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

// MARK: - Fixtures

let blocksJSON = """
{
  "_embedded": {
    "blockResourceList": [
      {
        "id": 10, "order": 1, "type": "ACTION", "content": "First line.",
        "_links": {"update": {"href": "/api/blocks/10"}}
      },
      {
        "id": 11, "order": 2, "type": "ACTION", "content": "Second line.",
        "_links": {"update": {"href": "/api/blocks/11"}}
      }
    ]
  },
  "_links": {"self": {"href": "/api/projects/1/blocks"}}
}
"""

let savedBlockJSON = """
{"id": 10, "order": 1, "type": "ACTION", "content": "First line, rewritten.",
 "_links": {"update": {"href": "/api/blocks/10"}}}
"""

let project: Project = decode(Project.self, """
{"id": 1, "title": "Test Script",
 "_links": {"blocks": {"href": "/api/projects/1/blocks"}}}
""")

/// Two editions of one lyric, told apart by their words. The superseded-load
/// case switches between them while the first request is still open, so which
/// set of lines is on screen afterwards is the whole answer.
let firstEditionJSON = """
{
  "_embedded": {
    "songBlockResourceList": [
      {"id": 40, "order": 1, "content": "The first edition's line.",
       "_links": {"update": {"href": "/api/song-blocks/40"}}}
    ]
  },
  "_links": {"self": {"href": "/api/documents/8/song-blocks"}}
}
"""

let secondEditionJSON = """
{
  "_embedded": {
    "songBlockResourceList": [
      {"id": 50, "order": 1, "content": "The second edition's line.",
       "_links": {"update": {"href": "/api/song-blocks/50"}}}
    ]
  },
  "_links": {"self": {"href": "/api/editions/2/song-blocks"}}
}
"""

let song: TextDocument = decode(TextDocument.self, """
{"id": 8, "projectId": 1, "title": "Test Song", "documentType": "SONG",
 "_links": {"songBlocks": {"href": "/api/documents/8/song-blocks"}}}
""")

let secondEditionLink: HALLink = decode(HALLink.self,
                                        #"{"href": "/api/editions/2/song-blocks"}"#)

@MainActor
func makeModel() -> ScriptModel {
    ScriptModel(app: AppModel(), project: project)
}

/// The load a case stands on, not the behavior it checks: fetches the script
/// and hands back its first block. A script that failed to arrive is recorded
/// as its own FAIL and the case is skipped — subscripting the empty array
/// instead was how one flaked transport used to crash the binary and take
/// the rest of the suite's cases down with it.
@MainActor
func firstBlock(of model: ScriptModel) async -> Block? {
    await model.loadBlocks()
    check("the script loaded before the case began", !model.blocks.isEmpty)
    return model.blocks.first
}

/// Suspends until a condition holds, or gives up at the deadline. The same bet
/// `TestServer.received` refuses to make: a fixed sleep is a guess about
/// machine load, and the thing being waited for can say when it has happened.
@MainActor
func settle(within deadline: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let cutoff = Date().addingTimeInterval(deadline)
    while !condition() {
        if Date() >= cutoff { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

// MARK: - Cases

@MainActor
func run() async {
    let server = TestServer()
    UserDefaults.standard.set(server.baseURL, forKey: AppConfig.baseURLOverrideKey)

    print("== A cancelled request is named for what it is ==")
    do {
        checkEqual("URLSession's cancellation is not a transport failure",
                   APIError.from(transportError: URLError(.cancelled)), APIError.cancelled)
        checkEqual("nor is Swift's own",
                   APIError.from(CancellationError()), APIError.cancelled)
        check("and it knows itself", APIError.cancelled.isCancellation)
        check("as does anything holding one", (APIError.cancelled as Error).isCancelledRequest)
        check("a real transport failure does not",
              !(APIError.transport("bad certificate") as Error).isCancelledRequest)
        // The string the writer was being shown. Nothing should ever be able to
        // assemble it out of a cancellation again.
        check("it never reads as an unreachable server",
              APIError.cancelled.errorDescription?.contains("Couldn't reach the server") != true)
        check("it is not worth retrying as a network failure",
              !APIError.cancelled.isRetryable)
        check("unlike the transport failures it used to be filed under",
              APIError.transport("connection reset").isRetryable)
    }

    print()
    print("== A load cancelled mid-flight says nothing ==")
    do {
        server.hangs = true
        server.reset()
        let model = makeModel()

        // The script view's `.task`, and what happens to it when the writer
        // leaves the screen: the load is abandoned with the request open.
        let load = Task { await model.loadBlocks() }
        check("the request did reach the server", await server.received(1))
        load.cancel()
        await load.value

        check("no alert is raised", model.errorMessage == nil)
        check("the writer is not told they are offline",
              !model.isShowingOfflineCopy)
        check("and nothing half-loaded is adopted", model.blocks.isEmpty)
        server.hangs = false
    }

    print()
    print("== A cancelled load leaves the script that was already there ==")
    do {
        server.reset()
        let model = makeModel()
        await model.loadBlocks()
        checkEqual("the script loaded", model.blocks.count, 2)

        // The sync poll, stopped on the way to the background while its reload
        // is open — the model outlives this one, so anything it reports lands
        // on a screen the writer is still looking at.
        server.hangs = true
        server.reset()
        let poll = Task { await model.loadBlocks() }
        check("the reload reached the server", await server.received(1))
        poll.cancel()
        await poll.value

        check("the script is untouched", model.blocks.count == 2)
        check("no alert is raised", model.errorMessage == nil)
        check("no offline banner is raised", !model.isShowingOfflineCopy)
        server.hangs = false
    }

    print()
    print("== Opening a screenplay outlives the screen that asked for it ==")
    do {
        server.reset()
        server.answersAfter = 0.4
        let model = makeModel()

        // Tapping a screenplay builds the detail pane, and SwiftUI takes that
        // build down and puts up another as the navigation settles — cancelling
        // the `.task` the first one started, with the script still on the wire.
        // Nothing awaits it after that, so the load has to land on its own.
        let opening = Task { await model.open() }
        check("the request did reach the server", await server.received(1))
        opening.cancel()

        // Deliberately not `await opening.value`: the screen that started this
        // is gone. Waiting past the round trip is the writer sitting in front
        // of the screenplay they just tapped.
        try? await Task.sleep(for: .milliseconds(900))

        checkEqual("the script arrived anyway", model.blocks.count, 2)
        check("so no empty-script placeholder is ever shown", !model.blocks.isEmpty)
        check("and it did not need a second request",
              server.requests.count == 1)
        check("with nothing to alarm the writer", model.errorMessage == nil)
        server.answersAfter = 0
    }

    print()
    print("== A script that never arrived is fetched again, not left blank ==")
    do {
        server.reset()
        server.hangs = true
        let model = makeModel()

        // The load abandoned mid-flight by something no longer owned here —
        // a pull-to-refresh the writer navigated away from, say. It says
        // nothing, by design; what it must not do is settle as an empty script
        // that only a second pull would fix.
        let abandoned = Task { await model.loadBlocks() }
        check("the pull reached the server", await server.received(1))
        abandoned.cancel()
        await abandoned.value
        check("nothing is on screen yet", model.blocks.isEmpty)
        check("and nothing was said about it", model.errorMessage == nil)

        // The sync poll is the only thing still running, and it now treats a
        // script that never arrived as work rather than as a baseline.
        server.hangs = false
        model.startSyncPolling()
        try? await Task.sleep(for: .milliseconds(6000))

        checkEqual("the poll fetched the script", model.blocks.count, 2)
        model.stopSyncPolling()
    }

    print()
    print("== The debounced save actually goes out ==")
    debounced: do {
        server.reset()
        let model = makeModel()
        guard let first = await firstBlock(of: model) else { break debounced }
        server.reset()

        model.liveEdit(first, text: "First line, rewritten.")
        // Past the 600ms debounce and well short of the 2s first retry, so
        // only the debounce itself can have sent anything. The debounce task
        // holds its own handle, and `commit` cancels that handle to supersede
        // a save still counting down: reaching commit through the task means
        // cancelling the caller from inside the call, and the PUT going out on
        // a task already cancelled. It fails instantly, and the writer's words
        // wait on a retry for work that should have landed here.
        try? await Task.sleep(for: .milliseconds(1200))

        checkEqual("the PUT reached the server", server.requests, ["PUT /api/blocks/10"])
        check("nothing is left flagged unsaved", model.unsavedBlockIds.isEmpty)
        check("and the writer is shown no error", model.errorMessage == nil)
    }

    print()
    print("== A superseded debounce is still not an error ==")
    superseded: do {
        server.reset()
        let model = makeModel()
        guard let first = await firstBlock(of: model) else { break superseded }
        server.reset()

        // Typing on: each keystroke replaces the save the last one armed.
        for text in ["F", "Fi", "Fir", "First line, rewritten."] {
            model.liveEdit(first, text: text)
            try? await Task.sleep(for: .milliseconds(80))
        }
        try? await Task.sleep(for: .milliseconds(1200))

        checkEqual("one save, not one per keystroke", server.requests.count, 1)
        check("no alert followed the cancelled ones", model.errorMessage == nil)
    }

    print()
    print("== A superseded load never lands on the edition that replaced it ==")
    do {
        server.reset()
        let model = SongBlockModel(app: AppModel(), document: song)

        // The first edition answers slowly; while its request is still open
        // the writer picks another edition, whose request is answered at once.
        // Without a generation check the slow answer arrives last and wins,
        // and the writer types their next line into the wrong edition.
        server.answersAfter = 0.6
        let first = Task { await model.load() }
        check("the first edition's request did go out", await server.received(1))

        // Picking an edition is what loads it — the link's `didSet` fires the
        // request, exactly as the editions picker does.
        server.answersAfter = 0
        model.editionBlocksLink = secondEditionLink
        check("the chosen edition's request went out too", await server.received(2))
        check("and its lines arrived", await settle { !model.blocks.isEmpty })

        checkEqual("the edition the writer chose is on screen",
                   model.blocks.first?.text, "The second edition's line.")
        await first.value
        checkEqual("and the slow answer that followed it changed nothing",
                   model.blocks.first?.text, "The second edition's line.")
        check("with the spinner put away", !model.isLoading)
        check("and no alert raised", model.errorMessage == nil)
        server.answersAfter = 0
    }

    print()
    if failures == 0 {
        print("ALL CHECKS PASSED")
    } else {
        print("\(failures) CHECK(S) FAILED")
    }
}

await run()
exit(failures == 0 ? 0 : 1)

// `APIError` carries associated values, so equality for the assertions above
// is spelled out rather than synthesised (as in Tests/UnsavedWork).
extension APIError: Equatable {
    static func == (lhs: APIError, rhs: APIError) -> Bool {
        switch (lhs, rhs) {
        case (.unauthorized, .unauthorized), (.forbidden, .forbidden),
             (.notFound, .notFound), (.offline, .offline), (.timedOut, .timedOut),
             (.cancelled, .cancelled):
            return true
        case (.validation(let a), .validation(let b)): return a == b
        case (.server(let a), .server(let b)): return a == b
        case (.invalidLink(let a), .invalidLink(let b)): return a == b
        case (.transport(let a), .transport(let b)): return a == b
        default: return false
        }
    }
}
