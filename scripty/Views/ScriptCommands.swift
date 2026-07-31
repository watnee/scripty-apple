//
//  ScriptCommands.swift
//  scripty
//
//  The menu bar, for the Mac build and for an iPad with a keyboard attached.
//
//  A menu command has to reach the script the writer is actually looking at,
//  and on Mac that may be one of several windows. So ScriptView publishes what
//  it can do as a focused value and the menus read it back — the same rule the
//  rest of the app follows, where an affordance only appears if it is really
//  available. When no script is frontmost every item here is simply disabled.
//

import SwiftUI

/// What the frontmost script can do, as the menu bar needs to see it.
///
/// Closures rather than a reference to the model: several of these open sheets
/// whose state belongs to the view, and the menu should not know that.
struct ScriptActions {
    var title: String = ""

    var undo: (() -> Void)?
    var redo: (() -> Void)?
    var canUndo = false
    var canRedo = false

    var addElement: (() -> Void)?
    var setType: ((BlockType) -> Void)?
    /// The element the writer is in, when one has focus. Drives the check mark
    /// in the Format menu and whether retyping is offered at all.
    var focusedType: BlockType?

    /// Character formatting for the focused element — the web Format menu's
    /// Bold / Italic / Underline and alignment, which the client otherwise
    /// offers only as tap-chips in the FormatBar. Nil when nothing editable is
    /// focused; the state flags drive the menu's check marks. These act on the
    /// focused block while the writer is typing in it, exactly as `setType`
    /// (⌘1–9) already does.
    var toggleBold: (() -> Void)?
    var toggleItalic: (() -> Void)?
    var toggleUnderline: (() -> Void)?
    var setAlign: ((TextAlign) -> Void)?
    var isBold = false
    var isItalic = false
    var isUnderline = false
    var alignment: TextAlign?

    /// The clipboard, at the level of whole elements rather than of the text
    /// inside one. Nil when nothing is focused, or when the pasteboard holds
    /// nothing worth pasting.
    var copyElement: (() -> Void)?
    var cutElement: (() -> Void)?
    var pasteElements: (() -> Void)?

    /// Open the comment thread on the focused element — the web's ⌘⌥M
    /// ("comments on the block you are editing"), deliberately reachable while
    /// typing rather than on the ⌘⇧ family, because commenting on the line you
    /// are writing is the main use case. Nil unless a block is focused;
    /// commenting needs only read access, so this is offered for any focused
    /// element (every block advertises `comments`), locked or not.
    var commentOnFocused: (() -> Void)?

    /// The View menu's per-project display toggles — Pins, Bookmarks, Element
    /// Labels and the editing lock, which the web binds to ⌘⇧N / ⌘⇧B / ⌘⇧U /
    /// ⌘⇧Q (`toolbar-shortcuts.js`) and the client otherwise offered only as
    /// toolbar toggles with no keyboard route. Nil when no script is focused;
    /// the flags drive the label ("Show"/"Hide", "Lock"/"Unlock"). Word count
    /// is device-wide, so the View menu reaches its own `settings` directly.
    var toggleShowPins: (() -> Void)?
    var toggleShowBookmarks: (() -> Void)?
    var toggleShowElementLabels: (() -> Void)?
    var toggleEditingLock: (() -> Void)?
    var showsPins = false
    var showsBookmarks = false
    var showsElementLabels = false
    var isEditingLocked = false

    var find: (() -> Void)?
    var ignoredWords: (() -> Void)?
    var outline: (() -> Void)?
    var titlePage: (() -> Void)?
    var stats: (() -> Void)?
    var pageSetup: (() -> Void)?
    /// Flips the script screen into (and out of) reading mode — the script
    /// without its editing chrome, in place, not a screen of its own. The flag
    /// drives the menu item's label.
    var readScript: (() -> Void)?
    var isReadingScript = false
    /// The voice, not a mode: reading aloud runs on whatever surface is up,
    /// transport bar and all. Pauses and resumes a reading already running.
    var readAloud: (() -> Void)?
    var versions: (() -> Void)?
    /// Open the editions browser — the web's ⌘⇧J "new version". Nil unless the
    /// script has more than one edition or the writer may create one; the
    /// client otherwise surfaced editions as a toolbar button alone.
    var editions: (() -> Void)?

