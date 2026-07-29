//
//  QuickAction.swift
//  scripty
//
//  What a long press on the Home Screen icon offers, and what the app does
//  about it. The menu holds two kinds of entry:
//
//  - Songs and Notes, declared in Info.plist. They are there from a fresh
//    install, before the app has ever run and had a chance to say anything.
//  - The last projects edited, published at runtime as the list loads.
//
//  iOS shows four entries at most, static ones first. That arithmetic is the
//  reason `recentProjectLimit` is two rather than a rounder number: a third
//  recent would be dropped on the floor, and a menu that silently loses an
//  entry is worse than one that never offered it.
//
//  With so few entries, each one has to earn its place, so this file decides
//  how a recent reads as well as which projects are offered: what its subtitle
//  says and which icon it carries.
//
//  This file is deliberately free of UIKit so the routing can be checked
//  without a simulator — QuickActions.swift is where the two meet.
//

import Foundation

/// One entry in the Home Screen's long-press menu, in the form the app acts on
/// rather than the form UIKit hands over.
enum QuickAction: Equatable, Sendable {
    /// The songs list of whichever project `project(in:)` settles on.
    case songs
    /// That same project's notes — the other half of the one screen.
    case notes
    /// A project the menu named, chosen from the recents.
    case project(id: Int)
}

extension QuickAction {
    /// The `type` strings the shortcut items carry. The two static ones are
    /// spelled out in Info.plist as well, and the pair has to agree: a typo
    /// there does not fail to build, it just produces a menu entry that does
    /// nothing when tapped.
    enum ItemType {
        static let songs = "scripty.songs"
        static let notes = "scripty.notes"
        static let project = "scripty.project"
    }

    /// The `userInfo` key a recents entry carries its project under.
    static let projectIdKey = "projectId"

    /// Rebuilds the action from the two things a shortcut item carries.
    ///
    /// Unknown types give nil rather than trapping: the Home Screen keeps
    /// showing the dynamic entries an older version published until this one
    /// replaces them, so an entry naming something the app no longer does is a
    /// normal thing to be handed, not a bug.
    init?(itemType: String, projectId: Int?) {
        switch itemType {
        case ItemType.songs:
            self = .songs
        case ItemType.notes:
            self = .notes
        case ItemType.project:
            guard let projectId else { return nil }
            self = .project(id: projectId)
        default:
            return nil
        }
    }

    /// Which of the two lists the action opens, or nil where it opens neither
    /// and only wants the screenplay itself.
    var documentType: DocumentType? {
        switch self {
        case .songs: .song
        case .notes: .notes
        case .project: nil
        }
    }
}

// MARK: - Choosing a project

extension QuickAction {
    /// When each project was last opened on this device, by project id.
    ///
    /// The server's `lastEdited` is the only recency it knows about, and it
    /// moves when a screenplay is written to — not when it is read, and not
    /// until the sidebar reloads and hears about it. Opening one here counts
    /// too, and counts immediately, which is what keeps the menu describing
    /// where the writer actually was rather than where the last load found them.
    typealias OpenedDates = [Int: Date]

    /// The project this action opens, or nil when the list holds nothing that
    /// answers to it — an entry naming a screenplay since deleted, or a Songs
    /// tap by an account with no projects at all.
    func project(in projects: [Project], openedAt: OpenedDates = [:]) -> Project? {
        switch self {
        case .project(let id):
            return projects.first { $0.id == id }
        case .songs, .notes:
            return Self.preferredProject(in: projects, openedAt: openedAt)
        }
    }

    /// Where Songs and Notes land when the menu entry names no project of its
    /// own: the starred default, and failing that the most recent one.
    ///
    /// The star is asked first on purpose. It is the writer's own answer to
    /// "which screenplay is mine", and a writer who has given one deserves it
    /// over whichever project a stray edit touched last.
    ///
    /// The fallback follows the same order the named entries are in, so the
    /// menu never contradicts itself: Songs lands on the screenplay sitting at
    /// the top of the recents, not on some other reading of "latest".
    static func preferredProject(in projects: [Project],
                                 openedAt: OpenedDates = [:]) -> Project? {
        if let starred = projects.first(where: { $0.isDefault == true }) {
            return starred
        }
        return recentProjects(in: projects, openedAt: openedAt, limit: 1).first
    }

    /// How many recent projects the menu can carry. See the note at the top of
    /// the file: four entries, two of them static, leaves two.
    static let recentProjectLimit = 2

