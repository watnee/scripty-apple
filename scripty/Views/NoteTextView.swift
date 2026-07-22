//
//  NoteTextView.swift
//  scripty
//
//  The writing surface for a note or a song's lyrics.
//
//  A UITextView rather than SwiftUI's TextEditor, for the same reason the
//  script editor uses one: the rules in `NoteFormatting` need to see Return and
//  Tab before the text does, and they need to put the caret somewhere
//  particular afterwards. TextEditor offers neither.
//

import SwiftUI
import UIKit

/// The handle the formatting bar holds on the live text view.
///
/// The bar is a sibling of the editor, not a child, so it has no way to reach
/// the coordinator that owns the caret. This is that way — set once when the
/// view is made, cleared with it.
@MainActor
final class NoteEditorController {
    fileprivate var perform: ((NoteTextView.Command) -> Void)?

    func callAsFunction(_ command: NoteTextView.Command) {
        perform?(command)
    }
}

struct NoteTextView: UIViewRepresentable {
    @Binding var text: String
    /// Nil where the bar is not offered — a song's lyrics, which take the
    /// keyboard rules but not the list controls, exactly as in the browser.
    var controller: NoteEditorController?
    var isEditable = true
    /// Whether misspellings are underlined, following the same device-wide
    /// preference the script editor honours.
    var spellChecks = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> NoteUITextView {
        let view = NoteUITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        view.autocapitalizationType = .sentences
        view.text = text
        view.onKey = { [weak coordinator = context.coordinator] key in
            coordinator?.handle(key) ?? false
        }
        view.onCommand = { [weak coordinator = context.coordinator] command in
            coordinator?.perform(command)
        }
        context.coordinator.textView = view
        controller?.perform = { [weak coordinator = context.coordinator] command in
            coordinator?.perform(command)
        }
        return view
    }

    func updateUIView(_ view: NoteUITextView, context: Context) {
        context.coordinator.parent = self
        // Only when the value really diverged: assigning `text` moves the caret
        // to the end, which mid-sentence would be maddening.
        if view.text != text { view.text = text }
        if view.isEditable != isEditable { view.isEditable = isEditable }

        let checking: UITextSpellCheckingType = spellChecks ? .yes : .no
        if view.spellCheckingType != checking {
            view.spellCheckingType = checking
            if view.isFirstResponder { view.reloadInputViews() }
        }
    }

    /// The formatting the toolbar and the keyboard shortcuts can ask for.
    enum Command {
        case bulletList, numberedList
        case heading(Int)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NoteTextView
        weak var textView: NoteUITextView?

        init(_ parent: NoteTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        /// Return and Tab, before the text view sees them.
        func handle(_ key: NoteUITextView.Key) -> Bool {
            guard let textView, textView.isEditable else { return false }
            let caret = characterOffset(textView.selectedRange.location, in: textView)
            // A selection is a replacement, not a formatting gesture — leave it
            // to the text view, which already knows what to do with one.
            guard textView.selectedRange.length == 0 else { return false }

            let edit: NoteEdit?
            switch key {
            case .newline: edit = NoteFormatting.newline(in: textView.text, caret: caret)
            case .tab: edit = NoteFormatting.indent(in: textView.text, caret: caret, outdent: false)
            case .backTab: edit = NoteFormatting.indent(in: textView.text, caret: caret, outdent: true)
            }
            guard let edit else { return false }
            apply(edit)
            return true
        }

        func perform(_ command: Command) {
            guard let textView, textView.isEditable else { return }
            let caret = characterOffset(textView.selectedRange.location, in: textView)
            switch command {
            case .bulletList:
                apply(NoteFormatting.toggleList(in: textView.text, caret: caret, ordered: false))
            case .numberedList:
                apply(NoteFormatting.toggleList(in: textView.text, caret: caret, ordered: true))
            case .heading(let level):
                apply(NoteFormatting.toggleHeading(in: textView.text, caret: caret, level: level))
            }
        }

        private func apply(_ edit: NoteEdit) {
            guard let textView else { return }
            textView.text = edit.text
            parent.text = edit.text
            let location = utf16Offset(edit.caret, in: edit.text)
            textView.selectedRange = NSRange(location: location, length: 0)
        }

        /// UITextView counts in UTF-16 and the formatting rules count in
        /// Characters, so every caret crosses this boundary twice.
        private func characterOffset(_ utf16Location: Int, in textView: UITextView) -> Int {
            let ns = textView.text as NSString? ?? ""
            return ns.substring(to: max(0, min(utf16Location, ns.length))).count
        }

        private func utf16Offset(_ characterOffset: Int, in text: String) -> Int {
            let bounded = max(0, min(characterOffset, text.count))
            let index = text.index(text.startIndex, offsetBy: bounded)
            return text.utf16.distance(from: text.utf16.startIndex,
                                       to: index.samePosition(in: text.utf16) ?? text.utf16.endIndex)
        }
    }
}

/// A UITextView that hands Return, Tab and Shift-Tab to its owner first.
///
/// Return and Tab arrive as ordinary text and so could be caught in the
/// delegate, but Shift-Tab has no text at all and needs a key command — so all
/// three are routed the same way rather than split across two mechanisms.
final class NoteUITextView: UITextView {
    enum Key {
        case newline, tab, backTab
    }

    /// Returns true when the key was handled and should not reach the text.
    var onKey: ((Key) -> Bool)?
    var onCommand: ((NoteTextView.Command) -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        // ⌘⌥1/2/3 for the three heading levels, the same keys the browser uses.
        var commands = [
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(handleBackTab))
        ]
        for level in 1...3 {
            let command = UIKeyCommand(input: "\(level)",
                                       modifierFlags: [.command, .alternate],
                                       action: #selector(handleHeading))
            command.title = "Heading \(level)"
            commands.append(command)
        }
        return commands
    }

    @objc private func handleBackTab() {
        _ = onKey?(.backTab)
    }

    @objc private func handleHeading(_ sender: UIKeyCommand) {
        guard let level = Int(sender.input ?? ""), (1...3).contains(level) else { return }
        onCommand?(.heading(level))
    }

    override func insertText(_ text: String) {
        switch text {
        case "\n" where onKey?(.newline) == true: return
        case "\t" where onKey?(.tab) == true: return
        default: super.insertText(text)
        }
    }
}

/// Bullet, number and heading controls — the counterpart of the web editor's
/// note formatting row, and the only route to these on a device with no
/// hardware keyboard.
struct NoteFormatBar: View {
    let controller: NoteEditorController

    private func perform(_ command: NoteTextView.Command) { controller(command) }

    var body: some View {
        HStack(spacing: 8) {
            button("List", systemImage: "list.bullet", .bulletList)
            button("Numbered List", systemImage: "list.number", .numberedList)
            Divider().frame(height: 18)
            ForEach(1...3, id: \.self) { level in
                Button("H\(level)") { perform(.heading(level)) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Heading \(level)")
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
    }

    private func button(_ label: String,
                        systemImage: String,
                        _ command: NoteTextView.Command) -> some View {
        Button {
            perform(command)
        } label: {
            Label(label, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
        .accessibilityLabel(label)
    }
}
