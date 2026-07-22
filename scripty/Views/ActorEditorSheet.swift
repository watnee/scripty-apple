//
//  ActorEditorSheet.swift
//  scripty
//
//  Create or edit one actor in the project's cast. Mirrors the character
//  editor: a short form, a save spinner, and the server's message inline
//  when the write is refused.
//

import PhotosUI
import SwiftUI

struct ActorEditorSheet: View {
    let casting: CastingModel
    let actor: ScriptyActor?   // nil = create

    @Environment(\.dismiss) private var dismiss
    @State private var first: String
    @State private var last: String
    @State private var phone: String
    @State private var email: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var isUploadingHeadshot = false

    init(casting: CastingModel, actor: ScriptyActor?) {
        self.casting = casting
        self.actor = actor
        _first = State(initialValue: actor?.first ?? "")
        _last = State(initialValue: actor?.last ?? "")
        _phone = State(initialValue: actor?.phone ?? "")
        _email = State(initialValue: actor?.email ?? "")
    }

    /// A name is the only thing the cast list can't do without; contact
    /// details are optional, but a typed email has to look like one.
    private var canSave: Bool {
        !first.trimmingCharacters(in: .whitespaces).isEmpty
            && !last.trimmingCharacters(in: .whitespaces).isEmpty
            && emailIsPlausible
            && !isSaving
    }

    private var emailIsPlausible: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("First name", text: $first)
                        .textContentType(.givenName)
                    TextField("Last name", text: $last)
                        .textContentType(.familyName)
                }
                headshotSection
                Section("Contact") {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(actor == nil ? "New Actor" : "Edit Actor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(!canSave)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The actor as the model now holds it. Uploading or removing a headshot
    /// changes which links the actor carries, and the copy this sheet was
    /// opened with cannot know that — reading it back is what makes "Choose"
    /// turn into "Replace" without closing the form.
    private var currentActor: ScriptyActor? {
        guard let actor else { return nil }
        return casting.actors.first { $0.id == actor.id } ?? actor
    }

    /// The headshot, and the two things that can be done to it.
    ///
    /// Only for an actor that already exists: the upload needs somewhere to put
    /// the image, and a new actor has no id until the form is saved. Adding a
    /// picture is therefore a second visit, which is how the web form behaves
    /// on create too.
    @ViewBuilder
    private var headshotSection: some View {
        if let actor = currentActor, casting.canSetHeadshot(actor) {
            Section("Headshot") {
                HStack(spacing: 14) {
                    thumbnail(for: actor)
                    VStack(alignment: .leading, spacing: 8) {
                        PhotosPicker(selection: $pickedPhoto, matching: .images) {
                            Label(casting.canRemoveHeadshot(actor) ? "Replace Photo…" : "Choose Photo…",
                                  systemImage: "photo")
                        }
                        .disabled(isUploadingHeadshot)

                        if casting.canRemoveHeadshot(actor) {
                            Button(role: .destructive) {
                                Task { await removeHeadshot(actor) }
                            } label: {
                                Label("Remove Photo", systemImage: "trash")
                            }
                            .disabled(isUploadingHeadshot)
                        }
                    }
                    Spacer(minLength: 0)
                    if isUploadingHeadshot { ProgressView() }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: pickedPhoto) { _, picked in
                guard let picked else { return }
                Task { await upload(picked, for: actor) }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for actor: ScriptyActor) -> some View {
        Group {
            if let data = casting.headshotData(for: actor),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
        .task { await casting.loadHeadshot(for: actor) }
        .accessibilityHidden(true)
    }

    /// Sends the chosen image as JPEG rather than whatever the photo library
    /// held. A photo off a modern iPhone is HEIC, which the server does not
    /// accept and no browser would have offered it either — re-encoding here is
    /// what makes "choose a photo" mean the same thing on both clients.
    private func upload(_ picked: PhotosPickerItem, for actor: ScriptyActor) async {
        isUploadingHeadshot = true
        errorMessage = nil
        defer {
            isUploadingHeadshot = false
            pickedPhoto = nil
        }

        guard let raw = try? await picked.loadTransferable(type: Data.self),
              let image = UIImage(data: raw),
              let jpeg = image.jpegData(compressionQuality: 0.85) else {
            errorMessage = "That image could not be read."
            return
        }
        if !(await casting.setHeadshot(actor, data: jpeg,
                                       fileName: "headshot.jpg",
                                       mimeType: "image/jpeg")) {
            // The server's message names the rule that was broken — too large,
            // wrong format — so it is worth more than anything written here.
            errorMessage = casting.errorMessage
            casting.errorMessage = nil
        }
    }

    private func removeHeadshot(_ actor: ScriptyActor) async {
        isUploadingHeadshot = true
        errorMessage = nil
        defer { isUploadingHeadshot = false }
        if !(await casting.removeHeadshot(actor)) {
            errorMessage = casting.errorMessage
            casting.errorMessage = nil
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        let trimmedFirst = first.trimmingCharacters(in: .whitespaces)
        let trimmedLast = last.trimmingCharacters(in: .whitespaces)
        let trimmedPhone = phone.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        Task {
            let succeeded: Bool
            if let actor {
                succeeded = await casting.updateActor(
                    actor, first: trimmedFirst, last: trimmedLast,
                    phone: trimmedPhone.isEmpty ? nil : trimmedPhone,
                    email: trimmedEmail.isEmpty ? nil : trimmedEmail)
            } else {
                succeeded = await casting.createActor(
                    first: trimmedFirst, last: trimmedLast,
                    phone: trimmedPhone.isEmpty ? nil : trimmedPhone,
                    email: trimmedEmail.isEmpty ? nil : trimmedEmail)
            }
            isSaving = false
            if succeeded {
                dismiss()
            } else {
                errorMessage = casting.errorMessage
                casting.errorMessage = nil   // shown inline; don't also alert the list
            }
        }
    }
}
