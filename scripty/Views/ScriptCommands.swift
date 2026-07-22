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

    /// The clipboard, at the level of whole elements rather than of the text
    /// inside one. Nil when nothing is focused, or when the pasteboard holds
    /// nothing worth pasting.
    var copyElement: (() -> Void)?
    var cutElement: (() -> Void)?
    var pasteElements: (() -> Void)?

    var find: (() -> Void)?
    var ignoredWords: (() -> Void)?
    var outline: (() -> Void)?
    var titlePage: (() -> Void)?
    var stats: (() -> Void)?
    var pageSetup: (() -> Void)?
    var readScript: (() -> Void)?
    var versions: (() -> Void)?

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
            Button("Title Page…") { actions?.titlePage?() }
                .disabled(actions?.titlePage == nil)
            // ⌘⌥P, not ⌘⇧P: the toolbar's Page View toggle already claims that
            // chord, as the browser does, and two views binding one chord means
            // whichever loses the responder race silently does nothing.
            Button("Page Setup…") { actions?.pageSetup?() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(actions?.pageSetup == nil)
        }

        CommandGroup(replacing: .importExport) {
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
        ForEach(Array(BlockType.allCases.enumerated()), id: \.element.id) { index, type in
            ElementTypeCommand(
                type: type,
                index: index,
                isCurrent: actions?.focusedType == type,
                setType: actions?.setType)
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

        Button("Read Script") { actions?.readScript?() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(actions?.readScript == nil)

        Button("Script Stats") { actions?.stats?() }
            .disabled(actions?.stats == nil)

        Button(settings.showsWordCount ? "Hide Word Count" : "Show Word Count") {
            settings.showsWordCount.toggle()
        }

        Button(settings.isSpellcheckEnabled ? "Stop Checking Spelling" : "Check Spelling") {
            settings.isSpellcheckEnabled.toggle()
        }
        .keyboardShortcut(";", modifiers: [.command, .shift])

        Button("Ignored Words…") { actions?.ignoredWords?() }
            .disabled(actions?.ignoredWords == nil)

        Button("Version History") { actions?.versions?() }
            .disabled(actions?.versions == nil)

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
