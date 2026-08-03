//
//  HistoryToastOverlay.swift
//  scripty
//
//  The capsule that floats a `HistoryToast` over whatever is being written.
//
//  One modifier for every surface that keeps a history, because a confirmation
//  that looked or lasted different in a song than in the screenplay would read
//  as a different feature rather than the same one. How long it stays is pure
//  presentation, so the timing lives here and the models only ever say what
//  happened.
//
//  Liquid Glass rather than the web's flat dark capsule: it floats over the
//  writing, which is exactly what the material is for, and it stays legible
//  against a light page or a dark one without a hardcoded pair of colours.
//

import SwiftUI

extension View {
    /// Float this surface's history confirmations over it. Apply where the
    /// toast should settle — after any bottom inset it must sit above.
    func historyToast(_ toast: HistoryToast?) -> some View {
        modifier(HistoryToastOverlay(toast: toast))
    }
}

private struct HistoryToastOverlay: ViewModifier {
    let toast: HistoryToast?

    /// What is on screen, and the task that clears it. Kept in the view
    /// because how long a confirmation stays up is presentation — the model
    /// only says what happened, and says it once.
    @State private var text: String?
    @State private var hide: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) { capsule }
            // The token, not the text: two identical messages in a row are two
            // events, and the second has to re-show and re-arm the timer.
            .onChange(of: toast?.token) { _, token in
                guard token != nil, let toast else { return }
                hide?.cancel()
                withAnimation(.spring(duration: 0.3)) { text = toast.text }
                hide = Task {
                    // Matches the web toast's 3.2s visible span.
                    try? await Task.sleep(for: .seconds(3.2))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.3)) { text = nil }
                }
            }
    }

    /// Non-interactive, so it never swallows a tap on the writing underneath.
    @ViewBuilder
    private var capsule: some View {
        if let text {
            Text(text)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 12)
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
        }
    }
}
