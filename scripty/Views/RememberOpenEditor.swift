//
//  RememberOpenEditor.swift
//  scripty
//
//  Keeping the "what was open" record up to date, as one modifier.
//
//  It could be an `onChange` at each of the three call sites, and was — but
//  ScriptView's and SongsView's bodies are both long enough that one more
//  inline closure put them past what the type checker will attempt ("unable to
//  type-check this expression in reasonable time", the same wall the songs list
//  and the projects sidebar hit over a Picker). A named modifier with concrete
//  argument types keeps that inference out of the body.
//

import SwiftUI

extension View {
    /// Notes what this view has open at `depth` — 0 for a screen above the
    /// script, 1 for one opened from there — whenever it changes.
    ///
    /// Deliberately not `initial: true`: the record has to survive being read on
    /// the way in, and announcing "nothing is open" before the restore has had
    /// its turn would erase what it came to reopen.
    ///
    /// `isEnabled` is how the demo opts out. The demo would restore perfectly
    /// well — it seeds the same ids every time — but its record would be written
    /// over the real account's, and someone who tries the sample screenplay for
    /// five minutes should not come back to their own work having lost their
    /// place in it. A walkthrough is not where anybody left off.
    func remembersOpenEditor(_ editor: OpenEditor?, atDepth depth: Int,
                             isEnabled: Bool) -> some View {
        onChange(of: editor) { _, editor in
            guard isEnabled else { return }
            OpenEditorState.shared.record(editor, atDepth: depth)
        }
    }
}
