//
//  SyncStatus.swift
//  scripty
//

import Foundation

/// Response of the project `syncStatus` link. `revision` is a lastEdited
/// epoch-millis timestamp; `changed` is true when the project was edited
/// after the `since` value the client sent.
struct SyncStatus: Decodable, HALResource {
    var exists: Bool?
    var revision: Int64?
    var changed: Bool?
    var title: String?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case exists, revision, changed, title
        case links = "_links"
    }
}

/// Response of the `undoRedoStatus` link; also returned by undo/redo
/// actions themselves (with `success`). Carries the `undo`/`redo` links.
struct UndoRedoStatus: Decodable, HALResource {
    var canUndo: Bool?
    var canRedo: Bool?
    var success: Bool?
    var moveOnly: Bool?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case canUndo, canRedo, success, moveOnly
        case links = "_links"
    }
}
