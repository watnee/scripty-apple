//
//  ScreenplayCover.swift
//  scripty
//
//  The front matter of a script, resolved to what the cover sheet should show.
//  A model rather than a view concern, because two renderers draw it: the page
//  view's cover sheet on screen, and the offline print PDF on paper.
//

import Foundation

/// The rules match the title-page editor's live preview and the web page-view
/// cover: the title falls back to the project name and is set in capitals, and
/// the "written by", version and contact lines each appear only when they carry
/// text. A script with no title at all has no cover, exactly as the web omits
/// the sheet — so this is a failable initialiser rather than a set of optionals.
struct ScreenplayCover: Equatable {
    let title: String
    let writers: String?
    let version: String?
    let contact: String?

    init?(project: Project) {
        let entered = project.screenplayTitle.trimmed
        let raw = entered.isEmpty ? project.title.trimmed : entered
        guard !raw.isEmpty else { return nil }
        title = raw.uppercased()
        writers = project.writers.trimmedOrNil
        version = project.screenplayVersion.trimmedOrNil
        contact = project.contactInfo.trimmedOrNil
    }
}

private extension Optional where Wrapped == String {
    var trimmed: String {
        (self ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedOrNil: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}
