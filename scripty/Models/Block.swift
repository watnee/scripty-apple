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
    var highlight: String?
    var textBold: Bool?
    var textItalic: Bool?
    var textUnderline: Bool?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, projectId, order, content, type, personId, personName
        case bookmarked, pinned, scene, tags, textAlign, font, highlight
        case textBold, textItalic, textUnderline
        case links = "_links"
    }

    /// The tags on this block, as the writer sees them.
    var tagList: [String] {
        (tags ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Unknown server types fall back to `.action` for rendering.
    var blockType: BlockType {
        BlockType(rawValue: type ?? "") ?? .action
    }

    var isBookmarked: Bool { bookmarked ?? false }
    var isPinned: Bool { pinned ?? false }

    /// An element written while offline, which the server has never seen. Its
    /// id is a placeholder handed out by `OfflineBlockQueue` and is negative;
    /// every real id the server issues is positive, so the sign is the whole
    /// test and no extra field has to be threaded through the decoder.
    var isLocal: Bool { id < 0 }

    /// True when the writer may type into this element. A local element
    /// advertises no links at all — there is nothing on the server to link to
    /// — so it would otherwise come out read-only, which is precisely the
    /// element the writer is in the middle of writing.
    var isEditable: Bool { hasLink(.update) || isLocal }
}

extension Block {
    /// Build the on-screen stand-in for an element created while offline.
    ///
    /// `order` is the anchor's, which only ever matters if a server load
    /// re-sorts — and a server load replaces the collection wholesale and
    /// re-inserts the pending elements by position anyway. Declared in an
    /// extension so the memberwise initialiser survives.
    static func local(tempId: Int, projectId: Int?, order: Int?,
                      content: String, type: BlockType, personId: Int?) -> Block {
        Block(id: tempId, projectId: projectId, order: order, content: content,
              type: type.rawValue, personId: personId, personName: nil,
              bookmarked: false, pinned: false, scene: type == .scene,
              tags: nil, textAlign: nil, font: nil, highlight: nil,
              textBold: nil, textItalic: nil, textUnderline: nil, links: nil)
    }
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

    /// The type a brand-new element gets when you press Return after this one.
    /// After a character cue you're writing dialogue; otherwise action.
    /// Mirrors `nextTypeAfter` in the web editor's fountain-power.js.
    var followingType: BlockType {
        isCharacterCue ? .dialogue : .action
    }

    /// The elements outline mode keeps — the story's skeleton — and, while it
    /// is on, the only types anything may create or retype into: every other
    /// one would take the element straight off the screen the moment it was
    /// applied, carrying whatever the writer had just typed with it.
    static let outlineTypes: [BlockType] = [.scene, .section, .synopsis]

    var isOutlineType: Bool { BlockType.outlineTypes.contains(self) }

    /// The type a new element gets when Return is pressed after this one while
    /// the script is collapsed to its outline.
    ///
    /// `followingType`'s answer is action, which outline mode does not show, so
    /// the writer's next line would land somewhere they cannot see it. A new
    /// outline line carries on as the one above it instead — the way Return in
    /// a list gives another item at the same level — and the element-type bar,
    /// already narrowed to these three, retypes it in a tap. Only an outline
    /// element can be focused while outlining, so the fallback is defensive.
    var followingOutlineType: BlockType { isOutlineType ? self : .scene }

    /// Classic Final-Draft-style Tab order (mirrors `TAB_CYCLE`).
    static let tabCycle: [BlockType] =
        [.scene, .action, .character, .parenthetical, .dialogue, .transition, .shot]

    /// Less-common types map onto the logical cycle before advancing
    /// (mirrors `TAB_CYCLE_ENTRY`).
    private var tabCycleEntry: BlockType {
        switch self {
        case .text, .centered, .note: return .action
        case .lyrics: return .dialogue
        case .dualDialogue: return .character
        case .section, .synopsis, .pageBreak: return .scene
        default: return self
        }
    }

    /// The next (or previous) type when the writer presses Tab / Shift-Tab.
    func cyclingType(backward: Bool) -> BlockType {
        let cycle = BlockType.tabCycle
        let entry = tabCycleEntry
        let index = cycle.firstIndex(of: entry) ?? cycle.firstIndex(of: .action)!
        let step = backward ? -1 : 1
        let next = (index + step + cycle.count) % cycle.count
        return cycle[next]
    }

    /// Tab / Shift-Tab while outlining, walking the three outline types alone.
    ///
    /// The ordinary cycle's very next stop after a scene heading is action, so
    /// one press of Tab would erase the line from the screen — the same trap
    /// `followingOutlineType` steps around, reached by the other hand.
    func cyclingOutlineType(backward: Bool) -> BlockType {
        let cycle = BlockType.outlineTypes
        guard let index = cycle.firstIndex(of: self) else { return .scene }
        let step = backward ? -1 : 1
        return cycle[(index + step + cycle.count) % cycle.count]
    }
}

struct CreateBlockCommand: Encodable {
    var content: String
    var personId: Int?
    var projectId: Int
    var type: String
}

/// A plain PUT cannot change a block's type — use `SetTypeCommand` for that.
/// The formatting fields are only sent when set; nil leaves the server value
/// untouched, so a text auto-save never clobbers the writer's formatting.
struct EditBlockCommand: Encodable {
    var content: String
    var personId: Int?
    var tags: String?
    var textAlign: String?
    var font: String?
    var textBold: Bool?
    var textItalic: Bool?
    var textUnderline: Bool?
}

/// Reorder a block (rel `move`). `position` is the absolute `order` the block
/// should end up at, matching what the block collection reports.
struct MoveBlockCommand: Encodable {
    var position: Int
}

/// Horizontal alignment a writer can apply to an element.
enum TextAlign: String, CaseIterable, Identifiable {
    case left = "left"
    case center = "center"
    case right = "right"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }

    var systemImage: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }

    /// The server has used both `left` and `LEFT` over the years; accept either.
    init?(serverValue: String?) {
        guard let serverValue, !serverValue.isEmpty else { return nil }
        self.init(rawValue: serverValue.lowercased())
    }
}

