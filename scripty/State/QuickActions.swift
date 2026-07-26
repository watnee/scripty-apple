//
//  QuickActions.swift
//  scripty
//
//  Where the Home Screen menu meets the app: the action waiting to be carried
//  out, and the recents the menu is currently offering.
//
//  SwiftUI has no hook for a quick action, so the two delegates at the bottom
//  supply one. Both arrival paths put an action here rather than acting on it,
//  because at the moment one arrives there may be no project list to act
//  against — on a cold launch the app has not even signed in yet. ContentView
//  picks it up once there is something to open.
//

import Observation
import UIKit

@Observable
@MainActor
final class QuickActions {
    static let shared = QuickActions()

    /// The action waiting for a project list to carry it out against, if any.
    /// Cleared by whoever performs it — or by the root view when the session
    /// turns out to be signed out, since none of these entries mean anything
    /// without an account.
    var pending: QuickAction?

    private init() {}

    /// Takes what UIKit handed over and keeps it if it means anything, saying
    /// whether it did.
    @discardableResult
    func receive(_ item: UIApplicationShortcutItem) -> Bool {
        let projectId = (item.userInfo?[QuickAction.projectIdKey] as? NSNumber)?.intValue
        guard let action = QuickAction(itemType: item.type, projectId: projectId) else {
            return false
        }
        pending = action
        return true
    }

    /// Republishes the "recent projects" half of the menu.
    ///
    /// The demo publishes nothing. Its projects live in memory for as long as
    /// the app is running, so an entry naming one would be an entry that could
    /// only ever fail — and it would sit on the Home Screen long after the demo
    /// was over, since nothing but this app can take it back down.
    func publishRecents(_ projects: [Project], isDemo: Bool) {
        guard !isDemo else {
            clearRecents()
            return
        }
        UIApplication.shared.shortcutItems = QuickAction.recentProjects(in: projects)
            .map { project in
                UIApplicationShortcutItem(
                    type: QuickAction.ItemType.project,
                    localizedTitle: project.displayTitle,
                    localizedSubtitle: nil,
                    icon: UIApplicationShortcutIcon(systemImageName: "film"),
                    userInfo: [QuickAction.projectIdKey: project.id as NSNumber])
            }
    }

    /// Takes the named projects back off the menu, leaving the two static
    /// entries. Signing out goes through here: the next person to pick up the
    /// phone should not be able to read the last writer's titles off a long
    /// press.
    func clearRecents() {
        UIApplication.shared.shortcutItems = []
    }
}

// MARK: - Getting told about a tap

/// Exists only to name the scene delegate below.
///
/// An app with scenes — which every SwiftUI app has — is told about a quick
/// action through its *scene* delegate; the app-delegate callback that looks
/// like the right one is never called for us. SwiftUI builds the scene itself,
/// so the one place to get a delegate class in front of it is here.
final class QuickActionAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil,
                                                 sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

/// The two ways a tap arrives, which differ only in whether the app was already
/// running when it happened.
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch: the tap is what started the app, so it comes attached to
    /// the scene rather than through the live path below.
    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let item = options.shortcutItem else { return }
        QuickActions.shared.receive(item)
    }

    /// The app was already running, so the action arrives on its own.
    /// Reporting `true` means it was understood; an entry naming something this
    /// version no longer does is dropped by `receive` and reported as such.
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(QuickActions.shared.receive(shortcutItem))
    }
}
