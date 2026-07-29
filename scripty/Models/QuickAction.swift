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
//  This file is deliberately free of UIKit so the routing can be checked
//  without a simulator — QuickActions.swift is where the two meet.
//

import Foundation

/// One entry in the Home Screen's long-press menu, in the form the app acts on
/// rather than the form UIKit hands over.
///
/// No longer only the menu's, despite the name: Control Center buttons and the
/// app's own Siri shortcuts park their requests here too. They all want the
/// same three things — a project, one of the two lists, and whether to open the
/// composer — and they all arrive at a moment when there may be no session and
/// no project list yet, which is what this vocabulary was built for.
enum QuickAction: Equatable, Sendable {
    /// The songs list of whichever project `project(in:)` settles on.
    case songs
    /// That same project's notes — the other half of the one screen.
    case notes
    /// A project the menu named, chosen from the recents.
    case project(id: Int)
    /// A new, empty song or note, with the composer already open. The project
    /// is named where one was known and settled the usual way where it wasn't —
    /// a Control Center tile knows nothing but which half it is for.
    case compose(projectId: Int?, type: DocumentType)
    /// The screenplay itself, on whichever project `project(in:)` settles on.
    /// The unnamed twin of `project(id:)`, for a fixed tile that cannot know
    /// which screenplay it will be pressed for.
    case preferredProject
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
        case .project, .preferredProject: nil
        case .compose(_, let type): type
        }
    }

    /// Whether the list should open with the composer already up, rather than
    /// on the list itself.
    var isCreating: Bool {
        if case .compose = self { return true }
        return false
    }
}

// MARK: - Choosing a project

extension QuickAction {
    /// The project this action opens, or nil when the list holds nothing that
    /// answers to it — an entry naming a screenplay since deleted, or a Songs
    /// tap by an account with no projects at all.
    func project(in projects: [Project]) -> Project? {
        switch self {
        case .project(let id):
            return projects.first { $0.id == id }
        case .compose(.some(let id), _):
            return projects.first { $0.id == id }
        case .songs, .notes, .preferredProject, .compose(nil, _):
            return Self.preferredProject(in: projects)
        }
    }

    /// Where Songs and Notes land when the menu entry names no project of its
    /// own: the starred default, and failing that the one edited most recently.
    ///
    /// The star is asked first on purpose. It is the writer's own answer to
    /// "which screenplay is mine", and a writer who has given one deserves it
    /// over whichever project a stray edit touched last.
    ///
    /// The list arrives sorted by last edited already, but this sorts again
    /// rather than trusting that — the ordering is the sidebar's business, and
    /// a menu that quietly follows it would break the day the sidebar changed
    /// its mind.
    static func preferredProject(in projects: [Project]) -> Project? {
        if let starred = projects.first(where: { $0.isDefault == true }) {
            return starred
        }
        return recentProjects(in: projects, limit: 1).first
    }

    /// How many recent projects the menu can carry. See the note at the top of
    /// the file: four entries, two of them static, leaves two.
    static let recentProjectLimit = 2

    /// The projects the menu offers by name, most recently edited first.
    ///
    /// A project the server gave no edit date is included rather than filtered
    /// out — it sorts last, but an account whose only screenplay has never been
    /// touched should still find it here rather than an empty menu. Ties break
    /// on title so the menu is not reshuffled by a sort that never promised to
    /// be stable.
    static func recentProjects(in projects: [Project],
                               limit: Int = recentProjectLimit) -> [Project] {
        let ordered = projects.sorted { lhs, rhs in
            let left = lhs.lastEdited ?? .distantPast
            let right = rhs.lastEdited ?? .distantPast
            if left != right { return left > right }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
                == .orderedAscending
        }
        return Array(ordered.prefix(max(0, limit)))
    }
}
