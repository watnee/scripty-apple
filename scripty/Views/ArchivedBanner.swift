//
//  ArchivedBanner.swift
//  scripty
//
//  Says a song or a note is in the archive rather than the list, and brings it
//  back when the button is pressed.
//
//  The archive opens its documents in place — that is the whole difference
//  between putting something aside and binning it — so a writer can be typing
//  into a document that is not in the list they came from, and nothing else on
//  screen would say so. Worse, the way back was somewhere else entirely: leave
//  the editor, reopen the archive, find the row, swipe it. This is that trip
//  reduced to the one button, at the moment the question comes up.
//
//  Shaped like `EditingLockBanner` and mounted where it is, because the two say
//  the same kind of thing: this document is not in the state you assume. Unlike
//  that one the strip is not itself the button — the way out of a lock is to
//  start typing, and the way out of the archive is a decision worth pressing
//  something for, next to a sentence that stays readable while you decide.
//
//  Told from `archivedAt`, not from the link: the stamp says what this is, the
//  link says whether this reader may change it. A view-only collaborator is
//  told where they are and simply offered nothing to press.
//

import SwiftUI

struct ArchivedBanner: View {
    /// What it is — "song" or "note" — so the sentence names the thing rather
    /// than saying "document" at someone who is looking at lyrics.
    let kind: DocumentType
    /// Nil where the server did not offer the way back, which leaves the strip
    /// as a statement of where you are.
    var unarchive: (() -> Void)?
    var isWorking = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox.fill")
                .font(.caption)
            Text("Archived")
                .fontWeight(.medium)
            Text("— not in your \(listWord)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let unarchive {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Unarchive", action: unarchive)
                        .fontWeight(.medium)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            }
        }
        .font(.footnote)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.secondary.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This \(kind == .song ? "song" : "note") is archived.")
    }

    /// The list it is being kept out of, named as the app names it.
    private var listWord: String { kind == .song ? "songs" : "notes" }
}
