//
//  ScriptNarration.swift
//  scripty
//
//  A screenplay, arranged for a voice.
//
//  A script on the page is laid out for the eye: the slug line is shouted in
//  caps, the speaker's name sits above their line rather than in it, and the
//  abbreviations are the ones that fit in a margin. Read back literally, all
//  of that comes out wrong — a synthesizer spells "INT." letter by letter,
//  announces every name twice, and runs the description into the dialogue with
//  no seam between them.
//
//  So this turns the blocks into an ordered run of *cues*: what to say, whose
//  line it is, and what kind of thing it is — which is what decides the pause
//  in front of it and, when a cast of voices is in use, who says it. Purely a
//  transformation over `Block`, with no synthesizer in sight, so the awkward
//  half (the text rules) can be checked without making a sound. `ScriptNarrator`
//  is the half that speaks.
//

import Foundation

/// What the reader is asked to say, and what to leave out.
struct NarrationOptions: Equatable {
    /// Say the speaker's name before their first line. Off is how a radio play
    /// sounds; on is how a table read sounds, and is the safer default when
    /// every character shares one voice.
    var announcesSpeakers = true

    /// Scene headings, action, transitions — everything that is not spoken by
    /// someone. Off leaves dialogue alone, which is how an actor runs lines.
    var includesDescription = true

    /// Parentheticals. They are directions to the actor rather than words in
    /// the character's mouth, and hearing "(beat)" read out gets old fast.
    var includesDirections = true

    /// Give each character their own voice, as far as the installed voices
    /// stretch. The narrator keeps the voice that was chosen for the script.
    var usesDistinctVoices = false
}

/// The sort of line a cue is, which is all the narrator needs to know to pace
/// and cast it.
enum NarrationKind: Equatable {
    /// A scene heading or a section — the beat before a new scene.
    case heading
    /// Action, a shot, a transition: the narrator's own voice.
    case description
    /// A speaker's name, announced ahead of their line.
    case cue
    /// Dialogue or lyrics.
    case speech
    /// A parenthetical.
    case direction

    /// The silence in front of this cue, in seconds. A new scene wants air
    /// around it; a line following its own character cue wants almost none.
    var pause: Double {
        switch self {
        case .heading: return 0.7
        case .description: return 0.35
        case .cue: return 0.4
        case .speech: return 0.1
        case .direction: return 0.2
        }
    }

    /// Whether this is somebody speaking, as opposed to the narrator reading
    /// the page. Directions belong to the narrator even though they sit inside
    /// a speech — they are an instruction about the line, not the line.
    var isSpoken: Bool { self == .cue || self == .speech }
}

/// One utterance: the text as it should be said, and where it came from.
struct NarrationCue: Identifiable, Equatable {
    /// Position in the run. The narrator plays by index, and the id is the
    /// index because the same block can produce several cues.
    let index: Int
    /// The element this came from, so the reader can highlight and scroll to it.
    let blockId: Int
    /// Whose line it is, in the script's own spelling; nil for the narrator.
    let speaker: String?
    /// What to say.
    let text: String
    let kind: NarrationKind

    var id: Int { index }
}

enum ScriptNarration {

    // MARK: - Building the run

    /// The script as an ordered run of cues.
    ///
    /// Synopses, notes and page breaks are left out for the same reason the
    /// reader view drops them: they are the writer's marks on the script, not
    /// part of it. Empty elements are skipped too — a blank line has nothing
    /// to say, and an utterance of "" is a stall in the middle of the read.
    static func cues(for blocks: [Block],
                     options: NarrationOptions = NarrationOptions()) -> [NarrationCue] {
        var cues: [NarrationCue] = []
        /// Who is speaking, carried forward from the last character cue: the
        /// dialogue block itself does not name them.
        var speaker: String?

        for block in blocks {
            let type = block.blockType
            switch type {
            case .synopsis, .note, .pageBreak:
                continue

            case .character, .dualDialogue:
                // A cue names the speaker even when it is not itself said, so
                // this runs before the option is consulted.
                let name = cueName(block)
                speaker = name
                guard options.announcesSpeakers, let name else { continue }
                append(&cues, block: block, speaker: name,
                       text: spoken(name, as: type), kind: .cue)

            case .dialogue, .lyrics:
                let who = speaker ?? block.personName
                append(&cues, block: block, speaker: who,
                       text: spoken(block.content ?? "", as: type), kind: .speech)

            case .parenthetical:
                guard options.includesDirections else { continue }
                append(&cues, block: block, speaker: speaker,
                       text: spoken(block.content ?? "", as: type), kind: .direction)

            case .scene, .section:
                // A new scene ends whatever speech was running; the next
                // dialogue in it will have its own cue.
                speaker = nil
                guard options.includesDescription else { continue }
                append(&cues, block: block, speaker: nil,
                       text: spoken(block.content ?? "", as: type), kind: .heading)

            default:
                speaker = nil
                guard options.includesDescription else { continue }
                append(&cues, block: block, speaker: block.personName,
                       text: spoken(block.content ?? "", as: type), kind: .description)
            }
        }
        return cues
    }