    /// How recently a project was touched by either measure — read or written,
    /// here or anywhere else. `.distantPast` for one that answers to neither,
    /// which sorts it last without dropping it.
    private static func lastActivity(_ project: Project, openedAt: OpenedDates) -> Date {
        max(project.lastEdited ?? .distantPast, openedAt[project.id] ?? .distantPast)
    }

    /// The projects the menu offers by name, most recently touched first.
    ///
    /// The list arrives sorted by last edited already, but this sorts again
    /// rather than trusting that — the ordering is the sidebar's business, and
    /// a menu that quietly followed it would break the day the sidebar changed
    /// its mind. It has to sort anyway now that opening counts, which the
    /// sidebar knows nothing about.
    ///
    /// A project the server gave no edit date is included rather than filtered
    /// out — it sorts last, but an account whose only screenplay has never been
    /// touched should still find it here rather than an empty menu. Ties break
    /// on title so the menu is not reshuffled by a sort that never promised to
    /// be stable.
    static func recentProjects(in projects: [Project],
                               openedAt: OpenedDates = [:],
                               limit: Int = recentProjectLimit) -> [Project] {
        let ordered = projects.sorted { lhs, rhs in
            let left = lastActivity(lhs, openedAt: openedAt)
            let right = lastActivity(rhs, openedAt: openedAt)
            if left != right { return left > right }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
                == .orderedAscending
        }
        return Array(ordered.prefix(max(0, limit)))
    }
}

// MARK: - How an entry reads

extension QuickAction {
    /// One named-project entry, in the form the menu shows rather than the form
    /// UIKit wants — so what the writer ends up reading can be checked here.
    struct MenuEntry: Equatable {
        var projectId: Int
        var title: String
        var subtitle: String
        var systemImage: String
    }

    /// The named half of the menu: which projects, in what order, and what each
    /// one says.
    static func menuEntries(in projects: [Project],
                            openedAt: OpenedDates = [:],
                            asOf now: Date,
                            limit: Int = recentProjectLimit) -> [MenuEntry] {
        recentProjects(in: projects, openedAt: openedAt, limit: limit).map { project in
            MenuEntry(projectId: project.id,
                      title: project.displayTitle,
                      subtitle: subtitle(for: project, openedAt: openedAt[project.id], asOf: now),
                      // The star the sidebar puts on the default project, which
                      // is also the one Songs and Notes open — so the entry that
                      // wears it is visibly the screenplay those two mean.
                      systemImage: project.isDefault == true ? "star.fill" : "film")
        }
    }

    /// What an entry says under its title.
    ///
    /// Two identically-named drafts are otherwise impossible to tell apart, and
    /// a menu offering a screenplay untouched since spring should say so rather
    /// than let its position at the top imply otherwise.
    ///
    /// The verb is whichever activity earned the entry its place. Saying
    /// "Edited three weeks ago" on the top entry — put there by this morning's
    /// visit — would read as a menu that had got its own order wrong.
    static func subtitle(for project: Project, openedAt: Date?, asOf now: Date) -> String {
        if let openedAt, openedAt > (project.lastEdited ?? .distantPast) {
            return phrase("Opened", openedAt, asOf: now)
        }
        guard let edited = project.lastEdited else { return "Not edited yet" }
        return phrase("Edited", edited, asOf: now)
    }

    /// "Edited yesterday", "Opened 3 weeks ago", and so on.
    ///
    /// Counted in whole calendar days rather than elapsed hours: something
    /// written at midnight and read at eight is "yesterday" to the writer, not
    /// "8 hours ago". Coarsens as it goes back, because at three months the
    /// exact day stopped being the point.
    ///
    /// A date in the future is the device's clock disagreeing with the
    /// server's, not a screenplay edited tomorrow, so it reads as just now.
    ///
    /// A relative phrase is only true as of when it was written, and nothing
    /// can rewrite the menu while the app is closed. ContentView rebuilds it on
    /// the way to the background, which covers everything but a phone left
    /// alone for days — where "Edited today" means the last day the app was
    /// opened. The alternative, a fixed date, is wrong at no moment and useful
    /// at none either: "recent" is the question being asked.
    private static func phrase(_ verb: String, _ date: Date, asOf now: Date) -> String {
        guard date <= now else { return "\(verb) just now" }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "\(verb) today"
        case 1: return "\(verb) yesterday"
        case 2..<7: return "\(verb) \(days) days ago"
        case 7..<14: return "\(verb) last week"
        case 14..<31: return "\(verb) \(days / 7) weeks ago"
        case 31..<62: return "\(verb) last month"
        case 62..<365: return "\(verb) \(days / 30) months ago"
        case 365..<730: return "\(verb) last year"
        default: return "\(verb) \(days / 365) years ago"
        }
    }
}
