//
//  PageSetup.swift
//  scripty
//
//  Paper, margins and page-number placement — the iPad counterpart of the web
//  app's page-setup dialog and the server's PageSetup.java. The presets and
//  their measurements are the same on both sides so a script paginates
//  identically wherever it is opened, and so the values can be handed to the
//  server's PDF export unchanged.
//

import Foundation

/// Sheet size. Margins are quoted as a fraction of paper *width*, which is how
/// the CSS custom properties express them.
enum PaperSize: String, CaseIterable, Identifiable, Codable {
    case letter
    case a4

    var id: String { rawValue }

    var label: String {
        switch self {
        case .letter: return "US Letter"
        case .a4: return "A4"
        }
    }

    var detail: String {
        switch self {
        case .letter: return "8.5 × 11 in"
        case .a4: return "210 × 297 mm"
        }
    }

    var widthIn: Double {
        switch self {
        case .letter: return 8.5
        case .a4: return 8.2677
        }
    }

    var heightIn: Double {
        switch self {
        case .letter: return 11.0
        case .a4: return 11.6929
        }
    }

    var aspectRatio: Double { widthIn / heightIn }
}

/// The three margin presets. `left` is the binding gutter, which is always the
/// wider edge on a screenplay.
enum MarginPreset: String, CaseIterable, Identifiable, Codable {
    case standard
    case narrow
    case wide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .narrow: return "Narrow"
        case .wide: return "Wide"
        }
    }

    var detail: String {
        switch self {
        case .standard: return "1 in, 1.5 in binding"
        case .narrow: return "0.5 in, 1 in binding"
        case .wide: return "1.25 in, 1.75 in binding"
        }
    }

    var topIn: Double {
        switch self {
        case .standard: return 1.0
        case .narrow: return 0.5
        case .wide: return 1.25
        }
    }

    var rightIn: Double { topIn }
    var bottomIn: Double { topIn }

    var leftIn: Double {
        switch self {
        case .standard: return 1.5
        case .narrow: return 1.0
        case .wide: return 1.75
        }
    }
}

/// Where the page number sits on the sheet.
enum PageNumberPlacement: String, CaseIterable, Identifiable, Codable {
    case topRight = "top-right"
    case topLeft = "top-left"
    case bottomCenter = "bottom-center"
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topRight: return "Top right"
        case .topLeft: return "Top left"
        case .bottomCenter: return "Bottom centre"
        case .none: return "None"
        }
    }
}

struct PageSetup: Codable, Equatable {
    var paper: PaperSize = .letter
    var margins: MarginPreset = .standard
    var pageNumbers: PageNumberPlacement = .topRight

    static let `default` = PageSetup()

    /// Text column left after the margins are taken off, in inches.
    var textWidthIn: Double {
        paper.widthIn - margins.leftIn - margins.rightIn
    }

    var textHeightIn: Double {
        paper.heightIn - margins.topIn - margins.bottomIn
    }

    /// How many 12pt lines fit between the top and bottom margins. Standard
    /// Letter gives the familiar 54.
    var linesPerPage: Int {
        let points = textHeightIn * ScreenplayLayout.pointsPerInch
        return max(1, Int((points / ScreenplayLayout.lineHeightPt).rounded(.down)))
    }

    /// Margins as fractions of paper width, matching `--scripty-page-pad-*`.
    var padTopFraction: Double { margins.topIn / paper.widthIn }
    var padRightFraction: Double { margins.rightIn / paper.widthIn }
    var padBottomFraction: Double { margins.bottomIn / paper.widthIn }
    var padLeftFraction: Double { margins.leftIn / paper.widthIn }

    /// Query items the server's PDF export understands, so an exported page
    /// matches what the writer was just looking at.
    var exportQueryItems: [URLQueryItem] {
        [URLQueryItem(name: "paper", value: paper.rawValue),
         URLQueryItem(name: "margins", value: margins.rawValue)]
    }
}
