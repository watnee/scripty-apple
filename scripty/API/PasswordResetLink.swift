//
//  PasswordResetLink.swift
//  scripty
//
//  Reading the token out of the link in a recovery email.
//
//  The link arrives two ways, and both end up here. Usually iOS hands it over
//  as a universal link, because the app claims that path in the server's site
//  association file — the writer taps the button in Mail and never sees a
//  token at all. The other way is a paste, for the writer whose mail is on a
//  machine that isn't this one; what they have to hand is the whole URL, so
//  that is what this accepts.
//

import Foundation

enum PasswordResetLink {
    /// The path the server sends people to, and the one the app claims.
    static let path = "/forgot-password/reset"

    /// The recovery token in `url`, or nil if that isn't a reset link.
    ///
    /// Deliberately indifferent to the host. The app is pointed at one server
    /// at a time and a token from any other simply won't validate, so checking
    /// would buy nothing and would break the localhost override — where the
    /// email's link points at the dev server by its own name.
    static func token(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https" || components.scheme == "http",
              // Suffix rather than equality: a server behind a context path
              // serves the same page one level down.
              components.path.hasSuffix(path) else { return nil }
        return components.queryItems?
            .first { $0.name == "token" }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    /// The token in whatever was pasted — a whole link, or a bare token typed
    /// out of one.
    ///
    /// A link is the thing to paste, so it is tried first; anything else is
    /// taken at face value, which keeps a writer who picked the token out of
    /// the URL themselves from being told they are wrong.
    static func token(inPasted text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed = trimmed.nonEmpty else { return nil }
        if let url = URL(string: trimmed), let token = token(in: url) {
            return token
        }
        // A URL with no token is a mis-paste, not a token: saying so beats
        // sending the whole link to the server as if it were one.
        guard !trimmed.lowercased().hasPrefix("http") else { return nil }
        return trimmed
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
