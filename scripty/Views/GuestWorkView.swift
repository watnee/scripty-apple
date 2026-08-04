//
//  GuestWorkView.swift
//  scripty
//
//  Asked once, straight after signing in, when the writer was working without
//  an account and wrote something: which of it should the account keep?
//
//  Everything written locally is ticked to begin with — the writer wrote it,
//  so the answer is almost always "all of it" — and the sample screenplay is
//  not on the list at all unless it was changed (see `DemoBackend.guestWork`).
//  Declining is a real answer and costs nothing to reach: the local workspace
//  outlives the session either way, so what is left unticked is waiting there
//  the next time this device is signed out rather than thrown away.
//
//  Nothing here leaves the device. The account is given a copy and the device
//  keeps its own, so signing out later opens on the screenplay rather than on
//  the hole where it used to be — and from then on the two are kept in step
//  rather than drifting apart: signing out brings the account's copy down,
//  signing in sends what was written here up, and this sheet never asks about
//  that screenplay again (see `AppModel.syncLinkedProjects`).
//
//  So what is listed here is only ever work this account has never seen. The
//  one row that still warns is a screenplay a *different* account was given a
//  copy of: that one really would become a second screenplay, and it arrives
//  unticked saying so.
//

import SwiftUI

struct GuestWorkView: View {
    let app: AppModel
    let offer: GuestWorkOffer

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<Int>
    @State private var isUploading = false
    @State private var errorMessage: String?

    init(app: AppModel, offer: GuestWorkOffer) {
        self.app = app
        self.offer = offer
        // One an account already has a copy of starts unticked: ticking it is
        // asking for a second screenplay, which is a thing to choose rather
        // than a thing to have to notice and undo.
        _chosen = State(initialValue: Set(offer.projects.filter { !$0.alreadyKept }.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(offer.projects) { project in
                        Button {
                            toggle(project.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.title)
                                        .foregroundStyle(.primary)
                                    Text(subtitle(for: project))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: chosen.contains(project.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(project.id)
                                                     ? AnyShapeStyle(.tint)
                                                     : AnyShapeStyle(.secondary))
                            }
                        }
                        // Plain, or the whole row reads as one blue link: a
                        // button's label takes the tint inside a list, and the
                        // tick is the only part of this row that is a control.
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(chosen.contains(project.id) ? .isSelected : [])
                    }
                } header: {
                    Text("Written on this device")
                } footer: {
                    Text("Kept work lives in your account and on this device, "
                         + "and Scripty keeps the two the same screenplay — sign "
                         + "out and you carry on writing in it, sign back in and "
                         + "what you wrote goes up. Anything left unticked stays "
                         + "on this device only.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            // The bar has two buttons on it and an iPhone gives the title
            // whatever is left over, so both of them are as short as they can
            // be said — "Add to Account" alongside this title truncated it to
            // "Keep Y…", and the question is the part that has to be readable.
            .navigationTitle("Keep Your Work?")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                        .disabled(isUploading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isUploading {
                        ProgressView()
                    } else {
                        Button("Keep") { upload() }
                            .disabled(chosen.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(isUploading)
        }
    }

    private func elementCount(_ count: Int) -> String {
        count == 1 ? "1 element" : "\(count) elements"
    }

    /// What the row says under the title. A screenplay another account already
    /// has a copy of says that instead of its size: the size is not the thing
    /// the writer has to weigh, and what "Keep" means for this row is different
    /// — a second screenplay rather than a first. (This account's own
    /// screenplays are not on this list at all; they are caught up without
    /// being asked about.)
    private func subtitle(for project: GuestWorkOffer.Item) -> String {
        project.alreadyKept
            ? "Already kept by another account — this makes a second copy"
            : elementCount(project.elements)
    }

    private func toggle(_ id: Int) {
        if chosen.contains(id) {
            chosen.remove(id)
        } else {
            chosen.insert(id)
        }
        errorMessage = nil
    }

    /// The chosen screenplays in the order they were offered — newest first,
    /// as the sidebar lists them — rather than in whatever order a `Set`
    /// happens to hold ids.
    private func upload() {
        isUploading = true
        let ids = offer.projects.map(\.id).filter(chosen.contains)
        Task {
            let failure = await app.uploadGuestWork(offer, ids: ids)
            isUploading = false
            if let failure {
                errorMessage = failure
            } else {
                dismiss()
            }
        }
    }
}