    /// Songs & Notes, and the documents themselves.
    ///
    /// `songs` and `notes` open the screen on their own list — one each, matching
    /// the two toolbar buttons, so the menu bar can no more open the wrong list
    /// than the bar can. `recentSongs` and `recentNotes` are the few last edited
    /// of each kind, which `openDocument` opens directly, so a writer at a
    /// keyboard reaches either without the screen in between. The lists are
    /// snapshots rather than closures because the menu has to draw the titles,
    /// not only act on them. Empty when the server never advertised the
    /// project's documents, or when no script is frontmost.
    var songs: (() -> Void)?
    var notes: (() -> Void)?
    var recentSongs: [TextDocument] = []
    var recentNotes: [TextDocument] = []
    var openDocument: ((TextDocument) -> Void)?

    /// Insert a song's lyrics or a note's text below the focused element — the
    /// block menu's "Insert Song" and "Insert Note". Empty and nil unless an
    /// element is focused, the script is unlocked, and the server advertised an
    /// `insert` link on at least one document, which it does only for a writer
    /// who may edit.
    var insertableSongs: [TextDocument] = []
    var insertableNotes: [TextDocument] = []
    var insertDocument: ((TextDocument) -> Void)?

    /// Open the screenplay file picker — the web's ⌘⇧I Import. Nil unless the
    /// server advertises `importScript` (editors only); the client otherwise
    /// surfaced import as a toolbar button alone, with no menu or keyboard route.
    var importScript: (() -> Void)?

    var exporter: ScriptExportModel?
}

struct ScriptActionsKey: FocusedValueKey {
    typealias Value = ScriptActions
}

extension FocusedValues {
    var scriptActions: ScriptActions? {
        get { self[ScriptActionsKey.self] }
        set { self[ScriptActionsKey.self] = newValue }
    }
}

struct ScriptCommands: Commands {
    /// Presentation is a device preference, not a per-window one, so the View
    /// menu talks to the same shared settings the toolbar does.
    private let settings = PresentationSettings.shared

    /// Light or dark is app-wide rather than per window, so the menu talks to
    /// the shared store the same way.
    private let appearance = AppearanceSettings.shared

    /// Help belongs to no window either, and a `Commands` body cannot present
    /// a sheet — so the menu sets the flag and the root view opens it.
    private let help = HelpPresentation.shared

    @FocusedValue(\.scriptActions) private var actions

