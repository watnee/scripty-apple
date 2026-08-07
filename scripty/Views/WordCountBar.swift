//
//  WordCountBar.swift
//  scripty
//
//  The running readout under a writing surface: how long the thing is, while
//  it is being written.
//
//  The screenplay's strip, and only the screenplay's: it once served the song
//  and note sheets too, but a document that runs to a page or two answers "how
//  long is this?" from its "…" menu now rather than by giving up a band of the
//  writing surface. A draft measured in pages is the one where the question is
//  standing rather than occasional, so the running band stays there — with the
//  page estimate `detail` carries, which is the reading a screenplay is
//  actually after.
//
//  Whether it shows at all stays with the caller: `showsWordCount` is a device
//  preference the screenplay reads.
//
//  It draws no background of its own. The host mounts it with `.safeAreaBar`,
//  which gives the strip the system's Liquid Glass and separates it from the
//  writing above — a hand-rolled `.bar` fill and hairline on top of that would
//  flatten the glass back into a slab.
//

import SwiftUI

struct WordCountBar: View {
    let words: Int
    /// A second reading after the count — the screenplay's page estimate. Nil
    /// where there is nothing more honest to say than the number itself.
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Text("\(ScriptWordCount.formatted(words)) words")
            if let detail {
                Text("·").foregroundStyle(.tertiary)
                Text(detail)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
