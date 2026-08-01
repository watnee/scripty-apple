//
//  EditingLockBanner.swift
//  scripty
//
//  Says a song or a note is closed to typing, and takes the lock off when
//  tapped.
//
//  The screenplay needs no such banner: a locked script visibly loses its
//  editing bars, and the toggle sits in a menu that is always on screen. These
//  editors are sheets whose toolbars keep the switch behind an overflow menu,
//  and a locked lyric — or a locked note — looks exactly like an unlocked one.
//  Without this, a tap that does nothing has nothing to say for itself.
//
//  Shared by both editors rather than written twice, because the two must not
//  drift: a writer who learns what the strip means over a lyric should not have
//  to learn it again over a note.
//

import SwiftUI

struct EditingLockBanner: View {
    /// Called when the strip is tapped, which is the way out of the lock.
    let unlock: () -> Void

    var body: some View {
        Button(action: unlock) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                Text("Locked")
                    .fontWeight(.medium)
                Text("— tap to edit")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(.secondary.opacity(0.12))
            .overlay(alignment: .bottom) {
                Rectangle().fill(.separator).frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Editing is locked. Unlock editing.")
    }
}
