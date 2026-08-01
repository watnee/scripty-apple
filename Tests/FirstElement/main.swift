//
//  main.swift
//  Tests/FirstElement
//
//  A new screenplay opens ready to type into.
//
//  Naming a screenplay used to buy you an empty state and one more button —
//  "Start Writing" — standing between the title you just typed and the first
//  line you meant to type next. The element it created is the only thing an
//  empty script needs, and wanting it is not a question worth asking, so the
//  opening load creates it.
//
//  What that must not become is a create fired at a script that was never
//  read: opening one offline, or opening one whose load failed, has to leave
//  the writer where it always left them rather than raising a second alert on
//  top of the first. Those cases are here too — they are the reason the seed
//  is guarded rather than unconditional.
//
//  The live cases run against the in-process demo backend, so the POST really
//  goes out and the block really comes back; the failure case runs against a
//  closed port, so the failure is a genuine transport failure.
//
//  Run via Tests/run.sh.
//

import Foundation

_ = setvbuf(stdout, nil, _IOLBF, 0)

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

func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
    try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}

// MARK: - Cases

/// The whole point: create a screenplay the way the sidebar's sheet does, open
/// it the way the detail pane does, and find somewhere to type.
@MainActor
func checkNewProjectOpensReadyToType() async {
    print("== A new screenplay opens with its first element already there ==")
    let app = AppModel()
    await app.enterDemo(persisted: false)
    let list = ProjectListModel(app: app)
    await list.refresh()

    guard let created = await list.createProject(title: "Untitled") else {
        check("the demo created a screenplay", false)
        return
    }
    check("the new screenplay has no elements of its own yet",
          created.link(.blocks) != nil)

    let model = ScriptModel(app: app, project: created)
    await model.open()

    checkEqual("opening it left exactly one element", model.blocks.count, 1)
    check("which is empty, so the first thing typed is the writer's",
          model.blocks.first?.content?.isEmpty ?? false)
    check("the caret is already in it",
          model.focusedBlockId != nil && model.focusedBlockId == model.blocks.first?.id)
    check("and nothing was said about any of it", model.errorMessage == nil)

    // The empty state is what the button lived on. With an element there, the
    // script is no longer empty and there is nothing left to seed.
    check("the empty state is gone", !model.blocks.isEmpty)
    check("and with it the offer to seed", !model.canSeedScript)
}

/// Opening the same screenplay again must not keep appending blank elements to
/// it — the seed is for a script with nothing in it, and after the first open
/// there is something.
@MainActor
func checkSecondOpenAddsNothing() async {
    print()
    print("== Opening it again adds nothing ==")
    let app = AppModel()
    await app.enterDemo(persisted: false)
    let list = ProjectListModel(app: app)
    await list.refresh()

    guard let created = await list.createProject(title: "Untitled") else {
        check("the demo created a screenplay", false)
        return
    }
    let first = ScriptModel(app: app, project: created)
    await first.open()
    checkEqual("the first open seeded one element", first.blocks.count, 1)

    // A fresh model against the same project: the detail pane rebuilt, which
    // is the shape that would have doubled the seed.
    let second = ScriptModel(app: app, project: created)
    await second.open()
    checkEqual("the second open left it at one", second.blocks.count, 1)
    checkEqual("and it is the same element",
               second.blocks.first?.id, first.blocks.first?.id)
}

/// A screenplay with a script in it is not a screenplay to seed, however it is
/// opened. The demo's own project comes with elements.
@MainActor
func checkExistingScriptIsUntouched() async {
    print()
    print("== A screenplay with a script in it is left alone ==")
    let app = AppModel()
    await app.enterDemo(persisted: false)
    let list = ProjectListModel(app: app)
    await list.refresh()

    guard let existing = list.projects.first else {
        check("the demo has a screenplay", false)
        return
    }
    let model = ScriptModel(app: app, project: existing)
    await model.open()

    check("its script arrived", model.blocks.count > 1)
    check("nothing blank was appended to it",
          !(model.blocks.last?.content?.isEmpty ?? true))
    check("and no create was offered for it", !model.canSeedScript)
}

/// The guard that matters most: a load that failed has already told the writer
/// once. Firing a create at the same unreachable server would tell them twice,
/// and the second alert would be about a screenplay they can't see.
@MainActor
func checkFailedLoadSeedsNothing() async {
    print()
    print("== A script that never arrived is not seeded over ==")
    // A closed port: nothing is listening, so the load fails the way a lost
    // connection does. The project advertises `blocks`; the collection that
    // would have advertised `createInitial` never lands, which is exactly why
    // the seed cannot be conditioned on that link alone.
    UserDefaults.standard.set("http://127.0.0.1:1", forKey: AppConfig.baseURLOverrideKey)
    let app = AppModel()
    let project: Project = decode(Project.self, """
    {"id": 1, "title": "Unreachable",
     "_links": {"blocks": {"href": "/api/block?projectId=1"}}}
    """)
    let model = ScriptModel(app: app, project: project)
    await model.open()

    check("the script is empty, as it must be", model.blocks.isEmpty)
    check("the writer was told once", model.errorMessage != nil)
    check("and nothing was created to type into", !model.canSeedScript)
    check("the caret was not put anywhere", model.focusedBlockId == nil)
}

// MARK: - Run

await checkNewProjectOpensReadyToType()
await checkSecondOpenAddsNothing()
await checkExistingScriptIsUntouched()
await checkFailedLoadSeedsNothing()

print()
if failures == 0 {
    print("ALL CHECKS PASSED")
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
