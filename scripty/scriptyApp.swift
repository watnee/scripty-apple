//
//  scriptyApp.swift
//  scripty
//
//  Created by Clint Watnee on 7/13/26.
//

import SwiftUI

@main
struct scriptyApp: App {
    @State private var appModel = AppModel()

    /// Only reason for an app delegate: a Home Screen quick action is delivered
    /// through the scene delegate this one names, and SwiftUI gives no other
    /// way to get one in front of the scene it builds.
    @UIApplicationDelegateAdaptor(QuickActionAppDelegate.self) private var appDelegate

    /// Light, dark or the device's own — the whole app, so it is applied here
    /// rather than anywhere a script happens to be.
    private let appearance = AppearanceSettings.shared

    var body: some Scene {
        WindowGroup {
            RootView(app: appModel)
                .preferredColorScheme(colorScheme)
                .onOpenURL { url in
                    // The link in a password recovery email, which iOS routes
                    // here rather than to a browser because the app claims that
                    // path on the server's domain. It carries the token, so
                    // there is nothing for the writer to copy out of the mail.
                    if let token = PasswordResetLink.token(in: url) {
                        appModel.passwordResetToken = token
                        return
                    }
                    // scripty://demo — e.g. from a home-screen Shortcut —
                    // jumps straight into the offline demo.
                    guard url.scheme == "scripty",
                          url.host() == "demo" || url.path == "/demo" else { return }
                    Task { await appModel.enterDemo() }
                }
        }
        // Real menus on the Mac, and real keyboard shortcuts on an iPad with
        // a keyboard attached. Every item is disabled until a script has focus.
        .commands { ScriptCommands() }
    }

    /// `nil` hands the choice back to the system, which is what "System" means.
    private var colorScheme: ColorScheme? {
        switch appearance.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Switches between the launch spinner, login, and the main app.
struct RootView: View {
    let app: AppModel

    /// Help is presented here rather than from the project list so that the
    /// menu bar's Help items work in every phase — including signed out, where
    /// "how do I get in" is exactly the question being asked.
    private let help = HelpPresentation.shared

    /// A token from a recovery email's link, once the server has said where a
    /// reset goes.
    ///
    /// Owned here rather than by the login screen because the link can land in
    /// any phase. Tapping it is often what launches the app, so it can arrive
    /// while the launch spinner is still up — and it can arrive on a device
    /// that is still signed in, where there is no login screen to hand it to.
    @State private var pendingReset: PendingReset?

    private struct PendingReset: Identifiable {
        let link: HALLink
        let token: String
        /// One sheet per token: tapping the same link twice shouldn't stack.
        var id: String { token }
    }

    var body: some View {
        phase
            .sheet(item: helpBinding) { screen in
                HelpSheet(screen: screen)
            }
            // Re-runs whenever a link arrives, whatever the phase.
            .task(id: app.passwordResetToken) { await adoptResetToken() }
            .sheet(item: $pendingReset, onDismiss: { app.passwordResetToken = nil }) { pending in
                PasswordRecoveryView(client: app.client, reset: pending.link,
                                     token: pending.token) {
                    // This session was opened with the password that just
                    // changed, so it cannot outlive it. The sheet lives above
                    // the phase and stays up to say the reset worked, while
                    // the login screen takes its place underneath.
                    if case .signedIn = app.phase { app.signOut() }
                }
            }
            // A quick action can only be carried out by a signed-in session, and
            // a cold launch is `.loading` while it finds out whether there is
            // one — so the drop waits for the answer rather than firing on the
            // way past. The named projects come off the menu at the same time,
            // along with the record of which ones were opened: both describe the
            // account that just left.
            .onChange(of: app.phase) { _, phase in
                guard case .signedOut = phase else { return }
                QuickActions.shared.pending = nil
                QuickActions.shared.clearRecents()
                QuickActions.shared.forgetOpens()
            }
    }

    @ViewBuilder
    private var phase: some View {
        switch app.phase {
        case .loading:
            ProgressView()
                .task { await app.bootstrap() }
        case .signedOut:
            LoginView(app: app)
        case .signedIn:
            // Re-key on demo mode so entering the demo from a signed-in
            // session rebuilds the project list against the new client.
            ContentView(app: app)
                .id(app.isDemo)
        }
    }

    /// Asks the server where a reset goes, then opens the sheet on the token.
    ///
    /// The link rides on the 401 challenge, which `signedOutLinks()` reads with
    /// no credentials attached — so it answers the same whether or not this
    /// device is signed in. A server that doesn't offer recovery leaves the
    /// token unclaimed rather than opening a sheet that could only fail.
    private func adoptResetToken() async {
        guard let token = app.passwordResetToken else { return }
        guard let link = await app.client.signedOutLinks()[.resetPassword] else { return }
        pendingReset = PendingReset(link: link, token: token)
    }

    private var helpBinding: Binding<HelpPresentation.Screen?> {
        Binding(get: { help.screen }, set: { help.screen = $0 })
    }
}
