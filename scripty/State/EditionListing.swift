//
//  EditionListing.swift
//  scripty
//
//  What a screen needs in order to present a set of editions.
//
//  Scripts and songs both have named editions with a default and a published
//  one, the same six operations, and the same rules about which are offered.
//  The only real difference is what an edition contains — screenplay elements
//  or lyric lines — and the picker does not care. One protocol lets one view
//  serve both, rather than two views drifting apart a fix at a time.
//

import Foundation
import Observation

@MainActor
protocol EditionListing: AnyObject, Observable {
    var editions: [ScriptEdition] { get }
    /// The one being read. Nil means "whichever the server calls default".
    var selectedId: Int? { get set }
    var selected: ScriptEdition? { get }

    var isLoading: Bool { get }
    var isWorking: Bool { get }
    var errorMessage: String? { get set }

    var canCreate: Bool { get }
    var hasChoice: Bool { get }

    /// What one item of this kind of edition is called, singular. A script
    /// edition holds elements; a song's holds lines. The picker is otherwise
    /// identical, and calling a lyric line an "element" would be the one place
    /// the shared view showed through.
    var itemNoun: String { get }

    func canRename(_ edition: ScriptEdition) -> Bool
    func canDelete(_ edition: ScriptEdition) -> Bool
    func canSetDefault(_ edition: ScriptEdition) -> Bool
    func canSetPublished(_ edition: ScriptEdition) -> Bool

    func load() async

    @discardableResult func create(name: String, copyFrom: ScriptEdition?) async -> Bool
    @discardableResult func rename(_ edition: ScriptEdition, to name: String) async -> Bool
    @discardableResult func delete(_ edition: ScriptEdition) async -> Bool
    @discardableResult func setDefault(_ edition: ScriptEdition) async -> Bool
    @discardableResult func setPublished(_ edition: ScriptEdition) async -> Bool
}

extension EditionsModel: EditionListing {}
extension SongEditionsModel: EditionListing {}
