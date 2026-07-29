//
//  ScriptOutline.swift
//  scripty
//
//  The navigation lists the web app's outline sidebars build from the loaded
//  script: structural outline, characters, locations and songs. Every entry
//  carries the block id to jump to. Pure value type, no UI.
//

import Foundation

/// One row in the structural outline: a scene, section or synopsis.
struct OutlineEntry: Identifiable, Hashable {
    let blockId: Int
    let type: BlockType
    /// Sequential scene number — only SCENE blocks are numbered, the way the
    /// web sidebar numbers them.
    let sceneNumber: Int?
    let preview: String
    let isBookmarked: Bool

    var id: Int { blockId }
}

/// The scene an element falls under: where a bookmarked line, a pinned one or
/// a commented one *is*, which a preview of the line itself never says.
struct OutlineSceneContext: Hashable {
    /// The scene's position in the script, numbered as the outline numbers it.
    let number: Int
    let heading: String
}

/// A speaker, with the cue you land on when you tap it.
struct OutlineCharacter: Identifiable, Hashable {
    let name: String
    let blockId: Int
    let speechCount: Int

    var id: String { name }
}

/// A location parsed out of the scene headings that mention it.
struct OutlineLocation: Identifiable, Hashable {
    let name: String
    let blockId: Int
    let sceneCount: Int

    var id: String { name.uppercased() }
}

/// A run of consecutive LYRICS blocks — the web app calls each run a song and
/// names it after its first line.
struct OutlineSong: Identifiable, Hashable {
    let name: String
    let blockId: Int
    let lineCount: Int

    var id: Int { blockId }
}

/// Everything the outline navigator needs, derived from `[Block]`.
struct ScriptOutline: Equatable {
    var entries: [OutlineEntry] = []
    var characters: [OutlineCharacter] = []
    var locations: [OutlineLocation] = []
    var songs: [OutlineSong] = []

    /// Longer previews are clipped the way the web sidebar clips them.
    private static let previewLimit = 80
    private static let previewClip = 77

    /// The types the web app treats as structure.
    static let structuralTypes: Set<BlockType> = [.scene, .section, .synopsis]

    init() {}

    init(blocks: [Block]) {
        var sceneNumber = 0
        var characterOrder: [String] = []
        var characterFirstBlock: [String: Int] = [:]
        var characterCounts: [String: Int] = [:]
        var locationOrder: [String] = []
        var locationEntries: [String: (name: String, blockId: Int, count: Int)] = [:]
        var songRun: (name: String, blockId: Int, lineCount: Int)?

        for block in blocks {
            let type = block.blockType
            let content = block.content ?? ""

            // A run of lyrics ends as soon as any other element appears.
            if type != .lyrics, let run = songRun {
                songs.append(OutlineSong(name: run.name, blockId: run.blockId, lineCount: run.lineCount))
                songRun = nil
            }

            if Self.structuralTypes.contains(type) {
                var number: Int?
                if type == .scene {
                    sceneNumber += 1
                    number = sceneNumber
                }
                entries.append(OutlineEntry(
                    blockId: block.id,
                    type: type,
                    sceneNumber: number,
                    preview: Self.preview(content),
                    isBookmarked: block.isBookmarked))
            }

            switch type {
            case .scene:
                // Forced headings are written `.INT. HOUSE`; drop the marker
                // before parsing, as the sidebar does.
                var heading = content.replacingOccurrences(of: "\u{00a0}", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if heading.hasPrefix(".") { heading = String(heading.dropFirst()) }
                // The sidebar splits the time of day off at the *first* " - ".
                guard let parsed = SceneHeading(heading, splittingTimeFromEnd: false),
                      !parsed.locationName.isEmpty else { break }
                let key = parsed.locationName.uppercased()
                if var existing = locationEntries[key] {
                    existing.count += 1
                    locationEntries[key] = existing
                } else {
                    locationOrder.append(key)
                    locationEntries[key] = (parsed.locationName, block.id, 1)
                }

            case .character, .dualDialogue:
                // Cue text is the name unless a character record is linked.
                let raw = content.isEmpty ? (block.personName ?? "") : content
                guard let name = ScriptStats.normalizeCharacterName(raw) else { break }
                if characterFirstBlock[name] == nil {
                    characterOrder.append(name)
                    characterFirstBlock[name] = block.id
                }
                characterCounts[name, default: 0] += 1

            case .lyrics:
                if var run = songRun {
                    run.lineCount += 1
                    songRun = run
                } else {
                    songRun = (Self.preview(content), block.id, 1)
                }

            default:
                break
            }
        }

        if let run = songRun {
            songs.append(OutlineSong(name: run.name, blockId: run.blockId, lineCount: run.lineCount))
        }

        characters = characterOrder.compactMap { name in
            guard let blockId = characterFirstBlock[name] else { return nil }
            return OutlineCharacter(name: name, blockId: blockId,
                                    speechCount: characterCounts[name] ?? 0)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        locations = locationOrder.compactMap { key in
            guard let entry = locationEntries[key] else { return nil }
            return OutlineLocation(name: entry.name, blockId: entry.blockId, sceneCount: entry.count)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Which scene each of the given elements sits in.
    ///
    /// Asked for a handful of ids rather than built for the whole script: only
    /// the marked lists need it, and they are short. Elements before the first
    /// scene heading are in no scene and are simply absent from the answer.
    static func sceneContexts(for blockIds: Set<Int>,
                              in blocks: [Block]) -> [Int: OutlineSceneContext] {
        guard !blockIds.isEmpty else { return [:] }
        var contexts: [Int: OutlineSceneContext] = [:]
        var scene: OutlineSceneContext?
        var number = 0
        for block in blocks {
            if block.blockType == .scene {
                number += 1
                scene = OutlineSceneContext(number: number,
                                            heading: preview(block.content ?? ""))
            }
            if blockIds.contains(block.id), let scene {
                contexts[block.id] = scene
            }
        }
        return contexts
    }

    /// Blocks worth showing as bookmarks/pins keep their document order, so
    /// the outline modal can reuse the same preview treatment.
    static func preview(_ content: String) -> String {
        let text = content
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "(Untitled)" }
        guard text.count > previewLimit else { return text }
        return String(text.prefix(previewClip)) + "…"
    }
}
