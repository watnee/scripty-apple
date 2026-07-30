//
//  CloudSyncBadge.swift
//  scripty
//
//  One glyph in the corner answering the question every writer asks without
//  meaning to: is what I just typed anywhere other than this device?
//
//  The banners already say so — but only when something is wrong, and a screen
//  that is silent when all is well can be silent for either reason. The badge
//  is the standing half of that answer: always there, quiet when the work is on
//  the server, coloured the moment it isn't.
//

import SwiftUI

/// Where the work on screen currently lives.
enum CloudSyncState: Equatable {
    /// Everything typed here has reached the server.
    case synced
    /// There is a route to the network, but some of the writing is still on
    /// its way — a save retrying, or elements written offline still queued.
    case holding
    /// No route to the network at all; nothing can leave this device yet.
    case offline
    /// The server refused some of the writing — a failure no retry is going
    /// to fix on its own. Distinct from `holding` because the honest verbs
    /// differ: holding is "saving", this is "couldn't save".
    case failed
}

/// The cloud in the corner: a standing answer to "is my work saved?".
///
/// Deliberately dull in the good state. A badge that shouts while everything
/// is fine is a badge writers learn to stop reading, which is precisely when
/// it needs to be read — so the healthy state is a grey checkmark and only the
/// two states worth acting on wear the banners' amber.
struct CloudSyncBadge: View {
    let state: CloudSyncState

    /// How many elements are held on this device. Named in the spoken label
    /// when there are any; the glyph itself never tries to carry a number.
    var heldCount: Int = 0

    /// Overrides the spoken sentence where the default one would be a lie —
    /// the projects list is not "saving" anything while it waits on a refresh,
    /// it is showing yesterday's copy. The glyph and its colour stay the same;
    /// only the words a caller can say better than this view are handed in.
    var label: String? = nil

    var body: some View {
        Image(systemName: symbol)
            // A shade smaller than the controls beside it: this is something to
            // read, not something to press, and the size difference says so
            // before the shape does.
            .font(.subheadline)
            // One width for all three glyphs — a slashed cloud is wider than a
            // ticked one, and without this the title next door would shuffle
            // sideways every time the connection changed its mind.
            .frame(width: 20)
            .foregroundStyle(tint)
            // Says "still working on it" without a spinner taking a seat of
            // its own in the bar.
            .symbolEffect(.pulse, options: .repeating, isActive: state == .holding)
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy(duration: 0.2), value: state)
            .accessibilityElement()
            .accessibilityLabel(spokenLabel)
            .help(spokenLabel)
    }

    private var symbol: String {
        switch state {
        case .synced: "checkmark.icloud"
        // The same arrows the "Not saved yet" banner wears, on a cloud.
        case .holding: "arrow.trianglehead.2.clockwise.rotate.90.icloud"
        case .offline: "icloud.slash"
        case .failed: "exclamationmark.icloud"
        }
    }

    private var tint: Color {
        switch state {
        case .synced: .secondary
        case .holding, .offline: .orange
        // Red, alone among the states: amber means patience will fix it,
        // and here it will not.
        case .failed: .red
        }
    }

    /// What VoiceOver reads and what the pointer's tooltip shows on the Mac.
    /// Full sentences: the badge is the only thing on screen saying this when
    /// the writing is merely late rather than stranded.
    private var spokenLabel: String {
        if let label { return label }
        let held = heldCount == 1
            ? "1 element is kept on this device"
            : "\(heldCount) elements are kept on this device"
        switch state {
        case .synced:
            return "Saved to the cloud."
        case .holding:
            return heldCount > 0
                ? "Saving to the cloud. \(held) in the meantime."
                : "Saving to the cloud."
        case .offline:
            return heldCount > 0
                ? "Offline. \(held) and will sync when you're back online."
                : "Offline. Edits are kept on this device and sync when you're back online."
        case .failed:
            return heldCount > 0
                ? "Some changes couldn't be saved. \(held)."
                : "Some changes couldn't be saved. They are kept on this device."
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        CloudSyncBadge(state: .synced)
        CloudSyncBadge(state: .holding, heldCount: 3)
        CloudSyncBadge(state: .offline, heldCount: 3)
        CloudSyncBadge(state: .failed, heldCount: 1)
    }
    .padding()
}
