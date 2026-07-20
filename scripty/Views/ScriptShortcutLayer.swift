//
//  ScriptShortcutLayer.swift
//  scripty
//
//  Binds every shortcut in the catalog, as a zero-sized layer behind the
//  script page.
//
//  SwiftUI attaches `.keyboardShortcut` to controls, not to windows, so a
//  binding needs a Button somewhere in the hierarchy whether or not there is
//  a matching control on screen. Most of these have no toolbar equivalent —
//  there is no "Centered element" button — and the ones that do (search,
//  outline) are hidden in focus mode or absent at phone width, which would
//  silently take their shortcut away with them. Putting the whole catalog in
//  one invisible layer decouples the bindings from the chrome: a shortcut
//  works whenever the script page is up, regardless of what the toolbar is
//  currently showing.
//
//  `.opacity(0)` rather than `.hidden()` on purpose — `.hidden()` takes the
//  buttons out of the layout entirely and their shortcuts stop firing.
//  `.disabled` is left doing real work: a disabled button's shortcut does not
//  fire, so gating on `isEnabled` means an unavailable action is inert rather
//  than a no-op that looks like a bug.
//

import SwiftUI

struct ScriptShortcutLayer: View {
    /// Whether the page can act on this shortcut right now. Shared with the
    /// reference sheet so the greyed-out rows there are exactly the inert ones.
    let isEnabled: (ScriptShortcutAction) -> Bool
    let perform: (ScriptShortcutAction) -> Void

    var body: some View {
        ZStack {
            ForEach(ScriptShortcutAction.all.filter { !$0.isBoundInTextView }) { action in
                Button(action.title) { perform(action) }
                    .keyboardShortcut(action.key, modifiers: action.modifiers)
                    .disabled(!isEnabled(action))
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
