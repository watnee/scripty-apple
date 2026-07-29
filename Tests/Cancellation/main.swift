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

    /// Every request line seen so far, newest last, as "METHOD path".
    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var hangs: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _hangs }
        set { lock.lock(); _hangs = newValue; lock.unlock() }
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
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = read(client, &buffer, buffer.count)
        guard count > 0 else { close(client); return }
        let text = String(decoding: buffer[0..<count], as: UTF8.self)
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
        close(client)
    }

    /// One block for a PUT, the collection for anything else. Enough for the
    /// paths this suite walks; nothing here inspects the rest.
    private func answer(to request: String) -> String {
        request.hasPrefix("PUT") ? savedBlockJSON : blocksJSON
    }

    func reset() {
        lock.lock(); _requests = []; lock.unlock()
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

@MainActor
func makeModel() -> ScriptModel {
    ScriptModel(app: AppModel(), project: project)
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
        try? await Task.sleep(for: .milliseconds(300))
        checkEqual("the request did reach the server", server.requests.count, 1)
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
        let poll = Task { await model.loadBlocks() }
        try? await Task.sleep(for: .milliseconds(300))
        poll.cancel()
        await poll.value

        check("the script is untouched", model.blocks.count == 2)
        check("no alert is raised", model.errorMessage == nil)
        check("no offline banner is raised", !model.isShowingOfflineCopy)
        server.hangs = false
    }

    print()
    print("== The debounced save actually goes out ==")
    do {
        server.reset()
        let model = makeModel()
        await model.loadBlocks()
        let first = model.blocks[0]
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
    do {
        server.reset()
        let model = makeModel()
        await model.loadBlocks()
        let first = model.blocks[0]
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
