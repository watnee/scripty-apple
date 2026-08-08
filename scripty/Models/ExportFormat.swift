//
//  ExportFormat.swift
//  scripty
//
//  What kind of file an export produces, said once for every surface that
//  offers one.
//
//  The rels are per-surface and there are a lot of them: a screenplay's PDF,
//  one song's, the songbook's and the notes file's are four separate rels, and
//  the same is true of Word, EPUB and text. A writer who always wants a PDF
//  means the same thing by it in all four places, so the preference cannot be
//  a rel — it has to be the family the rel belongs to. That family is this.
//
//  Nothing here decides what a menu offers; the server's links still do that.
//  This only says which of the formats already on offer is the one the writer
//  asked to see first.
//

import Foundation

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case pdf
    case word
    case epub
    case text
    case finalDraft = "final-draft"
    case musicXml = "musicxml"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .word: return "Word"
        case .epub: return "EPUB"
        case .text: return "Text"
        case .finalDraft: return "Final Draft"
        case .musicXml: return "MusicXML"
        }
    }

    /// What a writer gets by asking for this format on a surface that does not
    /// offer it — nothing at all, and the menu stands as it was. Worth saying
    /// on the settings screen rather than leaving someone to notice: Final
    /// Draft is a screenplay format, MusicXML a song one.
    var detail: String {
        switch self {
        case .pdf: return "Everywhere"
        case .word: return "Everywhere"
        case .epub: return "Everywhere"
        case .text: return "Fountain for a screenplay, plain text for a song or note"
        case .finalDraft: return "Screenplays only"
        case .musicXml: return "Songs only"
        }
    }

    /// The family a link belongs to, or nil where it belongs to none.
    ///
    /// Text covers two spellings of the same wish: a screenplay's plain-text
    /// format is Fountain, and a song's or a note's is a .txt file. Someone
    /// who wants the words without the layout wants whichever of those the
    /// thing in front of them has.
    ///
    /// The Scripty archive is deliberately absent. It is the whole project in
    /// a bundle — something to move or to keep, not a draft to carry away —
    /// and nobody's standing wish is to find it at the top of the menu.
    init?(rel: Rel) {
        switch rel {
        case .exportPdf, .exportSongPdf, .exportSongsPdf, .exportNotesPdf:
            self = .pdf
        case .exportDocx, .exportSongDocx, .exportSongsDocx, .exportNotesDocx:
            self = .word
        case .exportEpub, .exportSongEpub, .exportSongsEpub, .exportNotesEpub:
            self = .epub
        case .export, .exportSongTxt, .exportSongsTxt, .exportNotesTxt:
            self = .text
        case .exportFdx:
            self = .finalDraft
        case .exportSongMusicXml, .exportSongsMusicXml:
            self = .musicXml
        default:
            return nil
        }
    }
}
