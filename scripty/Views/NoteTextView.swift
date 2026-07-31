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

/// The handle the formatting bar holds on the live text view, and the keeper
/// of the note's undo history.
///
/// The bar is a sibling of the editor, not a child, so it has no way to reach
/// the coordinator that owns the caret. This is that way — set once when the
/// view is made, cleared with it.
///
/// The history lives here rather than in the coordinator because it has to
/// outlast one: the sheet, the bar and the menu bar's ⌘Z all reach for it, and
/// SwiftUI may rebuild the representable underneath any of them.
@Observable
@MainActor
final class NoteEditorController {
    @ObservationIgnored fileprivate var perform: ((NoteTextView.Command) -> Void)?
    @ObservationIgnored fileprivate var beginEditing: (() -> Void)?
    /// Puts a remembered state back on screen. Set when the view is made,
    /// alongside the others.
    @ObservationIgnored fileprivate var restore: ((NoteHistory.Snapshot) -> Void)?

    /// The note's own undo stack — see `NoteHistory` for why it is the app's
    /// and not UIKit's. Tracked, so the bar's two buttons dim and undim as the
    /// note is typed without anything having to remember to tell them.
    private var history: NoteHistory

    /// `text` is what the editor is about to put on screen, and so the state
    /// undo stops at. Seeded here rather than when the text view is made,
    /// because that happens inside a SwiftUI update and this is state a view
    /// in that same update reads.
    init(text: String = "") {
        history = NoteHistory(text: text)
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func callAsFunction(_ command: NoteTextView.Command) {
        perform?(command)
    }

    /// Puts the caret in the note. The title field submits into this, so a new
    /// note is named and then written without reaching for the screen.
    func focus() {
        beginEditing?()
    }

    /// Undo and redo the note's own text. The keyboard offers ⌘Z through the
    /// menu, and a device without one has only the shake gesture — so the bar
    /// carries them too, as the browser's note toolbar does.
    func undo() {
        guard let snapshot = history.undo() else { return }
        restore?(snapshot)
    }

    func redo() {
        guard let snapshot = history.redo() else { return }
        restore?(snapshot)
    }

    // MARK: - What the editor tells the history

    /// This is the note now, and none of what came before it belongs to it —
    /// the full document landing on top of the list row's preview, or another
    /// note opening in the same sheet.
    func reset(to text: String) {
        history.reset(to: text)
    }

    /// Words that arrived in one go from somewhere other than the keyboard,
    /// worth one press of undo: an offline draft taken back up, which is the
    /// one edit in a note the writer may never have watched themselves make.
    func record(_ text: String) {
        history.capture(NoteHistory.Snapshot(text: text), at: Self.now,
                        coalescing: false)
    }

    /// Typing, and the formatting bar's rewrites — which are one gesture each
    /// and so never folded into the typing around them.
    fileprivate func capture(text: String, selection: NSRange,
                             coalescing: Bool = true) {
        history.capture(NoteHistory.Snapshot(text: text,
                                             start: selection.location,
                                             end: selection.location + selection.length),
                        at: Self.now, coalescing: coalescing)
    }

    /// The text view was written to from outside and nobody said what it meant.
    /// If the history already knows these words — the editor recorded them just
    /// before handing them over — there is nothing to do; otherwise a history
    /// describing a note nobody is looking at is worse than none.
    fileprivate func syncExternal(_ text: String) {
        guard history.current.text != text else { return }
        history.reset(to: text)
    }

    /// Monotonic, so a clock that changes under the app — a timezone crossed,
    /// an NTP correction — cannot make a burst of typing look like an hour of
    /// it, or the reverse.
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
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
    /// Which version of the ignored-words list this text was last checked
    /// against, so a word ignored from the menu below stops being underlined
    /// where it appears again.
    var spellcheckRevision = 0
    /// The writer's chosen type size, the same `scripty-text-size` preference
    /// the script and lyric surfaces honour. Passed in rather than read from
    /// an environment: the editor lives in a sheet the script view's
    /// environment does not reach.
    var textScale: Double = 1.0
    /// What an empty note says. Drawn inside the text view rather than laid
    /// over it from SwiftUI, which is the only way it lands on the first line
    /// exactly: the prompt has to share the editor's font, its metrics and its
    /// container insets, and a SwiftUI overlay can only approximate all three.
    var placeholder = ""
    /// Reports whether the caret is in here, so the host can show the
    /// formatting bar only while there is something for it to format.
    var onFocusChange: ((Bool) -> Void)?

    /// Sized by the preference, then scaled again by the system's Dynamic
    /// Type setting — prose notes have no Courier-fidelity excuse to ignore
    /// either.
    private var scaledFont: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 16 * textScale, weight: .regular))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> NoteUITextView {
        // Spelled out rather than `NoteUITextView()`: the subclass overrides the
        // designated initialiser, so the argument-less one is no longer
        // inherited.
        let view = NoteUITextView(frame: .zero, textContainer: nil)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = scaledFont
        view.adjustsFontForContentSizeCategory = true
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
        controller?.beginEditing = { [weak view] in
            view?.becomeFirstResponder()
        }
        controller?.restore = { [weak coordinator = context.coordinator] snapshot in
            coordinator?.restore(snapshot)
        }
        view.placeholder = placeholder
        return view
    }

    func updateUIView(_ view: NoteUITextView, context: Context) {
        context.coordinator.parent = self
        // Only when the value really diverged: assigning `text` moves the caret
        // to the end, which mid-sentence would be maddening.
        if view.text != text {
            view.text = text
            // Words from outside the keyboard. Whoever wrote them has usually
            // already told the history what they mean; this is the backstop
            // for whoever didn't.
            controller?.syncExternal(text)
        }
        if view.isEditable != isEditable { view.isEditable = isEditable }
        if view.placeholder != placeholder { view.placeholder = placeholder }

        // Only when the size preference really moved — reassigning the font
        // re-lays-out the whole text.
        let font = scaledFont
        if view.font?.pointSize != font.pointSize { view.font = font }

        view.applySpellchecking(spellChecks, revision: spellcheckRevision)
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

        /// Set while the coordinator is the one writing, so a state put back by
        /// undo is not mistaken for typing and pushed onto the stack it just
        /// came off.
        private var isWriting = false

        init(_ parent: NoteTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? NoteUITextView)?.updatePlaceholder()
            guard !isWriting else { return }
            // Every route to a note changed by hand passes through here —
            // typing, dictation, a paste, the shake gesture — so this one call
            // is what the note's history is built from.
            parent.controller?.capture(text: textView.text,
                                       selection: textView.selectedRange)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange?(false)
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

        /// "Ignore Spelling" beside the system's corrections, the same route the
        /// screenplay and lyric surfaces offer.
        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            SpellcheckEditMenu.menu(for: textView, in: range, appending: suggestedActions)
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

        /// Puts a rewritten note back into the text view, and files it as one
        /// press of undo: a bullet the bar added comes off in one, without
        /// taking the sentence it was added to with it.
        private func apply(_ edit: NoteEdit) {
            let location = utf16Offset(edit.caret, in: edit.text)
            let caret = NSRange(location: location, length: 0)
            write(edit.text, selection: caret)
            parent.controller?.capture(text: edit.text, selection: caret,
                                       coalescing: false)
        }

        /// Puts a remembered state back on screen. The history has already
        /// moved, so nothing is captured here.
        fileprivate func restore(_ snapshot: NoteHistory.Snapshot) {
            guard let textView, textView.isEditable else { return }
            // Where the browser calls `focus()` on the field it is about to
            // restore: undo that leaves the caret in the title field would put
            // the next keystroke somewhere the writer is not looking.
            if !textView.isFirstResponder { textView.becomeFirstResponder() }
            let length = (snapshot.text as NSString).length
            let start = max(0, min(snapshot.start, length))
            let end = max(start, min(snapshot.end, length))
            write(snapshot.text, selection: NSRange(location: start, length: end - start))
        }

        /// The one route by which this coordinator writes the note.
        ///
        /// Through `replace(_:withText:)` rather than by assigning `text`: an
        /// assignment is invisible to UIKit's own undo manager, so the shake
        /// gesture — the one route to undo this app does not own — would step
        /// back past everything the rules had done since, silently discarding
        /// it. The web editor avoids the same trap by going through
        /// `execCommand`.
        private func write(_ text: String, selection: NSRange) {
            guard let textView else { return }
            isWriting = true
            defer { isWriting = false }
            let old = textView.text ?? ""
            if let change = NoteFormatting.change(from: old, to: text),
               let range = textRange(of: change, in: textView, oldText: old) {
                textView.replace(range, withText: change.replacement)
            }
            // Belt and braces: `replace` reports back through the delegate, but
            // a text view that refused the range has still to leave the model
            // holding what was asked for.
            if textView.text != text { textView.text = text }
            textView.updatePlaceholder()
            parent.text = text
            textView.selectedRange = selection
        }

        /// A changed span, as the pair of positions the text view wants.
        private func textRange(of change: NoteChange,
                               in textView: UITextView,
                               oldText: String) -> UITextRange? {
            let start = utf16Offset(change.start, in: oldText)
            let end = utf16Offset(change.end, in: oldText)
            guard let from = textView.position(from: textView.beginningOfDocument, offset: start),
                  let to = textView.position(from: textView.beginningOfDocument, offset: end)
            else { return nil }
            return textView.textRange(from: from, to: to)
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
final class NoteUITextView: UITextView, SpellcheckingTextView {
    var checkedSpellingRevision = 0

    enum Key {
        case newline, tab, backTab
    }

    /// Returns true when the key was handled and should not reach the text.
    var onKey: ((Key) -> Bool)?
    var onCommand: ((NoteTextView.Command) -> Void)?

    // MARK: - Placeholder

    /// What an empty note says, drawn where its first character would go.
    private let placeholderLabel = UILabel()

    var placeholder: String {
        get { placeholderLabel.text ?? "" }
        set {
            placeholderLabel.text = newValue
            setNeedsLayout()
        }
    }

    override var text: String! {
        didSet { updatePlaceholder() }
    }

    override var font: UIFont? {
        didSet {
            placeholderLabel.font = font
            setNeedsLayout()
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.numberOfLines = 0
        placeholderLabel.textColor = .tertiaryLabel
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Positioned by frame rather than by constraints: the label lives inside a
    /// scroll view whose own layout is UIKit's business, and pinning to it with
    /// Auto Layout fights that. The maths is just "where the first glyph would
    /// be" — the container's insets plus its line padding.
    override func layoutSubviews() {
        super.layoutSubviews()
        let padding = textContainer.lineFragmentPadding
        let left = textContainerInset.left + padding
        let width = max(0, bounds.width - left - textContainerInset.right - padding)
        let height = placeholderLabel.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)).height
        placeholderLabel.frame = CGRect(x: left, y: textContainerInset.top,
                                        width: width, height: height)
    }

    /// Called by the coordinator on every keystroke, and by `text`'s observer
    /// when the value is written from outside — between them that covers every
    /// way a note stops or starts being empty.
    func updatePlaceholder() {
        placeholderLabel.isHidden = !(text ?? "").isEmpty
    }

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

/// Undo, redo, bullet, number and heading controls — the counterpart of the web
/// editor's note formatting row, and the only route to any of them on a device
/// with no hardware keyboard. (Undo has the shake gesture, which is a gesture
/// nobody discovers and half the writers who do have turned off.)
///
/// Carries its own bar chrome because of where it sits: pinned to the bottom of
/// the editor, riding above the keyboard, where it has to read as a strip of
/// tools rather than as the first line of the note.
struct NoteFormatBar: View {
    let controller: NoteEditorController

    private func perform(_ command: NoteTextView.Command) { controller(command) }

    var body: some View {
        HStack(spacing: 8) {
            // Leading, where the browser's note toolbar puts them, and where
            // the screenplay and lyric editors put their own pair.
            Button {
                controller.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .labelStyle(.iconOnly)
            .disabled(!controller.canUndo)
            .accessibilityLabel("Undo")

            Button {
                controller.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .buttonStyle(.bordered)
            .labelStyle(.iconOnly)
            .disabled(!controller.canRedo)
            .accessibilityLabel("Redo")

            Divider().frame(height: 18)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(.separator).frame(height: 0.5)
        }
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
