//
//  UsersView.swift
//  scripty
//
//  Managing accounts: the set of them, their identity, and their roles.
//
//  Reached from the projects sidebar only when the API root advertised the
//  `users` rel — i.e. for an admin. What may be done to an account is driven by
//  the links it carries: a row offers Delete only when the server said it may be
//  deleted (an admin cannot remove their own account).
//

import SwiftUI

/// Mirrors the admin user list's sort control on the web. Raw values back an
/// @AppStorage under the same `userListSort` name the web's `<select>` uses, so
/// the choice sticks between visits.
enum UserSort: String, CaseIterable, Identifiable {
    case nameAsc
    case nameDesc
    case usernameAsc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nameAsc: "Name A–Z"
        case .nameDesc: "Name Z–A"
        case .usernameAsc: "Username A–Z"
        }
    }

    /// Web sorts on `firstName + ' ' + lastName` and, for the third option, the
    /// username — both case-insensitively.
    func applied(to users: [User]) -> [User] {
        switch self {
        case .nameAsc:
            return users.sorted {
                $0.sortName.localizedCaseInsensitiveCompare($1.sortName) == .orderedAscending
            }
        case .nameDesc:
            return users.sorted {
                $0.sortName.localizedCaseInsensitiveCompare($1.sortName) == .orderedDescending
            }
        case .usernameAsc:
            return users.sorted {
                ($0.username ?? "").localizedCaseInsensitiveCompare($1.username ?? "") == .orderedAscending
            }
        }
    }
}

struct UsersView: View {
    @State private var model: UsersModel

    @Environment(\.dismiss) private var dismiss
    @State private var isCreating = false
    @State private var editingUser: User?
    @State private var pendingDelete: User?
    @State private var searchText = ""
    @AppStorage("userListSort") private var sort = UserSort.nameAsc

    init(app: AppModel, source: HALLink) {
        _model = State(initialValue: UsersModel(app: app, source: source))
    }

