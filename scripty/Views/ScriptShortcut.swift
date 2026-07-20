//
//  ScriptShortcut.swift
//  scripty
//
//  The keyboard shortcuts the script page answers to, as data.
//
//  The web app keeps its canonical list in `fragments/shortcuts.html` and its
//  bindings in `shortcuts.js`, and the two drift — a shortcut gets rebound and
//  the help card still shows the old key. Here one catalog drives both: the
//  hidden button layer that binds the keys and the reference sheet that lists
//  them are built from the same array, so a shortcut cannot be documented
//  without being bound or bound without being documented.
//
//  Actions carry their operand (`.setType(.scene)`, `.export(.exportPdf)`)
//  rather than being spelled out one case per element, so adding an element
//  type to `BlockType` is a one-line addition here.
//

import SwiftUI

/// Something the script page can be asked to do from the keyboard.
enum ScriptShortcutAction: Hashable, Identifiable {
    // Edit
    case undo, redo

    // Search & navigation
    case search, findReplace, nextMatch, previousMatch
    case focusMode, pageView, readScript, wordCount, elementLabels
    case outline(ScriptOutlineView.Tab)
    case documents(DocumentType)
    case shortcutsReference

    // File & versions
    case titlePage, versionHistory, importFile, printScript
    case export(Rel)

    // Text size
    case biggerText, smallerText

    // Format
    case bold, italic, underline
    case align(TextAlign)

    // Elements
    case setType(BlockType)
    case moveUp, moveDown

    var id: String {
        switch self {
        case .undo: return "undo"
        case .redo: return "redo"
        case .search: return "search"
        case .findReplace: return "findReplace"
        case .nextMatch: return "nextMatch"
        case .previousMatch: return "previousMatch"
        case .focusMode: return "focusMode"
        case .pageView: return "pageView"
        case .readScript: return "readScript"
        case .wordCount: return "wordCount"
        case .elementLabels: return "elementLabels"
        case .outline(let tab): return "outline.\(tab.rawValue)"
        case .documents(let kind): return "documents.\(kind.rawValue)"
        case .shortcutsReference: return "shortcutsReference"
        case .titlePage: return "titlePage"
        case .versionHistory: return "versionHistory"
        case .importFile: return "importFile"
        case .printScript: return "printScript"
        case .export(let rel): return "export.\(rel.rawValue)"
        case .biggerText: return "biggerText"
        case .smallerText: return "smallerText"
        case .bold: return "bold"
        case .italic: return "italic"
        case .underline: return "underline"
        case .align(let align): return "align.\(align.rawValue)"
        case .setType(let type): return "setType.\(type.rawValue)"
        case .moveUp: return "moveUp"
        case .moveDown: return "moveDown"
        }
    }

    var title: String {
        switch self {
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .search: return "Search Script"
        case .findReplace: return "Find & Replace"
        case .nextMatch: return "Next Match"
        case .previousMatch: return "Previous Match"
        case .focusMode: return "Focus Mode"
        case .pageView: return "Page View"
        case .readScript: return "Read Script"
        case .wordCount: return "Word Count"
        case .elementLabels: return "Element Labels"
        case .outline(let tab): return tab.shortcutTitle
        case .documents(let kind): return kind == .song ? "Songs" : "Notes"
        case .shortcutsReference: return "Keyboard Shortcuts"
        case .titlePage: return "Title Page"
        case .versionHistory: return "Version History"
        case .importFile: return "Import File"
        case .printScript: return "Print"
        case .export(let rel): return "Export \(Self.exportLabel(rel))"
        case .biggerText: return "Bigger Text"
        case .smallerText: return "Smaller Text"
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .underline: return "Underline"
        case .align(let align): return "Align \(align.label)"
        case .setType(let type): return type.label
        case .moveUp: return "Move Element Up"
        case .moveDown: return "Move Element Down"
        }
    }