/// The three typefaces the web editor offers.
enum ScriptFont: String, CaseIterable, Identifiable {
    case courierPrime = "Courier Prime"
    case arial = "Arial"
    case timesNewRoman = "Times New Roman"

    var id: String { rawValue }
    var label: String { rawValue }

    /// The name trimmed to its distinguishing word, for the format bar, where
    /// a full "Times New Roman" pushes the row off the side of a phone. Menus
    /// and VoiceOver keep the whole name.
    var shortLabel: String {
        switch self {
        case .courierPrime: return "Courier"
        case .arial: return "Arial"
        case .timesNewRoman: return "Times"
        }
    }

    /// Accepts either the display name (`Times New Roman`) or the enum-style
    /// name (`TIMES_NEW_ROMAN`) the server may report.
    init?(serverValue: String?) {
        guard let serverValue, !serverValue.isEmpty else { return nil }
        if let exact = ScriptFont(rawValue: serverValue) {
            self = exact
            return
        }
        let key = serverValue.uppercased().replacingOccurrences(of: " ", with: "_")
        switch key {
        case "ARIAL": self = .arial
        case "TIMES_NEW_ROMAN", "TIMES": self = .timesNewRoman
        case "COURIER_PRIME", "COURIER", "COURIER_NEW": self = .courierPrime
        default: return nil
        }
    }
}

/// Insert a new element directly beneath an existing block (rel `createBelow`).
/// The web editor uses this when Return splits a line: `content` is the text
/// that lands in the new element.
struct CreateBelowCommand: Encodable {
    var content: String
    var personId: Int?
    var type: String
}

/// Retype a block in place (rel `setType`) — the REST counterpart of the web
/// editor's element-type bar. Content/personId/tags are preserved when omitted.
struct SetTypeCommand: Encodable {
    var type: String
    var content: String?
    var personId: Int?
    var tags: String?
}

/// Replace one occurrence in one block (rel `replace`) — the single-step
/// "Replace" that walks a find through the script. `occurrence` is the
/// zero-based match to swap; this client always sends the first, because it
/// navigates block by block and the first remaining occurrence is the one under
/// the cursor. `find` and `replace` are literal, never patterns.
struct ReplaceOneCommand: Encodable {
    var find: String
    var replace: String
    var matchCase: Bool
    var wholeWord: Bool
    var occurrence: Int
}
