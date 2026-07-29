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
//  What the menu offers is decided next door in QuickAction.swift, which knows
//  nothing of UIKit and can be checked without a simulator. This half is the
//  part that cannot: the actual shortcut items, and the record of which
//  projects were opened on this device.
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

    /// When each project was last opened here. See `noteOpened`.
    private(set) var openedAt: QuickAction.OpenedDates = [:]

    /// What was last handed to the system, so an unchanged menu can be left
    /// alone. The sidebar reloads on every write it makes — a rename, a star,
    /// a team change — and all but a few of those leave the two entries
    /// word for word identical.
    private var published: [QuickAction.MenuEntry] = []

    private static let openedAtDefaultsKey = "quickActionOpenedAt"

    /// How many opens are remembered. Only two can be shown, but a few spares
    /// mean deleting or archiving the top screenplay doesn't leave the menu
    /// falling straight back to whatever the server's dates happen to say.
    private static let rememberedOpenCount = 8

    private init() {
        openedAt = Self.loadOpenedAt()
    }

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
        // Opens for screenplays the list no longer holds go with them: the
        // record is only eight deep, and an id that cannot be offered crowds
        // out one that can. Restoring from the trash costs that project its
        // place in the order, which is a fair price — it was in the bin.
        forgetOpens(outside: projects)

        let entries = QuickAction.menuEntries(in: projects, openedAt: openedAt, asOf: Date())
        // Handing the system an identical menu is not free — it redraws the
        // Home Screen's list — and there is nothing to gain from it.
        guard entries != published else { return }
        published = entries
        UIApplication.shared.shortcutItems = entries.map { entry in
            UIApplicationShortcutItem(
                type: QuickAction.ItemType.project,
                localizedTitle: entry.title,
                localizedSubtitle: entry.subtitle,
                icon: UIApplicationShortcutIcon(systemImageName: entry.systemImage),
                userInfo: [QuickAction.projectIdKey: entry.projectId as NSNumber])
        }
    }

    /// Remembers that a screenplay was opened, which is half of what the menu
    /// means by "recent".
    ///
    /// Kept on the device rather than sent anywhere: opening a screenplay is
    /// not an edit, and the server has no reason to hear about it. It also
    /// takes effect at once, where an edit only reaches the menu when the
    /// sidebar next reloads and notices the date moved.
    func noteOpened(_ project: Project, at date: Date = Date()) {
        openedAt[project.id] = date
        // Newest kept, oldest dropped — the record is a short tail, not a log.
        if openedAt.count > Self.rememberedOpenCount {
            let keep = openedAt.sorted { $0.value > $1.value }.prefix(Self.rememberedOpenCount)
            openedAt = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        saveOpenedAt()
    }

    /// Takes the named projects back off the menu, leaving the two static
    /// entries. Signing out goes through here: the next person to pick up the
    /// phone should not be able to read the last writer's titles off a long
    /// press.
    ///
    /// The record of opens is left alone, because entering the demo comes
    /// through here too and a look at the sample script is no reason to forget
    /// where the writer was. `forgetOpens()` is for the case that is.
    func clearRecents() {
        published = []
        UIApplication.shared.shortcutItems = []
    }

    /// Forgets which screenplays were opened here. Signing out: the ids belong
    /// to the account that just left, and applying them to whoever signs in
    /// next would order their menu by a stranger's reading.
    func forgetOpens() {
        openedAt = [:]
        saveOpenedAt()
    }

    private func forgetOpens(outside projects: [Project]) {
        // An empty list is "the load never landed" as often as it is "there are
        // no screenplays", and only one of those is worth forgetting over. The
        // ids cost nothing to keep: an open naming a project the list doesn't
        // hold is ignored when the order is worked out.
        guard !openedAt.isEmpty, !projects.isEmpty else { return }
        let live = Set(projects.map(\.id))
        let kept = openedAt.filter { live.contains($0.key) }
        guard kept.count != openedAt.count else { return }
        openedAt = kept
        saveOpenedAt()
    }

    // MARK: Where the opens are kept

    /// Plain defaults rather than the offline store: this is a handful of dates
    /// about the menu, not a cached copy of anything the server said, and it has
    /// to be readable before the app has signed in or fetched a thing.
    ///
    /// Ids travel as strings because a defaults dictionary is keyed by them.
    private func saveOpenedAt() {
        let encoded = Dictionary(uniqueKeysWithValues: openedAt.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(encoded, forKey: Self.openedAtDefaultsKey)
    }

    private static func loadOpenedAt() -> QuickAction.OpenedDates {
        let stored = UserDefaults.standard.dictionary(forKey: openedAtDefaultsKey) ?? [:]
        return stored.reduce(into: QuickAction.OpenedDates()) { result, pair in
            guard let id = Int(pair.key), let date = pair.value as? Date else { return }
            result[id] = date
        }
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