    private static func exportLabel(_ rel: Rel) -> String {
        switch rel {
        case .exportPdf: return "PDF"
        case .exportDocx: return "Word"
        case .exportFdx: return "Final Draft"
        case .exportEpub: return "EPUB"
        case .exportArchive: return "Project Archive"
        default: return "Fountain"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .undo, .redo: return "z"
        case .search, .findReplace: return "f"
        case .nextMatch, .previousMatch: return "g"
        case .focusMode: return "f"
        case .pageView: return "p"
        case .readScript: return "x"
        case .wordCount: return "y"
        case .elementLabels: return "u"
        case .outline(let tab): return tab.shortcutKey
        case .documents(let kind): return kind == .song ? "s" : "d"
        case .shortcutsReference: return "/"
        case .titlePage: return "t"
        case .versionHistory: return "h"
        case .importFile: return "i"
        case .printScript: return "p"
        // Every advertised format needs its own digit. A `default` here would
        // hand two exports the same binding, which in SwiftUI silently breaks
        // both — and the reference sheet would list a key twice.
        case .export(let rel):
            switch rel {
            case .exportPdf: return "1"
            case .exportDocx: return "2"
            case .exportFdx: return "3"
            case .exportEpub: return "5"
            case .exportArchive: return "6"
            default: return "4"   // Fountain
            }
        // "=" rather than "+", which is the same physical key: a KeyEquivalent
        // that needs Shift to type, declared without `.shift`, never matches —
        // neither ⌘= nor ⌘⇧= fired it. ⌘= is also what every other Mac app
        // actually binds, whatever its menu prints.
        case .biggerText: return "="
        case .smallerText: return "-"
        case .bold: return "b"
        case .italic: return "i"
        case .underline: return "u"
        case .align(let align):
            switch align {
            case .left: return "l"
            case .center: return "e"
            case .right: return "r"
            }
        case .setType(let type): return type.shortcutKey
        case .moveUp: return .upArrow
        case .moveDown: return .downArrow
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .undo, .search, .bold, .italic, .underline,
             .biggerText, .smallerText, .nextMatch, .printScript:
            return .command
        case .findReplace:
            return [.command, .option]
        // ⇧⌘/ is ⌘? on a US layout — the web app's `?`, and the macOS
        // convention for Help. Plain ⌘/ does not register as a SwiftUI
        // KeyEquivalent, which is the other reason it is spelled this way.
        case .redo, .previousMatch, .focusMode, .pageView, .readScript,
             .wordCount, .elementLabels,
             .outline, .documents, .titlePage, .versionHistory,
             .importFile, .export, .align, .shortcutsReference:
            return [.command, .shift]
        case .setType:
            return [.command, .option]
        case .moveUp, .moveDown:
            return .option
        }
    }

    /// True when the binding lives in `BlockUITextView.keyCommands` rather
    /// than in the shortcut layer.
    ///
    /// Reordering acts on the element holding the caret, so a text view is
    /// always first responder — and UITextView claims every modifier+arrow
    /// combination for its own navigation and selection before a SwiftUI
    /// `.keyboardShortcut` is ever consulted. (⌥↑ moved the caret to the top
    /// of the paragraph; the web app's alternative ⌃⇧↑ extended the selection.)
    /// A `UIKeyCommand` on the text view itself is the only level that wins,
    /// which is where Shift-Tab already had to go for the same reason.
    ///
    /// Still listed in the catalog, because it is still a shortcut the writer
    /// can press — this flag only tells the layer not to bind a second, dead
    /// copy of it.
    var isBoundInTextView: Bool {
        switch self {
        case .moveUp, .moveDown: return true
        default: return false
        }
    }

