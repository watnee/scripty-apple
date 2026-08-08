//
//  ExportSettings.swift
//  scripty
//
//  The standing answers every export follows: which format is offered first,
//  whether a paged export carries the writer's own page setup or the standard
//  sheet, and what the file that comes out is called.
//
//  Until these existed the only thing that shaped an export was page setup,
//  and it was borrowed silently from page view — a writer who set A4 to see
//  the sheets they print on had every PDF they exported quietly follow, with
//  nowhere to say otherwise. These are the three questions worth answering
//  once instead of at every export, gathered where the app's other standing
//  answers live.
//
//  Device preferences, like the type size and the default font beside them:
//  nothing here changes a stored word, and the web app has no counterpart to
//  sync with. Each one is spelled the web's way all the same, so the keys sit
//  with the rest.
//
//  Deliberately free of the rest of the app — no ScriptModel, no
//  PresentationSettings. The ordering below is generic over "something with a
//  format" precisely so this file can be reasoned about, and checked, on its
//  own; the callers hold the export options and the page setup, and hand over
//  only what the answer needs.
//

import Foundation
import Observation

@Observable
@MainActor
final class ExportSettings {
    /// Shared, because six surfaces offer an export and all of them are asking
    /// the same writer the same question.
    static let shared = ExportSettings()

    // MARK: - Preferred format

    /// The format to put at the top of every export menu, or nil to leave each
    /// menu in the order the server advertised it.
    ///
    /// Nil to begin with, and that is not shyness: the lists are already
    /// ordered sensibly and differently — a screenplay leads with PDF, a song
    /// with Text — so a shipped default of any one format would silently
    /// rearrange menus for every writer who never asked for anything.
    var preferredFormat: ExportFormat? {
        didSet {
            guard preferredFormat != oldValue else { return }
            if let preferredFormat {
                defaults.set(preferredFormat.rawValue, forKey: Key.format)
            } else {
                defaults.removeObject(forKey: Key.format)
            }
        }
    }

    /// The same options with the preferred format first, and everything else
    /// in the order it arrived.
    ///
    /// Stable on purpose. This moves one item and disturbs nothing else, so a
    /// menu a writer has learned the shape of stays the shape they learned
    /// apart from the one line they asked to be able to reach without looking.
    ///
    /// Generic over the option type rather than taking `ScriptModel.ExportOption`:
    /// the rule is "put this family first", and it should not need the whole
    /// export stack compiled beside it to say so.
    func ordered<Option>(_ options: [Option],
                         format: (Option) -> ExportFormat?) -> [Option] {
        guard let preferred = preferredFormat else { return options }
        let first = options.filter { format($0) == preferred }
        // A surface that does not offer it is left exactly as it was, rather
        // than being reordered around a format that is not there.
        guard !first.isEmpty else { return options }
        return first + options.filter { format($0) != preferred }
    }

    // MARK: - Page setup

    /// Whether a paged export is laid out on the writer's own paper.
    ///
    /// On to begin with, which is what the app did before there was a switch:
    /// the PDF matched the sheets in page view. Off sends the export without a
    /// page setup at all, and the server lays it out on its standard US Letter
    /// page — which is what someone who reads on A4 but delivers on Letter
    /// wants, and had no way to ask for.
    ///
    /// Printing goes through the PDF export, so this answers for the printer
    /// too — including the PDF this device draws itself when there is no route
    /// to the server. That fallback exists to be the same document as the
    /// server's, and it stays the same document by following this as well.
    var usesPageSetup: Bool {
        didSet {
            guard usesPageSetup != oldValue else { return }
            defaults.set(usesPageSetup, forKey: Key.pageSetup)
        }
    }

    // MARK: - File names

    /// Whether the day's date goes on the end of an exported file's name.
    ///
    /// Off to begin with — a file called after the thing it holds is what most
    /// people want most of the time, and the share sheet is usually on its way
    /// to one message. It earns its keep for the writer sending drafts out
    /// week after week, whose Downloads folder is otherwise four files called
    /// the same thing with numbers in brackets after them.
    var namesFilesWithDate: Bool {
        didSet {
            guard namesFilesWithDate != oldValue else { return }
            defaults.set(namesFilesWithDate, forKey: Key.dateInName)
        }
    }

    /// What an exported file is called, before its extension.
    ///
    /// The date is written the sortable way round, and in a fixed format
    /// rather than the device's own: a localised date is a slash away from
    /// being a path separator in the middle of a filename, and a folder of
    /// drafts is only in order if every one of them is written the same way.
    func fileName(for baseName: String, on date: Date = Date()) -> String {
        guard namesFilesWithDate else { return baseName }
        let stamped = baseName + " " + Self.stamp(for: date)
        // Trimmed, so a document with no name of its own does not come out as
        // a filename that starts with a space.
        return stamped.trimmingCharacters(in: .whitespaces)
    }

    /// A date as an exported file would carry it. Public so the settings
    /// screen can show a real example of what turning this on does, rather
    /// than a day someone typed into a footer once and left there.
    static func stamp(for date: Date = Date()) -> String {
        dateStamp.string(from: date)
    }

    private static let dateStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Storage

    /// Ours alone — the web app has no export preferences to borrow keys from
    /// — but spelled its way, so they sit with the rest of them.
    private enum Key {
        static let format = "scripty-export-format"
        static let pageSetup = "scripty-export-page-setup"
        static let dateInName = "scripty-export-date-in-name"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // A format name nothing recognises — one dropped from a later build,
        // or a key someone edited — is no preference at all, and the menus as
        // advertised are the honest answer then.
        preferredFormat = ExportFormat(rawValue: defaults.string(forKey: Key.format) ?? "")

        // `object(forKey:)` rather than `bool(forKey:)`: an unset key has to
        // mean on here, or the first launch after this shipped would quietly
        // stop honouring a page setup the writer had already chosen.
        usesPageSetup = defaults.object(forKey: Key.pageSetup) as? Bool ?? true
        namesFilesWithDate = defaults.bool(forKey: Key.dateInName)
    }
}