    var body: some Commands {
        // Replacing the stock New Item keeps ⌘N meaningful: in a screenplay
        // the thing you make is the next element, not a document.
        CommandGroup(replacing: .newItem) {
            Button("New Element") { actions?.addElement?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions?.addElement == nil)
        }

        CommandGroup(after: .newItem) {
            Divider()
            // ⌘⇧T matches the web (`toolbar-shortcuts.js`). The chord is free
            // here — a native app has no browser "reopen closed tab" on it — so
            // the client and web agree, as they do on the other File-menu chords.
            Button("Title Page…") { actions?.titlePage?() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(actions?.titlePage == nil)
            // ⌘⌥P, not ⌘⇧P: the toolbar's Page View toggle already claims that
            // chord, as the browser does, and two views binding one chord means
            // whichever loses the responder race silently does nothing.
            Button("Page Setup…") { actions?.pageSetup?() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(actions?.pageSetup == nil)
            Divider()
            songItems
        }

        CommandGroup(replacing: .importExport) {
            // ⌘⇧I matches the web (`toolbar-shortcuts.js`); free in the client
            // (⌘I alone is Italic). The action opens the same picker the toolbar
            // Import button does, so the menu reaches it in focus mode too.
            Button("Import Script…") { actions?.importScript?() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(actions?.importScript == nil)
            Divider()
            exportMenu
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { actions?.undo?() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!(actions?.canUndo ?? false))
            Button("Redo") { actions?.redo?() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(actions?.canRedo ?? false))
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            // Shifted, and named for what they act on, because ⌘C and ⌘V
            // belong to the words inside the element the writer is typing in.
            // Taking those would mean a copy did something different depending
            // on where the caret happened to be.
            Button("Copy Element") { actions?.copyElement?() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(actions?.copyElement == nil)
            Button("Cut Element") { actions?.cutElement?() }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(actions?.cutElement == nil)
            Button("Paste Elements Below") { actions?.pasteElements?() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(actions?.pasteElements == nil)
            insertDocumentItems
            Divider()
            // ⌘⌥M, not a ⌘⇧ chord: the web deliberately puts comments there so
            // it fires while the caret is still in the block ("comments on the
            // block you are editing"). Opens the thread on the focused element.
            Button("Comment on Element…") { actions?.commentOnFocused?() }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(actions?.commentOnFocused == nil)
        }

        CommandGroup(after: .undoRedo) {
            Divider()
            Button("Find in Script…") { actions?.find?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions?.find == nil)
        }

        CommandMenu("Format") {
            formatMenu
        }

        CommandGroup(after: .toolbar) {
            viewMenu
        }

        // The stock Help menu points at a help book this app does not ship, so
        // it is replaced rather than added to: an item that opens nothing is
        // worse company for these two than no item at all.
        CommandGroup(replacing: .help) {
            Button("Scripty Help") { help.screen = .help }
            Button("Keyboard Shortcuts") { help.screen = .shortcuts }
                .keyboardShortcut("/", modifiers: .command)
        }
    }

    /// The two lists, and the documents under them.
    ///
    /// One item each, matching the toolbar: an item named "Songs & Notes" could
    /// not say which list it opened, so it opened on whichever the project was
    /// last left on and a writer after the other one paid a segment tap.
    ///
    /// ⌘⇧S stays on the songs, which is where it has always landed and what
    /// Help has always said it does. It is free in the client — nothing here is
    /// a saveable document, so the stock Save chords never appear. Notes take no
    /// chord: ⌘⇧N is Show/Hide Pins, the rest of the ⌘⇧ row is spoken for, and a
    /// chord with no mnemonic left in it is worse than none. Notes are also the
    /// half that needs it least here, since a Mac has the width to draw both
    /// buttons in the bar at all times.
    ///
    /// The submenus are named for what they hold: "Songs" would claim to list
    /// every one of them, when each lists the few last edited and leaves the rest
    /// to the screen above them. Notes get their own rather than sharing one
    /// list with the songs, so a project deep in either kind still shows both.
    /// Neither takes a chord either — they are a list to pick from rather than
    /// one action a key could stand for.
    @ViewBuilder
    private var songItems: some View {
        Button("Songs…") { actions?.songs?() }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(actions?.songs == nil)

        Button("Notes…") { actions?.notes?() }
            .disabled(actions?.notes == nil)

        documentMenu("Recent Songs", actions?.recentSongs ?? [], actions?.openDocument)
        documentMenu("Recent Notes", actions?.recentNotes ?? [], actions?.openDocument)
    }

    /// One kind of document, listed by title under a heading, each row doing
    /// the one thing the menu is for — opening it, or inserting it. Greyed out
    /// rather than dropped when the project has none of that kind, so the items
    /// keep their places in the menu between projects.
    @ViewBuilder
    private func documentMenu(_ title: String, _ documents: [TextDocument],
                              _ action: ((TextDocument) -> Void)?) -> some View {
        Menu(title) {
            ForEach(documents) { document in
                Button(document.displayTitle) { action?(document) }
            }
        }
        .disabled(documents.isEmpty || action == nil)
    }

    /// The block menu's "Insert Song" and "Insert Note", where the keyboard can
    /// reach them.
    ///
    /// They act on the focused element, so they are unavailable with nothing
    /// focused — which is also the only way they could know where to put the
    /// text. A submenu with nothing in it is left to the platform to grey out or
    /// drop, as it does the element clipboard items these sit with.
    @ViewBuilder
    private var insertDocumentItems: some View {
        documentMenu("Insert Song Below", actions?.insertableSongs ?? [], actions?.insertDocument)
        documentMenu("Insert Note Below", actions?.insertableNotes ?? [], actions?.insertDocument)
    }

    @ViewBuilder
    private var exportMenu: some View {
        let exporter = actions?.exporter
        Menu("Export") {
            ForEach(exporter?.options ?? []) { option in
                Button(option.label) { exporter?.export(option) }
            }
        }
        .disabled((exporter?.options ?? []).isEmpty || exporter?.isExporting == true)

        Button("Print…") {
            if let printable = exporter?.printableOption {
                exporter?.print(printable)
            }
        }
        .keyboardShortcut("p", modifiers: .command)
        .disabled(exporter?.printableOption == nil || exporter?.isExporting == true)
    }

    @ViewBuilder
    private var formatMenu: some View {
        styleItems
        Divider()
        alignItems
        Divider()
        elementTypeItems
    }

    /// Bold / Italic / Underline on the focused element. ⌘B / ⌘I / ⌘U are the
    /// universal chords and none is claimed elsewhere here or by the block text
    /// view, so they reach the menu even while typing — the same route ⌘1–9 use.
    @ViewBuilder
    private var styleItems: some View {
        Button { actions?.toggleBold?() } label: {
            checked("Bold", on: actions?.isBold ?? false)
        }
        .keyboardShortcut("b", modifiers: .command)
        .disabled(actions?.toggleBold == nil)

        Button { actions?.toggleItalic?() } label: {
            checked("Italic", on: actions?.isItalic ?? false)
        }
        .keyboardShortcut("i", modifiers: .command)
        .disabled(actions?.toggleItalic == nil)

        Button { actions?.toggleUnderline?() } label: {
            checked("Underline", on: actions?.isUnderline ?? false)
        }
        .keyboardShortcut("u", modifiers: .command)
        .disabled(actions?.toggleUnderline == nil)
    }

    @ViewBuilder
    private var alignItems: some View {
        // ⌘⇧L / ⌘⇧E follow the word-processor convention and are both free. The
        // web's align-right chord is ⌘⇧R, which is already this client's "Read
        // Script", so the right item carries no shortcut rather than colliding —
        // whichever view lost that responder race would silently do nothing.
        alignButton(.left, key: "l")
        alignButton(.center, key: "e")
        alignButton(.right, key: nil)
    }

    @ViewBuilder
    private func alignButton(_ align: TextAlign, key: KeyEquivalent?) -> some View {
        if let key {
            alignPlain(align).keyboardShortcut(key, modifiers: [.command, .shift])
        } else {
            alignPlain(align)
        }
    }

    private func alignPlain(_ align: TextAlign) -> some View {
        Button { actions?.setAlign?(align) } label: {
            checked("Align \(align.label)", on: actions?.alignment == align)
        }
        .disabled(actions?.setAlign == nil)
    }

    @ViewBuilder
    private var elementTypeItems: some View {
        ForEach(Array(BlockType.allCases.enumerated()), id: \.element.id) { index, type in
            ElementTypeCommand(
                type: type,
                index: index,
                isCurrent: actions?.focusedType == type,
                setType: actions?.setType)
        }
    }

    /// A menu label that carries a check mark when the state is on, matching
    /// `ElementTypeCommand` — a Toggle would imply switching a thing off, but a
    /// formatting chord just re-applies, so the mark is an indicator only.
    @ViewBuilder
    private func checked(_ title: String, on: Bool) -> some View {
        if on {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private var viewMenu: some View {
        Divider()
        Button(settings.isPageView ? "Show as List" : "Show as Pages") {
            settings.isPageView.toggle()
        }
        .keyboardShortcut("1", modifiers: [.command, .option])

        Button(settings.isFocusMode ? "Exit Focus Mode" : "Focus Mode") {
            settings.isFocusMode.toggle()
        }
        .keyboardShortcut("d", modifiers: [.command, .control])

        Button(settings.isFullWidth ? "Standard Screenplay Width" : "Full Page Width") {
            settings.isFullWidth.toggle()
        }
        .keyboardShortcut("\\", modifiers: .command)
        .disabled(settings.isPageView)

        // ⌘⇧O is the browser's outline *mode*, so it stays with the mode here
        // too; the outline panel — which is ours, and has no counterpart on the
        // web — moves along one modifier.
        Button(settings.isOutlineMode ? "Show Whole Script" : "Outline Mode") {
            settings.isOutlineMode.toggle()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])

        Button("Outline") { actions?.outline?() }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(actions?.outline == nil)

        // A mode toggle like the ones above it, so the item names the way out
        // while the mode is on.
        Button(actions?.isReadingScript == true ? "Exit Read Mode" : "Read Script") {
            actions?.readScript?()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(actions?.readScript == nil)

        // The voice, in place on the script screen. ⌘⇧A rather than anything
        // nearer ⌘⇧R: R is taken by the reader itself, and every other letter
        // in "aloud" is spoken for.
        Button("Read Aloud") { actions?.readAloud?() }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(actions?.readAloud == nil)

        Button("Script Stats") { actions?.stats?() }
            .disabled(actions?.stats == nil)

        Button(settings.showsWordCount ? "Hide Word Count" : "Show Word Count") {
            settings.showsWordCount.toggle()
        }
        .keyboardShortcut("y", modifiers: [.command, .shift])

        // The per-project marks the toolbar's "Show" section carries, given the
        // same keyboard route the web binds. These come through the focused
        // script (nil when none is open) because the marks are per project,
        // where word count above is a device preference. Notes has no chord on
        // the web, so it stays a toolbar-only toggle.
        if let toggle = actions?.toggleShowPins {
            Button((actions?.showsPins ?? false) ? "Hide Pins" : "Show Pins") { toggle() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        if let toggle = actions?.toggleShowBookmarks {
            Button((actions?.showsBookmarks ?? false) ? "Hide Bookmarks" : "Show Bookmarks") {
                toggle()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
        }
        if let toggle = actions?.toggleShowElementLabels {
            Button((actions?.showsElementLabels ?? false)
                    ? "Hide Element Labels" : "Show Element Labels") { toggle() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
        }

        Button(settings.isSpellcheckEnabled ? "Stop Checking Spelling" : "Check Spelling") {
            settings.isSpellcheckEnabled.toggle()
        }
        .keyboardShortcut(";", modifiers: [.command, .shift])

        Button("Ignored Words…") { actions?.ignoredWords?() }
            .disabled(actions?.ignoredWords == nil)

        // Lock keeps company with spellcheck as in the toolbar: both are about
        // typing, and both are offered only where there is something to type in
        // (`toggleEditingLock` is nil for a reader).
        if let toggle = actions?.toggleEditingLock {
            Button((actions?.isEditingLocked ?? false) ? "Unlock Editing" : "Lock Editing") {
                toggle()
            }
            .keyboardShortcut("q", modifiers: [.command, .shift])
        }

        // ⌘⇧H matches the web's "Snapshot history" chord; free in the client.
        Button("Version History") { actions?.versions?() }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(actions?.versions == nil)

        // ⌘⇧J matches the web's edition/version chord; free in the client. Sits
        // by Version History — both open other versions of the same script.
        Button("Editions…") { actions?.editions?() }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(actions?.editions == nil)

        Divider()
        Button("Bigger Text") { settings.increaseTextSize() }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!settings.canIncreaseTextSize)
        Button("Smaller Text") { settings.decreaseTextSize() }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!settings.canDecreaseTextSize)
        Button("Actual Size") { settings.resetTextSize() }
            .keyboardShortcut("0", modifiers: .command)

        Divider()
        Picker("Appearance", selection: appearanceBinding) {
            ForEach(AppearanceSettings.Appearance.allCases) { choice in
                Text(choice.label).tag(choice)
            }
        }
    }

    private var appearanceBinding: Binding<AppearanceSettings.Appearance> {
        Binding(get: { appearance.appearance }, set: { appearance.appearance = $0 })
    }
}

/// One element type in the Format menu.
///
/// Split out because the first nine carry a ⌘-number shortcut and the rest
/// carry none — a difference the menu builder can't express inline.
private struct ElementTypeCommand: View {
    let type: BlockType
    let index: Int
    let isCurrent: Bool
    let setType: ((BlockType) -> Void)?

    var body: some View {
        if index < 9 {
            button.keyboardShortcut(
                KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            setType?(type)
        } label: {
            // A check mark rather than a Toggle: retyping the element you are
            // already in is a no-op, not something to switch off.
            if isCurrent {
                Label(type.label, systemImage: "checkmark")
            } else {
                Text(type.label)
            }
        }
        .disabled(setType == nil)
    }
}
