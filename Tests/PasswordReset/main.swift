//
//  Password reset link parsing
//
//  The magic link is the whole flow now: a tap in Mail opens the app, and what
//  the app gets is a URL it has to find the token in. Getting this wrong fails
//  in the one place it cannot be debugged — on a stranger's phone, holding an
//  email, locked out of their account — so the shapes are pinned here.
//
//  Run via Tests/run.sh.
//

import Foundation

var failures = 0

func check(_ label: String, _ actual: String?, _ expected: String?) {
    if actual == expected {
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label) — expected \(String(describing: expected)), "
            + "got \(String(describing: actual))")
    }
}

let token = "7f3a9c21-5b8e-4d10-a6f2-91cc4e0b7d38"

// MARK: - The link iOS hands over

func checkUniversalLink() {
    print("Universal link:")

    check("the reset link",
          PasswordResetLink.token(in: URL(string:
            "https://scripty.example/forgot-password/reset?token=\(token)")!),
          token)

    // Mail and mail forwarders love adding their own parameters.
    check("token among other query items",
          PasswordResetLink.token(in: URL(string:
            "https://scripty.example/forgot-password/reset?utm_source=mail&token=\(token)")!),
          token)

    // A server behind a context path serves the same page one level down.
    check("under a context path",
          PasswordResetLink.token(in: URL(string:
            "https://scripty.example/scripty/forgot-password/reset?token=\(token)")!),
          token)

    // The site association claims the path only with a token, but nothing stops
    // a hand-typed URL arriving without one.
    check("reset page with no token",
          PasswordResetLink.token(in: URL(string:
            "https://scripty.example/forgot-password/reset")!),
          nil)
    check("token present but empty",
          PasswordResetLink.token(in: URL(string:
            "https://scripty.example/forgot-password/reset?token=")!),
          nil)

    // Every other page on the domain belongs to the browser, and the demo
    // scheme must still reach the demo rather than this.
    check("some other page",
          PasswordResetLink.token(in: URL(string:
            "https://scripty.example/project/show?token=\(token)")!),
          nil)
    check("the demo scheme",
          PasswordResetLink.token(in: URL(string: "scripty://demo")!),
          nil)
}

// MARK: - What a writer pastes

func checkPaste() {
    print("\nPasted:")

    check("the whole link",
          PasswordResetLink.token(inPasted:
            "https://scripty.example/forgot-password/reset?token=\(token)"),
          token)

    // Copying out of a mail client picks up the surrounding whitespace.
    check("link with whitespace around it",
          PasswordResetLink.token(inPasted:
            "  https://scripty.example/forgot-password/reset?token=\(token)\n"),
          token)

    // A writer who picked the token out of the URL themselves is not wrong.
    check("a bare token", PasswordResetLink.token(inPasted: token), token)

    // A link that isn't the reset link is a mis-paste. Sending it on as if it
    // were a token would earn them "invalid token" for a mistake this can name.
    check("a link with no token in it",
          PasswordResetLink.token(inPasted: "https://scripty.example/forgot-password/reset"),
          nil)
    check("some other link",
          PasswordResetLink.token(inPasted: "https://scripty.example/help"),
          nil)
    check("nothing at all", PasswordResetLink.token(inPasted: "   "), nil)
}

checkUniversalLink()
checkPaste()

print()
if failures == 0 {
    print("All password reset link checks passed.")
} else {
    print("\(failures) check(s) failed.")
    exit(1)
}
