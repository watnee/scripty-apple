//
//  main.swift
//  Tests/SongLines
//
//  Backspace at the head of a lyric line.
//
//  A lyric is a list of separately stored lines, so folding one into the line
//  above is not an edit — it is an edit, a delete, and a caret placed at the
//  seam between two lines that used to be apart. Each of those can be right on
//  its own while the result is wrong: the words joined in the wrong order, the
//  half-typed line committed as it was on the server rather than as it is on
//  screen, or a fold offered on the first line of the song, where there is
//  nothing above to fold into.
//
//  Driven against the in-process demo backend, so the whole round trip runs —
//  the PUT, the DELETE, and the reload that follows them.
//
//  Run via Tests/run.sh.
//

import Foundation

var failures = 0

func check(_ label: String, _ condition: Bool) {
    print(condition ? "  PASS  \(label)" : "  FAIL  \(label)")
    if !condition { failures += 1 }
}

func checkEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    let ok = actual == expected
    print(ok ? "  PASS  \(label)"
             : "  FAIL  \(label)\n          expected: \(expected)\n          actual:   \(actual)")
    if !ok { failures += 1 }
}

// MARK: - Harness

/// The demo project's first song, with its lyric loaded.
@MainActor
func openASong() async -> SongBlockModel? {
    let app = AppModel()
    await app.enterDemo()
    guard let projectsLink = app.apiRoot?.link(.projects),
          let projects: HALCollection<Project> = try? await app.client.fetch(from: projectsLink),
          let project = projects.items.first
    else {
        check("the demo has a project", false)
        return nil
    }

    let script = ScriptModel(app: app, project: project)
    await script.loadDocuments()
    guard let song = script.documents.first(where: { $0.kind == .song && $0.hasLink(.songBlocks) })
    else {
        check("the demo has a song kept as lyric lines", false)
        return nil
    }

    let model = SongBlockModel(app: app, document: song)
    await model.load()
    return model
}

// MARK: - Cases

@MainActor
func run() async {
    guard let model = await openASong() else { return }
    guard model.blocks.count >= 3 else {
        check("the song has lines to fold together", false)
        return
    }

    print("Folding a line into the one above")
    do {
        let first = model.blocks[0]
        let second = model.blocks[1]
        let firstText = first.text
        let secondText = second.text
        let lineCount = model.blocks.count

        let target = await model.mergeIntoPrevious(second)

        checkEqual("the caret is sent to the line above", target, first.id)
        checkEqual("the folded line is gone", model.blocks.count, lineCount - 1)
        checkEqual("the words are joined in the order they were read",
                   model.blocks.first?.text, firstText + secondText)
        checkEqual("and the caret lands on the seam between them",
                   model.caretRequests[first.id], firstText.count)
    }

    print("")
    print("What is on screen, not what was last saved")
    do {
        // The line being folded away is the one most likely to be mid-edit: the
        // writer is at its head with the caret, which is where they got to by
        // typing. Its unsaved text has to travel, or the Backspace silently
        // reverts it to whatever the server last heard.
        let first = model.blocks[0]
        let second = model.blocks[1]
        let firstText = first.text
        model.edit(second, text: "typed but not yet sent")

        let target = await model.mergeIntoPrevious(second)

        checkEqual("the fold carries the unsaved words", target, first.id)
        checkEqual("joined onto the line above",
                   model.blocks.first?.text, firstText + "typed but not yet sent")
        check("and nothing is left holding them", model.liveText.isEmpty)
    }

    print("")
    print("The first line has nowhere to go")
    do {
        let first = model.blocks[0]
        let lineCount = model.blocks.count
        let text = first.text
        // Whatever the last fold left behind, not nil: a caret request is
        // cleared by the row that consumes it, and no row is running here.
        let caret = model.caretRequests

        let target = await model.mergeIntoPrevious(first)

        checkEqual("Backspace at the top of the song does nothing", target, nil)
        checkEqual("and takes no line with it", model.blocks.count, lineCount)
        checkEqual("nor changes the line itself", model.blocks.first?.text, text)
        check("nor moves anybody's caret", model.caretRequests == caret)
    }

    print("")
    print("An empty line is the ordinary case")
    do {
        // What a Return pressed by mistake leaves behind, and the reason this
        // key is reached for at all: the line above must come back unchanged.
        guard let created = await model.addLine(below: model.blocks[0]) else {
            check("the demo song takes a new line", false)
            return
        }
        guard let empty = model.blocks.first(where: { $0.id == created }) else {
            check("the new line is in the lyric", false)
            return
        }
        let above = model.blocks[0]
        let aboveText = above.text
        let lineCount = model.blocks.count

        let target = await model.mergeIntoPrevious(empty)

        checkEqual("the empty line is removed", model.blocks.count, lineCount - 1)
        checkEqual("the caret goes back where it came from", target, above.id)
        checkEqual("and the line above is untouched", model.blocks.first?.text, aboveText)
        checkEqual("with the caret back at its end",
                   model.caretRequests[above.id], aboveText.count)
    }

    print("")
    print("Return puts its line on screen without a reload")
    do {
        // The create answers with the one new line, and the model shows that
        // reply rather than fetching the collection again — so the line must
        // land in the right place with the right margin number, not wherever
        // the reply's own (unrenumbered) order would sort it.
        let anchor = model.blocks[0]
        guard let created = await model.addLine(below: anchor) else {
            check("the demo song takes a new line", false)
            return
        }

        checkEqual("the new line sits directly below the one Return was pressed in",
                   model.blocks.indices.contains(1) ? model.blocks[1].id : nil, created)
        checkEqual("the caret is asked into it", model.focusRequest, created)
        checkEqual("and the margin numbers still count 1, 2, 3…",
                   model.blocks.map { $0.order ?? 0 },
                   Array(1...model.blocks.count))

        // A reload adopts the server's own numbering; nothing should move.
        let shown = model.blocks.map { [$0.id, $0.order ?? 0] }
        await model.load()
        checkEqual("which is the numbering the server confirms on the next load",
                   model.blocks.map { [$0.id, $0.order ?? 0] }, shown)

        _ = await model.mergeIntoPrevious(model.blocks[1])
    }
}

await run()

print("")
if failures == 0 {
    print("Lyric line checks passed.")
    exit(0)
} else {
    print("\(failures) lyric line check(s) FAILED.")
    exit(1)
}
