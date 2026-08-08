//
//  Export setting checks
//
//  Three standing answers, and every one of them has a way of going wrong
//  quietly. The preferred format has to move one item and disturb nothing
//  else, and has to leave a menu that does not offer it exactly as it was —
//  a rule that only shows itself on the surfaces where the format is missing,
//  which is most of them for Final Draft and MusicXML. The page-setup switch
//  has to read an absent key as *on*, or the first launch after it shipped
//  would silently stop honouring a page setup the writer had already chosen.
//  And the date on a file name has to be the sortable, fixed one rather than
//  the device's, because a localised date is one slash away from being a path
//  separator in the middle of a filename.
//
//  The rel-to-format map is checked here too: it is the thing that lets one
//  stored preference answer for six export menus, and a rel left out of it
//  goes wrong by doing nothing at all.
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

/// A throwaway store per case, so one check cannot colour the next.
func scratch(_ name: String) -> UserDefaults {
    let suite = "scripty.tests.exportsettings.\(name)"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

/// Stands in for `ScriptModel.ExportOption`: the ordering only ever asks an
/// option what family it belongs to, and it is written generically so that it
/// can be checked without the whole export stack compiled beside it.
struct Option: Equatable {
    let label: String
    let format: ExportFormat?
}

func labels(_ options: [Option]) -> String {
    options.map(\.label).joined(separator: ", ")
}

/// The screenplay's menu, in the order the model builds it.
let screenplay = [
    Option(label: "PDF", format: .pdf),
    Option(label: "Fountain", format: .text),
    Option(label: "Word", format: .word),
    Option(label: "Final Draft", format: .finalDraft),
    Option(label: "EPUB", format: .epub),
    Option(label: "Scripty Archive", format: nil),
]

/// A song's, which leads with Text rather than PDF — the reason a shipped
/// default of any one format would have rearranged somebody's menu.
let song = [
    Option(label: "Text", format: .text),
    Option(label: "PDF", format: .pdf),
    Option(label: "Word", format: .word),
    Option(label: "EPUB", format: .epub),
    Option(label: "MusicXML", format: .musicXml),
]

@MainActor
func runPreferredFormat() {
    print("Preferred format")
    let store = scratch("format")
    let settings = ExportSettings(defaults: store)

    // Nothing to begin with: both menus stand as the server advertised them.
    check("no preference on a first run", settings.preferredFormat == nil, true)
    check("so a screenplay menu is untouched",
          labels(settings.ordered(screenplay) { $0.format }), labels(screenplay))
    check("and a song's leads with Text",
          labels(settings.ordered(song) { $0.format }), labels(song))

    settings.preferredFormat = .word
    check("Word comes first in a screenplay menu",
          labels(settings.ordered(screenplay) { $0.format }),
          "Word, PDF, Fountain, Final Draft, EPUB, Scripty Archive")
    // One item moves; the rest keep the order they were built in.
    check("and in a song's",
          labels(settings.ordered(song) { $0.format }), "Word, Text, PDF, EPUB, MusicXML")

    // Text means Fountain on a screenplay and a .txt on a song: one wish, two
    // spellings, which is the whole reason the preference is a family.
    settings.preferredFormat = .text
    check("Text reaches Fountain",
          settings.ordered(screenplay) { $0.format }.first?.label ?? "", "Fountain")
    check("and a song's plain text",
          settings.ordered(song) { $0.format }.first?.label ?? "", "Text")

    // A menu without the format is left alone rather than rearranged around
    // something that is not in it.
    settings.preferredFormat = .finalDraft
    check("Final Draft leads a screenplay",
          settings.ordered(screenplay) { $0.format }.first?.label ?? "", "Final Draft")
    check("and leaves a song's menu as it was",
          labels(settings.ordered(song) { $0.format }), labels(song))

    settings.preferredFormat = .musicXml
    check("MusicXML leads a song",
          settings.ordered(song) { $0.format }.first?.label ?? "", "MusicXML")
    check("and leaves a screenplay's menu as it was",
          labels(settings.ordered(screenplay) { $0.format }), labels(screenplay))

    check("the choice survives a relaunch",
          ExportSettings(defaults: store).preferredFormat == .musicXml, true)

    // Back to no preference: the key goes rather than holding an empty string,
    // so a reopened store reads "never chosen" and not "chose nothing".
    settings.preferredFormat = nil
    check("clearing it removes the key",
          store.object(forKey: "scripty-export-format") == nil, true)
    check("and the menus come back as advertised",
          labels(ExportSettings(defaults: store).ordered(song) { $0.format }), labels(song))

    // A format name nothing recognises — one dropped from a later build, or a
    // key someone edited — is no preference at all.
    let stale = scratch("format-stale")
    stale.set("laserdisc", forKey: "scripty-export-format")
    check("an unknown format reads as no preference",
          ExportSettings(defaults: stale).preferredFormat == nil, true)
}

@MainActor
func runPageSetup() {
    print("")
    print("Page setup in exports")
    let store = scratch("pagesetup")

    // The one that would have gone wrong silently: before this switch existed
    // every paged export carried the writer's setup, so an absent key has to
    // keep doing that rather than reading as false.
    check("on when the key has never been written",
          ExportSettings(defaults: store).usesPageSetup, true)

    let settings = ExportSettings(defaults: store)
    settings.usesPageSetup = false
    check("turning it off is stored",
          store.object(forKey: "scripty-export-page-setup") as? Bool ?? true, false)
    check("and survives a relaunch",
          ExportSettings(defaults: store).usesPageSetup, false)

    settings.usesPageSetup = true
    check("and back on again",
          ExportSettings(defaults: store).usesPageSetup, true)
}

@MainActor
func runFileNames() {
    print("")
    print("Dated file names")
    let store = scratch("filenames")
    let settings = ExportSettings(defaults: store)

    // Noon on a known day *here*, not an instant: the stamp is the writer's
    // own date, so a fixed epoch second would name the day before on any
    // machine west of Greenwich and pass or fail by time zone.
    let day = Calendar.current.date(
        from: DateComponents(year: 2026, month: 8, day: 8, hour: 12))!

    check("off on a first run", settings.namesFilesWithDate, false)
    check("so a file keeps the name it had",
          settings.fileName(for: "Sunset Boulevard", on: day), "Sunset Boulevard")

    settings.namesFilesWithDate = true
    check("the date goes on the end, sortable",
          settings.fileName(for: "Sunset Boulevard", on: day), "Sunset Boulevard 2026-08-08")
    // Written the same way whatever the device's own date format is: a
    // localised date could put a slash in the middle of a filename, and a
    // folder of drafts is only in order if they are all written alike.
    check("and is the same string as the example the settings screen shows",
          ExportSettings.stamp(for: day), "2026-08-08")
    check("the choice survives a relaunch",
          ExportSettings(defaults: store).namesFilesWithDate, true)

    // A nameless document would otherwise come out as a file whose name starts
    // with a space. The callers all pass a fallback name, so this is a belt
    // rather than a brace — but it is one line, and the alternative is a file
    // called " 2026-08-08.pdf".
    check("a name that is nothing but the date has no leading space",
          settings.fileName(for: "", on: day), "2026-08-08")

    settings.namesFilesWithDate = false
    check("turning it off gives the plain name back",
          settings.fileName(for: "Sunset Boulevard", on: day), "Sunset Boulevard")
}

@MainActor
func runFormatFamilies() {
    print("")
    print("Which rel is which format")

    // Every export rel the app knows, and the family it belongs to. The point
    // of the map is that four rels can mean "PDF"; a rel missing from it goes
    // wrong by doing nothing, which is the sort of thing only a list catches.
    let expected: [(Rel, ExportFormat?)] = [
        (.exportPdf, .pdf), (.exportSongPdf, .pdf),
        (.exportSongsPdf, .pdf), (.exportNotesPdf, .pdf),
        (.exportDocx, .word), (.exportSongDocx, .word),
        (.exportSongsDocx, .word), (.exportNotesDocx, .word),
        (.exportEpub, .epub), (.exportSongEpub, .epub),
        (.exportSongsEpub, .epub), (.exportNotesEpub, .epub),
        (.export, .text), (.exportSongTxt, .text),
        (.exportSongsTxt, .text), (.exportNotesTxt, .text),
        (.exportFdx, .finalDraft),
        (.exportSongMusicXml, .musicXml), (.exportSongsMusicXml, .musicXml),
        // The archive is the whole project in a bundle rather than a draft to
        // carry away, and is deliberately nobody's preferred format.
        (.exportArchive, nil),
    ]
    for (rel, format) in expected {
        check("\(rel.rawValue) is \(format?.label ?? "no format")",
              ExportFormat(rel: rel) == format, true)
    }

    // Not an export at all — the map has to say so rather than guess from the
    // spelling of the rel.
    check("a rel that is not an export has no format",
          ExportFormat(rel: .update) == nil, true)
}

MainActor.assumeIsolated {
    runPreferredFormat()
    runPageSetup()
    runFileNames()
    runFormatFamilies()
}

print("")
if failures == 0 {
    print("Export setting checks passed.")
    exit(0)
} else {
    print("\(failures) export setting check(s) FAILED.")
    exit(1)
}
