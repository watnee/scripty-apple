//
//  HideKeyboardButton.swift
//  scripty
//
//  Puts the keyboard away without leaving the line being written.
//
//  On a phone the keyboard covers half of what a writer is working on, and
//  until now the only ways down were scrolling the script — which moves the
//  very thing they were reading — or closing the editor altogether. Every
//  writing surface here now carries this chip at the trailing edge of the bar
//  riding above the keyboard, which is where iPadOS puts the same key on the
//  keyboard itself, and it uses that key's glyph so it needs no label.
//
//  Dismissal goes through UIKit rather than through each surface's own focus
//  state. All three text views — screenplay element, lyric line, note — grant
//  themselves first responder and leave *losing* it to UIKit, following along
//  in `textViewDidEndEditing`; resigning is therefore the one move every
//  surface already understands, and the focus the bars are drawn from clears
//  itself as a consequence rather than having to be cleared in step.
//

import Observation
import SwiftUI
import UIKit

/// Whether the keyboard is on screen — watched, rather than worked out from
/// whatever the surface thinks has focus.
///
/// For the one surface that cannot answer the question itself: the note sheet's
/// title is a SwiftUI `TextField`, and its `@FocusState` stays false when the
/// writer taps into it, because the UIKit editor below it has been in and out
/// of first responder and SwiftUI's focus engine no longer agrees with UIKit
/// about who holds it. The keyboard's own notifications are not in any doubt.
@Observable
@MainActor
final class SoftwareKeyboard {
    static let shared = SoftwareKeyboard()

    private(set) var isVisible = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillShowNotification,
                           object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SoftwareKeyboard.shared.isVisible = true }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification,
                           object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SoftwareKeyboard.shared.isVisible = false }
        }
    }
}

struct HideKeyboardButton: View {
    /// How the chip is dressed, so it reads as one of whatever bar it joins.
    enum Style {
        /// The capsule chip of the screenplay's element bar.
        case chip
        /// The bordered button of the note formatting bar.
        case bordered
    }

    var style: Style = .chip

    /// The host's chance to let go of the focus it is tracking, run in the same
    /// turn as the resign below.
    ///
    /// Not optional politeness: the screenplay grants first responder from
    /// `focusedBlockId` on every update and clears that only after an async
    /// commit, so a row left holding it wins the race and takes the keyboard
    /// straight back — the chip appeared to do nothing at all. A surface whose
    /// focus follows UIKit rather than driving it can leave this nil.
    var releaseFocus: (() -> Void)?

    /// Whether this device has a keyboard worth hiding. A Mac has only the
    /// hardware one, so the chip there would dismiss nothing — and the hosts
    /// that mount a bar solely to carry it should not mount the bar either,
    /// which is why this is asked separately rather than folded into `body`.
    static var isAvailable: Bool { !ProcessInfo.processInfo.isMacCatalystApp }

    /// Asks whatever is being typed into to let the keyboard go.
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    private func hide() {
        releaseFocus?()
        Self.dismiss()
    }

    var body: some View {
        if Self.isAvailable {
            switch style {
            case .chip: chip
            case .bordered: bordered
            }
        }
    }

    private var chip: some View {
        Button(action: hide) {
            icon
                // Matches ElementTypeBar's chips, so the row keeps one rhythm.
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
        .accessibilityLabel("Hide Keyboard")
    }

    private var bordered: some View {
        Button(action: hide) { icon }
            .buttonStyle(.bordered)
            .accessibilityLabel("Hide Keyboard")
    }

    private var icon: some View {
        Image(systemName: "keyboard.chevron.compact.down")
            .font(.footnote.weight(.medium))
    }
}

/// A bar carrying nothing but the chip, trailing-aligned.
///
/// For the surfaces with no standing bar above the keyboard — a lyric, a song's
/// plain text — where the chip has to bring its own strip. Draws no background:
/// every host mounts it with `.safeAreaBar`, which supplies the glass.
struct HideKeyboardBar: View {
    /// Passed straight to the chip — see `HideKeyboardButton.releaseFocus`.
    var releaseFocus: (() -> Void)?

    @ViewBuilder
    var body: some View {
        // Nothing at all on a Mac, rather than an empty strip's worth of air.
        if HideKeyboardButton.isAvailable {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HideKeyboardButton(releaseFocus: releaseFocus)
            }
            // The same 12/5 the editing bars inset by, so the chip lands at the
            // same distance from the edge wherever a writer meets it.
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
    }
}
