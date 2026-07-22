//
//  ScriptClipboard.swift
//  scripty
//
//  The wire format for elements on the clipboard, shared with the web editor.
//
//  Copying a screenplay element has to carry more than its words: an element
//  pasted back must still be a scene heading or a cue, with its speaker and
//  its tags. The web editor solves this by putting two representations on the
//  clipboard — readable plain text, and a JSON payload under a private type —
//  and this is the same payload, byte for byte, so a scene copied in Safari
//  pastes into the app with its types intact and vice versa.
//
//  There is also a fallback the web falls back to when a browser won't accept
//  a second representation: the JSON hidden inside the plain text between two
//  invisible separators. We never *write* that (a pasteboard here carries as
//  many representations as we like, and a stray marker would follow the text
//  into every other app), but we do read it, since text copied out of such a
//  browser will have it.
//

import Foundation

/// One element as it travels on the clipboard. Every field is a string,
/// matching the web payload exactly — including `personId`, which is empty
/// rather than absent when there is no speaker.
struct ClipboardBlock: Codable, Equatable {
    var type: String
    var content: String
    var personId: String
    var characterName: String
    var tags: String

    init(type: BlockType,
         content: String,
         personId: Int? = nil,
         characterName: String = "",
         tags: String = "") {
        self.type = type.rawValue
        self.content = content
        self.personId = personId.map(String.init) ?? ""
        self.characterName = characterName
        self.tags = tags
    }

    /// Unknown or missing types read as action, the same fallback the block
    /// list makes for a type it doesn't recognise.
    var blockType: BlockType {
        BlockType(rawValue: type.uppercased()) ?? .action
    }

    /// Decoding is lenient on purpose: this payload crosses a version boundary
    /// whenever the two clients are not deployed together, and a missing field
    /// should cost that field rather than the whole paste.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decode(String.self, forKey: .type))?.uppercased() ?? "ACTION"
        content = (try? container.decode(String.self, forKey: .content)) ?? ""
        characterName = (try? container.decode(String.self, forKey: .characterName)) ?? ""
        tags = (try? container.decode(String.self, forKey: .tags)) ?? ""
        // The web writes this as a string, but a server-shaped payload could
        // carry a number; take either rather than losing the speaker.
        if let text = try? container.decode(String.self, forKey: .personId) {
            personId = text
        } else if let number = try? container.decode(Int.self, forKey: .personId) {
            personId = String(number)
        } else {
            personId = ""
        }
    }
}

private struct ScriptClipboardPayload: Codable {
    var version: Int
    var blocks: [ClipboardBlock]
}

enum ScriptClipboard {
    /// The web's private clipboard MIME type, reused verbatim as a pasteboard
    /// type so the two clients recognise each other's copies.
    static let pasteboardType = "application/x-scripty-blocks+json"

    /// U+2063 INVISIBLE SEPARATOR, the fence around the plain-text fallback.
    private static let embedMarker = "\u{2063}"

    // MARK: - Writing

    /// The readable half of a copy: a cue and its speech end up on separate
    /// lines, which is what a paste into any other app should look like.
    static func plainText(_ blocks: [ClipboardBlock]) -> String {
        blocks.map { block in
            block.characterName.isEmpty
                ? block.content
                : block.characterName + "\n" + block.content
        }
        .joined(separator: "\n")
    }

    static func encode(_ blocks: [ClipboardBlock]) -> Data? {
        try? JSONEncoder().encode(ScriptClipboardPayload(version: 1, blocks: blocks))
    }

    // MARK: - Reading

    static func decode(_ data: Data) -> [ClipboardBlock]? {
        guard let payload = try? JSONDecoder().decode(ScriptClipboardPayload.self, from: data),
              !payload.blocks.isEmpty else { return nil }
        return payload.blocks
    }

    /// Pulls a fenced payload back out of plain text, returning the text with
    /// the fence removed. Text without one comes back untouched.
    static func parseEmbedded(_ text: String) -> (text: String, blocks: [ClipboardBlock]?) {
        guard let end = text.range(of: embedMarker, options: .backwards),
              let start = text.range(of: embedMarker, options: .backwards,
                                     range: text.startIndex..<end.lowerBound)
        else { return (text, nil) }

        var plain = String(text[text.startIndex..<start.lowerBound])
        if plain.hasSuffix("\n") { plain.removeLast() }
        let json = String(text[start.upperBound..<end.lowerBound])
        return (plain, json.data(using: .utf8).flatMap(decode))
    }
}
