//
//  Block.swift
//  scripty
//

import Foundation

/// One screenplay element (a Fountain block): scene heading, action,
/// dialogue, transition, etc. Ordered by `order` within a project.
struct Block: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var projectId: Int?
    var order: Int?
    var content: String?
    var type: String?
    var personId: Int?
    var personName: String?
    var bookmarked: Bool?
    var pinned: Bool?
    var scene: Bool?
    var tags: String?
    var textAlign: String?
    var font: String?
    var textBold: Bool?
    var textItalic: Bool?
    var textUnderline: Bool?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, projectId, order, content, type, personId, personName
        case bookmarked, pinned, scene, tags, textAlign, font
        case textBold, textItalic, textUnderline
        case links = "_links"
    }

    /// Unknown server types fall back to `.action` for rendering.
    var blockType: BlockType {
        BlockType(rawValue: type ?? "") ?? .action
    }

    var isBookmarked: Bool { bookmarked ?? false }
    var isPinned: Bool { pinned ?? false }

    /// True when the server advertises any mutation link for this block.
    var isEditable: Bool { hasLink(.update) }
}

/// Fountain screenplay element types (mirrors Block.java on the server).
enum BlockType: String, CaseIterable, Identifiable {
    case scene = "SCENE"
    case action = "ACTION"
    case text = "TEXT"
    case character = "CHARACTER"
    case dialogue = "DIALOGUE"
    case dualDialogue = "DUAL_DIALOGUE"
    case parenthetical = "PARENTHETICAL"
    case transition = "TRANSITION"
    case shot = "SHOT"
    case lyrics = "LYRICS"
    case centered = "CENTERED"
    case section = "SECTION"
    case synopsis = "SYNOPSIS"
    case note = "NOTE"
    case pageBreak = "PAGE_BREAK"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scene: return "Scene"
        case .action: return "Action"
        case .text: return "Text"
        case .character: return "Character"
        case .dialogue: return "Dialogue"
        case .dualDialogue: return "Dual Dialogue"
        case .parenthetical: return "Parenthetical"
        case .transition: return "Transition"
        case .shot: return "Shot"
        case .lyrics: return "Lyrics"
        case .centered: return "Centered"
        case .section: return "Section"
        case .synopsis: return "Synopsis"
        case .note: return "Note"
        case .pageBreak: return "Page Break"
        }
    }

    /// Character cues carry the speaker name as their content.
    var isCharacterCue: Bool {
        self == .character || self == .dualDialogue
    }

    /// The element a writer almost always wants next, following screenplay
    /// convention: a cue is followed by its line, a line returns to action.
    /// Pressing Return in the editor creates this type below; the type bar
    /// is there for the times the guess is wrong.
    var typeBelow: BlockType {
        switch self {
        case .character, .dualDialogue, .parenthetical: return .dialogue
        case .transition: return .scene
        default: return .action
        }
    }

    /// Types offered in the editor's type bar, in the order the web app's
    /// element menu lists them.
    static var editorBar: [BlockType] {
        [.scene, .action, .character, .dialogue, .parenthetical, .transition,
         .shot, .text, .dualDialogue, .lyrics, .centered, .section, .synopsis,
         .note, .pageBreak]
    }
}

/// Content-only edit. Retyping a block goes through `setType` instead.
struct EditBlockCommand: Encodable {
    var content: String
    var personId: Int?
    var tags: String?
}

/// Inserts a new block directly below an existing one — what Return does in
/// the editor. Blank content is allowed: the row appears and the writer types.
struct CreateBlockBelowCommand: Encodable {
    var content: String
    var personId: Int?
    var type: String
}

/// Retypes a block. Omitted fields keep their stored values on the server,
/// so content/personId/tags are carried through unchanged.
struct SetBlockTypeCommand: Encodable {
    var type: String
    var content: String?
    var personId: Int?
    var tags: String?
}

/// Reorders a block to an absolute position in the project's `order` space.
struct MoveBlockCommand: Encodable {
    var position: Int
}
