//
//  UserMenu.swift
//  scripty
//
//  The account menu behind the toolbar avatar — the iOS counterpart to the
//  web app's user dropdown. Every item is rel-gated: Teams, Users, and Change
//  Password appear only when the account resource advertises those links, so
//  a non-admin (or a server that predates the account resource) simply sees
//  identity, the Theme control, and Sign Out.
//

import SwiftUI

struct UserMenu: View {
    @Bindable var app: AppModel

    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: Int, Identifiable {
        case users, teams, changePassword
        var id: Int { rawValue }
    }

    var body: some View {
        Menu {
            // Identity is the section header. The Theme picker always lives in
            // this section so it's never empty — an empty Section drops its
            // header, which would hide the name for non-admins.
            Section(app.accountDisplayName) {
                if app.account?.hasLink(.teams) == true {
                    Button {
                        activeSheet = .teams
                    } label: {
                        Label("Teams", systemImage: "person.3")
                    }
                }
                if app.account?.hasLink(.users) == true {
                    Button {
                        activeSheet = .users
                    } label: {
                        Label("Users", systemImage: "person.2")
                    }
                }
                if app.account?.hasLink(.changePassword) == true {
                    Button {
                        activeSheet = .changePassword
                    } label: {
                        Label("Change Password", systemImage: "key")
                    }
                }

                Picker(selection: $app.theme) {
                    ForEach(ThemeSetting.allCases) { setting in
                        Label(setting.label, systemImage: setting.symbol).tag(setting)
                    }
                } label: {
                    Label("Theme", systemImage: "circle.lefthalf.filled")
                }
            }

            Section {
                Button(role: .destructive) {
                    app.signOut()
                } label: {
                    Label(app.isDemo ? "Exit Demo" : "Sign Out",
                          systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            Label("Account", systemImage: "person.crop.circle")
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .users:
                if let link = app.account?.link(.users) {
                    UsersView(app: app, link: link)
                }
            case .teams:
                if let link = app.account?.link(.teams) {
                    TeamsView(app: app, link: link)
                }
            case .changePassword:
                ChangePasswordSheet(app: app)
            }
        }
    }
}