    /// The list as the admin sees it: filtered by the search field, then sorted.
    /// The web matches the whole row's text; here that is the name, username,
    /// team and role summary a row shows.
    private var shown: [User] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty ? model.users : model.users.filter { user in
            user.searchHaystackLowercased.contains(query)
        }
        return sort.applied(to: filtered)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown) { user in
                    row(user)
                }
            }
            .overlay { emptyState }
            .searchable(text: $searchText, prompt: "Search by name, username, team, or role")
            .navigationTitle("Users")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(UserSort.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreating = true
                    } label: {
                        Label("New User", systemImage: "plus")
                    }
                    .disabled(model.isWorking)
                }
            }
            .task { await model.load() }
            .refreshable { await model.load() }
            .sheet(isPresented: $isCreating) {
                UserEditorSheet(heading: "New User") { draft in
                    await model.create(draft.createCommand)
                }
            }
            .sheet(item: $editingUser) { user in
                UserEditorSheet(heading: "Edit User", editing: user) { draft in
                    await model.update(user, with: draft.editCommand)
                }
            }
            .alert("Delete User", isPresented: deleteBinding) {
                Button("Cancel", role: .cancel) { pendingDelete = nil }
                Button("Delete", role: .destructive) {
                    let user = pendingDelete
                    pendingDelete = nil
                    Task {
                        guard let user else { return }
                        await model.delete(user)
                    }
                }
            } message: {
                Text("Remove “\(pendingDelete?.displayName ?? "")”? This cannot be undone.")
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private func row(_ user: User) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(user.displayName)
            HStack(spacing: 6) {
                if let username = user.username, !username.isEmpty {
                    Text("@\(username)")
                }
                Text(user.roleSummary)
                if user.enabled == false {
                    Text("Disabled").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if user.canUpdate { editingUser = user }
        }
        .swipeActions(edge: .trailing) {
            if user.canDelete {
                Button(role: .destructive) {
                    pendingDelete = user
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            if user.canUpdate {
                Button {
                    editingUser = user
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
        .contextMenu {
            if user.canUpdate {
                Button {
                    editingUser = user
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
            if user.canDelete {
                Button(role: .destructive) {
                    pendingDelete = user
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if shown.isEmpty {
            if model.isLoading {
                ProgressView()
            } else if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ContentUnavailableView {
                    Label("No Users Yet", systemImage: "person.crop.circle")
                } description: {
                    Text("Create an account to give someone access to the workspace.")
                } actions: {
                    Button("New User") { isCreating = true }
                }
            }
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}

private extension User {
    /// The key the web sorts "Name A–Z/Z–A" on: given name then surname.
    var sortName: String {
        [firstName, lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The text the web's row-level search scans — everything a row shows, so
    /// searching by name, username, team or role all work.
    var searchHaystackLowercased: String {
        [displayName, username.map { "@\($0)" } ?? "", team ?? "", roleSummary]
            .joined(separator: " ")
            .lowercased()
    }
}

/// The editable state of a user, shared by the create and edit sheets. Kept
/// separate from the `User` resource so the form owns mutable copies and the
/// two command shapes are built from one place.
private struct UserDraft {
    var username = ""
    var password = ""
    var firstName = ""
    var lastName = ""
    var team = ""
    var admin = false
    var director = false
    var producer = false
    var writer = false
    var actor = false
    var crew = false
    var directorOfPhotography = false
    var castingDirector = false
    var viewCasting = false
    var developer = false

    init() {}

    init(_ user: User) {
        username = user.username ?? ""
        firstName = user.firstName ?? ""
        lastName = user.lastName ?? ""
        team = user.team ?? ""
        admin = user.admin ?? false
        director = user.director ?? false
        producer = user.producer ?? false
        writer = user.writer ?? false
        actor = user.actor ?? false
        crew = user.crew ?? false
        directorOfPhotography = user.directorOfPhotography ?? false
        castingDirector = user.castingDirector ?? false
        viewCasting = user.viewCasting ?? false
        developer = user.developer ?? false
    }

    private var trimmedTeam: String? {
        let value = team.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var createCommand: CreateUserCommand {
        CreateUserCommand(
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            firstName: firstName.trimmingCharacters(in: .whitespaces),
            lastName: lastName.trimmingCharacters(in: .whitespaces),
            team: trimmedTeam,
            admin: admin, director: director, producer: producer, writer: writer,
            actor: actor, crew: crew, directorOfPhotography: directorOfPhotography,
            castingDirector: castingDirector, viewCasting: viewCasting,
            developer: developer)
    }

    var editCommand: EditUserCommand {
        // A blank password means "leave unchanged" — omit it so the server does
        // not try to validate an empty string.
        let trimmedPassword = password.trimmingCharacters(in: .whitespaces)
        return EditUserCommand(
            username: username.trimmingCharacters(in: .whitespaces),
            password: trimmedPassword.isEmpty ? nil : password,
            firstName: firstName.trimmingCharacters(in: .whitespaces),
            lastName: lastName.trimmingCharacters(in: .whitespaces),
            team: trimmedTeam,
            admin: admin, director: director, producer: producer, writer: writer,
            actor: actor, crew: crew, directorOfPhotography: directorOfPhotography,
            castingDirector: castingDirector, viewCasting: viewCasting,
            developer: developer)
    }
}

private struct UserEditorSheet: View {
    let heading: String
    /// Nil when creating. Drives whether a password is required and how the
    /// password field is labelled.
    let editing: User?
    let action: (UserDraft) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft = UserDraft()
    @State private var isSaving = false

    init(heading: String, editing: User? = nil, action: @escaping (UserDraft) async -> Bool) {
        self.heading = heading
        self.editing = editing
        self.action = action
        if let editing {
            _draft = State(initialValue: UserDraft(editing))
        }
    }

    private var isCreating: Bool { editing == nil }

    /// A new account needs a username, a name, and an ≥8-character password. An
    /// edit can leave the password blank to keep the existing one.
    private var canSave: Bool {
        let hasIdentity = !draft.username.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.firstName.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.lastName.trimmingCharacters(in: .whitespaces).isEmpty
        let password = draft.password.trimmingCharacters(in: .whitespaces)
        let passwordOK = isCreating ? password.count >= 8 : (password.isEmpty || password.count >= 8)
        return hasIdentity && passwordOK
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Username", text: $draft.username)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    TextField("First name", text: $draft.firstName)
                    TextField("Last name", text: $draft.lastName)
                    TextField("Team (optional)", text: $draft.team)
                }
                Section {
                    SecureField(isCreating ? "Password" : "New password", text: $draft.password)
                } header: {
                    Text("Password")
                } footer: {
                    Text(isCreating
                         ? "At least 8 characters."
                         : "Leave blank to keep the current password.")
                }
                Section("Roles") {
                    Toggle("Admin", isOn: $draft.admin)
                    Toggle("Director", isOn: $draft.director)
                    Toggle("Producer", isOn: $draft.producer)
                    Toggle("Writer", isOn: $draft.writer)
                    Toggle("Actor", isOn: $draft.actor)
                    Toggle("Crew", isOn: $draft.crew)
                    Toggle("Director of Photography", isOn: $draft.directorOfPhotography)
                    Toggle("Casting Director", isOn: $draft.castingDirector)
                    Toggle("View Casting", isOn: $draft.viewCasting)
                    Toggle("Developer", isOn: $draft.developer)
                }
            }
            .navigationTitle(heading)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        Task {
            let ok = await action(draft)
            isSaving = false
            if ok { dismiss() }
        }
    }
}
