//
//  ScriptPagination.swift
//  scripty
//
//  Splits a script into Letter-sized pages, porting the greedy fill in the web
//  app's page-view-mode.js.
//
//  The web version measures rendered DOM rows because a browser has already
//  laid the text out. SwiftUI has not, so this counts instead: Courier at 12pt
//  is exactly ten characters to the inch, which turns each element into a
//  known number of lines and each page into a budget of 54 of them. That is the
//  same arithmetic the server's PDF exporter does, so the two agree, and unlike
//  measurement it is deterministic enough to pin down in tests.
//
//  Two rules from the web carry over because they are what keep pages from
//  looking wrong:
//    * elements bind into indivisible atoms, so a cue never ends a page alone
//      and a scene heading never dangles without a line beneath it;
//    * an atom's leading blank line is shed only when it lands at the top of a
//      page, never mid-page.
//

import Foundation

/// One element of a page: either a script element or a continuation marker the
/// paginator inserted.
///
/// The row carries the line budget the paginator assigned it. The sheet view
/// renders to exactly that budget rather than letting the text find its own
/// height, because otherwise the model and the rendering disagree — SwiftUI
/// lays type out at the font's natural leading, while a screenplay page is
/// reckoned in 12pt lines — and the page fills to the wrong point.
struct PageRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case block(Block)
        /// `(MORE)` closing a speech that runs onto the next page.
        case more
        /// `SPEAKER (CONT'D)` reopening it.
        case continued(speaker: String)
    }

    let id: String
    let kind: Kind
    /// Lines of text this element occupies.
    let lines: Int
    /// Blank lines above it, already shed if it landed at the top of a page.
    let spacing: Int

    var block: Block? {
        if case .block(let block) = kind { return block }
        return nil
    }

    /// Total lines the row consumes on the page.
    var totalLines: Int { lines + spacing }

    static func == (lhs: PageRow, rhs: PageRow) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind
            && lhs.lines == rhs.lines && lhs.spacing == rhs.spacing
    }
}

struct ScriptPage: Identifiable, Equatable {
    /// One-based, and what the page navigator shows.
    let number: Int
    let rows: [PageRow]

    var id: Int { number }
}

/// A script element measured into lines, before it is assigned to a page.
private struct MeasuredRow {
    let block: Block
    let type: BlockType
    /// Wrapped height of the element's own text.
    let lines: Int
    /// Blank lines carried above it.
    let spacing: Int
    /// The cue this row is speaking under, if it is part of a speech.
    let speaker: String?

    var cost: Int { lines + spacing }
}

/// Rows that must not be split across a page boundary.
private struct Atom {
    var rows: [MeasuredRow]
    var forcesBreak: Bool

    /// Cost of the atom, shedding the first row's leading blank line when the
    /// atom starts a page. This asymmetry is what makes screen and print agree.
    func cost(atPageTop: Bool) -> Int {
        rows.enumerated().reduce(0) { total, pair in
            let (index, row) = pair
            return total + row.lines + (index == 0 && atPageTop ? 0 : row.spacing)
        }
    }

    var trailingSpeaker: String? { rows.last?.speaker }
    var leadingSpeaker: String? { rows.first?.speaker }
}

enum ScriptPagination {
    /// Lines reserved for a `(MORE)` when a speech is about to break, and for
    /// the `(CONT'D)` that reopens it overleaf.
    private static let continuationReserve = 1

    static func paginate(blocks: [Block], setup: PageSetup = .default) -> [ScriptPage] {
        let printable = blocks.filter { isPrintable($0.blockType) }
        let measured = measure(blocks: printable, setup: setup)
        guard !measured.isEmpty else { return [] }
        let atoms = buildAtoms(from: measured)
        return fill(atoms: atoms, linesPerPage: setup.linesPerPage)
    }

    /// Outline scaffolding and working annotations do not go to paper. The web
    /// app's print stylesheet hides exactly these three, and they are dropped
    /// before measuring so the page does not reserve room for something it
    /// will not draw.
    static func isPrintable(_ type: BlockType) -> Bool {
        switch type {
        case .section, .synopsis, .note: return false
        default: return true
        }
    }

    // MARK: - Measuring

    private static func measure(blocks: [Block], setup: PageSetup) -> [MeasuredRow] {
        // Scale the standard column if the writer chose a non-standard paper
        // or margin preset, so narrow margins genuinely fit more per line.
        let columnScale = setup.textWidthIn / ScreenplayLayout.textWidthIn
        var speaker: String?

        return blocks.map { block in
            let type = block.blockType
            let text = displayText(for: block, type: type)

            // A cue opens a speech; dialogue and parentheticals continue it;
            // anything else ends it.
            switch type {
            case .character, .dualDialogue:
                speaker = normalisedSpeaker(text)
            case .dialogue, .parenthetical:
                break
            default:
                speaker = nil
            }

            let box = ScreenplayLayout.box(for: type)
            let columns = max(1, Int((Double(box.columns) * columnScale).rounded(.down)))

            return MeasuredRow(
                block: block,
                type: type,
                lines: type == .pageBreak ? 0 : wrappedLineCount(text, columns: columns),
                spacing: type == .pageBreak ? 0 : ScreenplayLayout.spacingLines(for: type),
                speaker: (type == .dialogue || type == .parenthetical) ? speaker : nil)
        }
    }

    /// Character cues fall back to the linked character when their content is
    /// empty, exactly as the row views do.
    private static func displayText(for block: Block, type: BlockType) -> String {
        let content = block.content ?? ""
        if content.isEmpty, type.isCharacterCue, let name = block.personName {
            return name
        }
        return content
    }

