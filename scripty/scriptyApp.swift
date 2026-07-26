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

    var body: some View {
        phase
            .sheet(item: helpBinding) { screen in
                HelpSheet(screen: screen)
            }
            // A quick action can only be carried out by a signed-in session, and
            // a cold launch is `.loading` while it finds out whether there is
            // one — so the drop waits for the answer rather than firing on the
            // way past. The named projects come off the menu at the same time.
            .onChange(of: app.phase) { _, phase in
                guard case .signedOut = phase else { return }
                QuickActions.shared.pending = nil
                QuickActions.shared.clearRecents()
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

    private var helpBinding: Binding<HelpPresentation.Screen?> {
        Binding(get: { help.screen }, set: { help.screen = $0 })
    }
}
