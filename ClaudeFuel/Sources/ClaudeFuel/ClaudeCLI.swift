import Foundation

// Detects whether the Claude Code CLI is installed, so the sign-in flow can offer to install it when
// it's missing (the "sign in via CLI" escape hatch is useless if there's no CLI to sign in with).
//
// A GUI app launched from Finder doesn't inherit the shell's PATH, so we can't just run `which claude`
// and trust an empty result — we check the known install locations directly first, then fall back to a
// login shell (which *does* have the user's PATH) to catch Homebrew/npm/custom installs.
enum ClaudeCLI {
    // Where the supported installers put the binary. The native installer (what we run) uses
    // ~/.local/bin/claude; the others cover Homebrew (Apple silicon / Intel) and npm global.
    static var candidatePaths: [String] {
        [
            "\(NSHomeDirectory())/.local/bin/claude",   // native installer (curl … | bash) — our default
            "/opt/homebrew/bin/claude",                  // Homebrew (Apple silicon)
            "/usr/local/bin/claude",                     // Homebrew (Intel) / npm global
        ]
    }

    // Absolute path to the installed `claude`, or nil if we can't find one.
    static func installedPath() -> String? {
        let fm = FileManager.default
        for p in candidatePaths where fm.isExecutableFile(atPath: p) { return p }
        return loginShellWhich()
    }

    static var isInstalled: Bool { installedPath() != nil }

    // Ask a login shell to resolve `claude`, so a custom PATH (nvm, asdf, a hand-placed launcher) is
    // still found even though this app didn't inherit that PATH from Finder.
    private static func loginShellWhich() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }
}