    /// A speaker is compared and reprinted uppercased and without any trailing
    /// `(CONT'D)`, so a speech that already continues does not gain a second.
    private static func normalisedSpeaker(_ text: String) -> String? {
        var name = text
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespaces)
            .uppercased() ?? ""
        for suffix in ["(CONT'D)", "(CONT’D)", "(CONTD)"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? nil : name
    }

    /// Greedy word wrap at a fixed column count. An empty element still
    /// occupies its line, and an over-long word is broken rather than allowed
    /// to overhang the column.
    static func wrappedLineCount(_ text: String, columns: Int) -> Int {
        guard columns > 0 else { return 1 }
        var total = 0
        // Hard newlines inside an element start a new line of their own.
        for paragraph in text.components(separatedBy: .newlines) {
            var lines = 1
            var used = 0
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                let length = word.count
                if length > columns {
                    // Break the oversized word across as many lines as it needs.
                    if used > 0 { lines += 1; used = 0 }
                    let full = (length - 1) / columns
                    lines += full
                    used = length - full * columns
                } else if used == 0 {
                    used = length
                } else if used + 1 + length <= columns {
                    used += 1 + length
                } else {
                    lines += 1
                    used = length
                }
            }
            total += lines
        }
        return max(1, total)
    }

    // MARK: - Atoms

    private static func buildAtoms(from rows: [MeasuredRow]) -> [Atom] {
        var atoms: [Atom] = []
        var index = 0

        while index < rows.count {
            let row = rows[index]

            if row.type == .pageBreak {
                atoms.append(Atom(rows: [row], forcesBreak: true))
                index += 1
                continue
            }

            var group = [row]
            index += 1

            switch row.type {
            case .character, .dualDialogue, .parenthetical:
                // Bind forward through the speech, stopping after the first
                // dialogue so a cue can never be stranded at a page foot.
                while index < rows.count {
                    let next = rows[index]
                    guard next.type == .parenthetical || next.type == .dialogue else { break }
                    group.append(next)
                    index += 1
                    if next.type == .dialogue { break }
                }

            case .scene:
                // A heading keeps one line of body with it — no orphan slugs.
                if index < rows.count, rows[index].type != .pageBreak {
                    group.append(rows[index])
                    index += 1
                }

            default:
                break
            }

            atoms.append(Atom(rows: group, forcesBreak: false))
        }

        return atoms
    }

    // MARK: - Filling

    private static func fill(atoms: [Atom], linesPerPage: Int) -> [ScriptPage] {
        var pages: [ScriptPage] = []
        var current: [PageRow] = []
        var used = 0

        func flush() {
            // Pages holding nothing but a forced break carry no content and are
            // dropped, matching the web app's mergeEmptyPages.
            guard !current.isEmpty else { return }
            pages.append(ScriptPage(number: pages.count + 1, rows: current))
            current = []
            used = 0
        }

        for (position, atom) in atoms.enumerated() {
            if atom.forcesBreak {
                flush()
                continue
            }

            let atPageTop = current.isEmpty
            let cost = atom.cost(atPageTop: atPageTop)

            // Reserve room for a `(MORE)` only when this atom would actually
            // leave a speech open — decided from the speaker in effect *after*
            // the atom lands, not the one before it.
            let next = position + 1 < atoms.count ? atoms[position + 1] : nil
            let willBreakSpeech = atom.trailingSpeaker != nil
                && next?.leadingSpeaker != nil
                && atom.trailingSpeaker == next?.leadingSpeaker
            let limit = linesPerPage - (willBreakSpeech ? continuationReserve : 0)

            if !atPageTop && used + cost > limit {
                // Close the page. If we are cutting a speech in half, say so.
                if let speaker = openSpeaker(in: current, continuingInto: atom) {
                    current.append(PageRow(id: "more-\(pages.count + 1)", kind: .more,
                                           lines: continuationReserve, spacing: 0))
                    flush()
                    current.append(PageRow(id: "contd-\(pages.count + 1)",
                                           kind: .continued(speaker: speaker),
                                           lines: continuationReserve, spacing: 0))
                    used = continuationReserve
                } else {
                    flush()
                }
                used += atom.cost(atPageTop: current.isEmpty)
            } else {
                used += cost
            }

            // Only the atom's first row sheds its leading blank, and only when
            // the atom genuinely opened the page — the same asymmetry the cost
            // calculation used, recorded so the view can reproduce it.
            let landedAtTop = current.isEmpty
            for (offset, row) in atom.rows.enumerated() {
                current.append(PageRow(
                    id: "block-\(row.block.id)",
                    kind: .block(row.block),
                    lines: row.lines,
                    spacing: offset == 0 && landedAtTop ? 0 : row.spacing))
            }
        }

        flush()
        return pages
    }

    /// The speaker whose speech spans the break, if the page being closed ends
    /// mid-speech and the incoming atom keeps talking as the same character.
    private static func openSpeaker(in rows: [PageRow], continuingInto atom: Atom) -> String? {
        guard let speaker = atom.leadingSpeaker else { return nil }
        // Walk back over the rows just placed to confirm the same cue is live.
        for row in rows.reversed() {
            guard let block = row.block else { continue }
            switch block.blockType {
            case .dialogue, .parenthetical:
                continue
            case .character, .dualDialogue:
                return normalisedSpeaker(displayText(for: block, type: block.blockType)) == speaker
                    ? speaker : nil
            default:
                return nil
            }
        }
        return nil
    }
}
