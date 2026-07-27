//
//  WordCountBar.swift
//  scripty
//
//  The running readout under a writing surface: how long the thing is, while
//  it is being written.
//
//  One view rather than one per editor because it is the same strip of chrome
//  in every one of them — a hairline, a bar background, small monospaced
//  secondary text — and three copies of it drift apart on the first change to
//  any. What differs is only what there is to count: the screenplay adds a page
//  estimate, a lyric is measured in lines and has none, and a note is prose.
//
//  Whether it shows at all stays with the caller: `showsWordCount` is a device
//  preference each editor already reads.
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
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(.separator).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}
