//
//  Rel.swift
//  scripty
//
//  Link relation names advertised by the Scripty API.
//  Mirrors ApiRel.java on the server — the one deliberate coupling point.
//

import Foundation

struct Rel: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    static let selfRel = Rel("self")
    static let users = Rel("users")
    static let projects = Rel("projects")
    static let blocks = Rel("blocks")
    static let characters = Rel("characters")
    static let actors = Rel("actors")
    static let teams = Rel("teams")
    static let update = Rel("update")
    static let delete = Rel("delete")
    static let project = Rel("project")
    static let actor = Rel("actor")
    static let undo = Rel("undo")
    static let redo = Rel("redo")
    static let undoRedoStatus = Rel("undoRedoStatus")
    static let syncStatus = Rel("syncStatus")
    static let toggleBookmark = Rel("toggleBookmark")
    static let togglePinned = Rel("togglePinned")
    static let createBelow = Rel("createBelow")
    static let createInitial = Rel("createInitial")
    static let setType = Rel("setType")
    static let move = Rel("move")
    static let export = Rel("export")
    static let exportPdf = Rel("exportPdf")
    static let exportDocx = Rel("exportDocx")
    static let exportFdx = Rel("exportFdx")
    static let headshot = Rel("headshot")
}