    var group: Group {
        switch self {
        case .undo, .redo: return .edit
        case .search, .findReplace, .nextMatch, .previousMatch,
             .focusMode, .pageView, .readScript, .wordCount, .elementLabels,
             .outline, .documents, .shortcutsReference:
            return .navigation
        case .titlePage, .versionHistory, .importFile, .printScript, .export:
            return .file
        case .biggerText, .smallerText: return .textSize
        case .bold, .italic, .underline, .align: return .format
        case .setType: return .elements
        case .moveUp, .moveDown: return .reordering
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case edit, navigation, format, elements, reordering, textSize, file

        var id: String { rawValue }

        var title: String {
            switch self {
            case .edit: return "Edit & Undo"
            case .navigation: return "Search & Navigation"
            case .format: return "Format"
            case .elements: return "Elements"
            case .reordering: return "Element Reordering"
            case .textSize: return "Text Size"
            case .file: return "File & Versions"
            }
        }

        var systemImage: String {
            switch self {
            case .edit: return "arrow.uturn.backward"
            case .navigation: return "magnifyingglass"
            case .format: return "bold.italic.underline"
            case .elements: return "film"
            case .reordering: return "arrow.up.arrow.down"
            case .textSize: return "textformat.size"
            case .file: return "folder"
            }
        }

        /// The note under the card, where the web app puts its context line.
        var footnote: String? {
            switch self {
            case .edit:
                return "While typing, these step through your text. Otherwise "
                     + "they move through the project's history."
            case .format, .elements:
                return "Apply to the element holding the caret, and work while typing."
            case .reordering:
                return "Move the element holding the caret. Also available from "
                     + "the element menu."
            default:
                return nil
            }
        }
    }

    /// Everything the script page binds, in the order the reference sheet
    /// reads best — grouped, and within a group in the web app's own order.
    static let all: [ScriptShortcutAction] = [
        .undo, .redo,

        .search, .findReplace, .nextMatch, .previousMatch,
        .focusMode, .pageView, .readScript, .wordCount, .elementLabels,
        .outline(.outline), .outline(.characters), .outline(.locations),
        .outline(.songs), .outline(.bookmarks), .outline(.pins),
        .documents(.song), .documents(.notes),
        .shortcutsReference,

        .bold, .italic, .underline,
        .align(.left), .align(.center), .align(.right),

        .setType(.scene), .setType(.action), .setType(.character),
        .setType(.parenthetical), .setType(.dialogue), .setType(.transition),
        .setType(.shot), .setType(.text), .setType(.dualDialogue),
        .setType(.lyrics), .setType(.centered), .setType(.section),
        .setType(.synopsis), .setType(.note), .setType(.pageBreak),

        .moveUp, .moveDown,

        .biggerText, .smallerText,

        .titlePage, .versionHistory, .importFile, .printScript,
        .export(.exportPdf), .export(.exportDocx),
        .export(.exportFdx), .export(.export),
        .export(.exportEpub), .export(.exportArchive),
    ]

    static func inGroup(_ group: Group) -> [ScriptShortcutAction] {
        all.filter { $0.group == group }
    }

    /// How the binding reads on a key cap — "⌘⌥1".
    var displayKeys: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        default: text += String(key.character).uppercased()
        }
        return text
    }
}

// MARK: - Per-type key assignments

extension BlockType {
    /// The element's ⌘⌥ key, matching the web app's Elements card. Scene
    /// through Shot take the digits in screenplay-frequency order; the rest
    /// take a mnemonic letter.
    var shortcutKey: KeyEquivalent {
        switch self {
        case .scene: return "1"
        case .action: return "2"
        case .character: return "3"
        case .parenthetical: return "4"
        case .dialogue: return "5"
        case .transition: return "6"
        case .shot: return "7"
        case .text: return "t"
        case .dualDialogue: return "u"
        case .lyrics: return "y"
        case .centered: return "m"
        case .section: return "x"
        case .synopsis: return "o"
        case .note: return "n"
        case .pageBreak: return "b"
        }
    }
}

extension ScriptOutlineView.Tab {
    /// Each outline list gets the key the web app gives its sidebar.
    var shortcutKey: KeyEquivalent {
        switch self {
        case .outline: return "o"
        case .characters: return "c"
        case .locations: return "a"
        case .songs: return "m"
        case .bookmarks: return "b"
        case .pins: return "n"
        }
    }

    /// Named for what the shortcut opens rather than for the tab itself, so
    /// the reference sheet reads as a list of destinations.
    var shortcutTitle: String {
        switch self {
        case .outline: return "Outline"
        case .characters: return "Character List"
        case .locations: return "Location List"
        case .songs: return "Song List"
        case .bookmarks: return "Bookmarks"
        case .pins: return "Pins"
        }
    }
}
