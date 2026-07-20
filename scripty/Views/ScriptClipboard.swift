//
//  ScriptClipboard.swift
//  scripty
//
//  Carrying screenplay elements on the system pasteboard.
//
//  Two representations go on at once. Scripty's own type keeps the element
//  types exactly, so copying a speech and pasting it elsewhere in the app
//  reproduces the cue as a cue rather than re-guessing it. Plain Fountain text
//  rides alongside for everything else — Mail, Notes, another editor — and is
//  also what we fall back to reading when the text came from somewhere else.
//
//  The web app achieves the same thing with a custom clipboard payload on a
//  DOM selection. The payload is what transplants; the selection is not, since
//  every element here is a separate text view and a selection cannot span
//  them. Selection mode is the equivalent, and is where Copy lives.
//

import Foundation
import UIKit

enum ScriptClipboard {

    /// A UTI of our own, so only Scripty reads it. Nothing else claims it, and
    /// a stale payload from an older build simply fails to decode and falls
    /// through to the text representation.
    static let elementsType = "app.scripty.elements"

    private struct Payload: Codable {
        let type: String
        let content: String
    }

    // MARK: - Writing

    /// Put `elements` on the pasteboard as both Scripty elements and Fountain.
    static func copy(_ elements: [FountainElement]) {
        let text = FountainScript.fountain(from: elements)
        var item: [String: Any] = [UTType.plainText: text]
        if let data = try? JSONEncoder().encode(
            elements.map { Payload(type: $0.type.rawValue, content: $0.content) }) {
            item[elementsType] = data
        }
        UIPasteboard.general.items = [item]
    }

    // MARK: - Reading

    /// What is on the pasteboard, if it is worth pasting as elements.
    ///
    /// Returns nil for ordinary text — a sentence copied from a browser should
    /// land in the element the caret is in, the way any other paste does.
    /// Only our own payload, or text that actually carries screenplay
    /// structure, earns the right to create rows.
    static func elements() -> [FountainElement]? {
        let board = UIPasteboard.general

        if let data = board.data(forPasteboardType: elementsType),
           let payloads = try? JSONDecoder().decode([Payload].self, from: data) {
            let elements = payloads.map {
                FountainElement(type: BlockType(rawValue: $0.type) ?? .action,
                                content: $0.content)
            }
            if !elements.isEmpty { return elements }
        }

        guard let text = board.string, FountainScript.looksLikeScreenplay(text) else {
            return nil
        }
        return FountainScript.parse(text)
    }

    /// Whether a paste right now would create elements rather than insert text.
    ///
    /// Reads the pasteboard, so iOS may show its "allow paste?" prompt. Only
    /// call this in response to the writer actually asking to paste, where
    /// that prompt is expected — never to decide whether to draw a control.
    static var holdsElements: Bool { elements() != nil }

    /// Whether there is *anything* worth offering a paste for, answered
    /// without reading the pasteboard and so without prompting.
    ///
    /// `contains(pasteboardTypes:)` and `hasStrings` report shape rather than
    /// contents, which iOS treats as non-private. This is deliberately looser
    /// than `holdsElements`: a menu that quietly nags for pasteboard access
    /// every time it opens is worse than one that occasionally offers a paste
    /// that turns out to be a single element.
    static var mayHoldElements: Bool {
        let board = UIPasteboard.general
        return board.contains(pasteboardTypes: [elementsType]) || board.hasStrings
    }

    /// The pasteboard's plain text, for the fallback path where it turned out
    /// not to be a screenplay after all.
    static func plainText() -> String? {
        guard let text = UIPasteboard.general.string else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Spelled out rather than importing UniformTypeIdentifiers for one constant.
private enum UTType {
    static let plainText = "public.utf8-plain-text"
}
