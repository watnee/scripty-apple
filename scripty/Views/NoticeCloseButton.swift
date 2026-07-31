//
//  NoticeCloseButton.swift
//  scripty
//
//  The ✕ on a standing notice — the offline strips in the two editors, the
//  footer under the project list, the line under a song in the workspace.
//
//  One recipe for all four so they close the same way: a small glyph, tinted
//  down so it reads as an affordance rather than as part of the warning, and a
//  hit target padded out past the glyph itself, since a 10-point ✕ is not a
//  thing a thumb can be asked to find.
//
//  Hidden from VoiceOver on purpose. Every strip that carries one combines its
//  own text into a single accessibility element with a named "Dismiss" action;
//  a second, unlabelled control inside that element would only be noise.
//

import SwiftUI

struct NoticeCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}