    /// Appends unless the text came out empty, numbering as it goes.
    private static func append(_ cues: inout [NarrationCue],
                               block: Block,
                               speaker: String?,
                               text: String,
                               kind: NarrationKind) {
        guard !text.isEmpty else { return }
        cues.append(NarrationCue(index: cues.count,
                                 blockId: block.id,
                                 speaker: speaker,
                                 text: text,
                                 kind: kind))
    }

    /// The speaker a character cue names. The cue's own text is the name, but
    /// a cue picked from the character list can be empty with the name held on
    /// the link instead — the reader view makes the same substitution.
    private static func cueName(_ block: Block) -> String? {
        let content = (block.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty { return content }
        let name = (block.personName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The distinct speakers in a run, in the order they first speak — which
    /// is the order a cast of voices is handed out in.
    ///
    /// Only the cues somebody says count. A description can carry a name too
    /// (the reader labels those), but it is still the narrator reading the
    /// page, so casting a voice for it would spend one of the few available
    /// voices on a character who never speaks.
    static func speakers(in cues: [NarrationCue]) -> [String] {
        var seen: Set<String> = []
        var order: [String] = []
        for cue in cues where cue.kind.isSpoken {
            if let name = cue.speaker, seen.insert(name).inserted { order.append(name) }
        }
        return order
    }

    // MARK: - Saying it

    /// One element's text, as it should be said rather than as it is written.
    static func spoken(_ text: String, as type: BlockType) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        if type == .parenthetical {
            result = strippingParens(result)
        }

        // Shouting first: an all-caps line is spelled out a letter at a time,
        // and every heading, cue and transition in a screenplay is shouted.
        // Lowering the case before expanding keeps the rules below reading as
        // one pass over ordinary text.
        result = unshouted(result)

        switch type {
        case .scene:
            result = expanding(result, Self.sceneAbbreviations)
            // The dashes in a slug line are joints, not punctuation to read.
            // A comma is the pause they are standing in for.
            result = result
                .replacingOccurrences(of: " -- ", with: ", ")
                .replacingOccurrences(of: " - ", with: ", ")
        case .character, .dualDialogue, .dialogue, .lyrics:
            result = expanding(result, Self.cueAbbreviations)
        default:
            break
        }

        // Force markers should already be stripped by the time text is stored,
        // but a leftover would be read as punctuation, so it goes here too.
        // Leading only: a trailing full stop is a sentence ending, and the
        // synthesizer's pause at one is worth keeping.
        while let first = result.first, Self.markers.contains(first) {
            result.removeFirst()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Fountain force markers, as characters that can open a line.
    private static let markers: Set<Character> = [".", "@", ">", "~", "#", "=", "*", "_", " "]

    /// Whether a line is written in the screenplay's shouting case — no
    /// lowercase letters anywhere in it.
    private static func unshouted(_ text: String) -> String {
        text.rangeOfCharacter(from: .lowercaseLetters) == nil ? text.lowercased() : text
    }

    /// A parenthetical's parentheses are how it is set on the page; the words
    /// inside are what is said.
    private static func strippingParens(_ text: String) -> String {
        guard text.hasPrefix("("), text.hasSuffix(")"), text.count > 2 else { return text }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// Longest first: "int./ext." has to be taken before "int.".
    ///
    /// Each expansion keeps a comma where the abbreviation's full stop was.
    /// The stop is what makes a slug line read as "interior. house." rather
    /// than one long noun phrase, and dropping it runs the setting into the
    /// location with no breath between them.
    private static let sceneAbbreviations: [(String, String)] = [
        ("int./ext.", "interior, exterior,"),
        ("ext./int.", "exterior, interior,"),
        ("int/ext.", "interior, exterior,"),
        ("i/e.", "interior, exterior,"),
        ("int.", "interior,"),
        ("ext.", "exterior,"),
        ("est.", "establishing,"),
    ]

    /// The extensions that ride along with a character cue, and the two that
    /// turn up inside dialogue.
    private static let cueAbbreviations: [(String, String)] = [
        ("v.o.", "voice over"),
        ("o.s.", "off screen"),
        ("o.c.", "off camera"),
        ("cont'd", "continued"),
        ("cont\u{2019}d", "continued"),
    ]

    private static func expanding(_ text: String, _ rules: [(String, String)]) -> String {
        rules.reduce(text) { partial, rule in
            partial.replacingOccurrences(of: rule.0,
                                         with: rule.1,
                                         options: [.caseInsensitive])
        }
    }
}
