import AppKit

// Best-effort crash reporting. We can't reliably draw UI *at* crash time (the process is dying),
// so instead we trap uncaught Obj-C exceptions and fatal signals, write a small report to disk,
// and on the NEXT launch show a "quit unexpectedly last time" screen with the report to copy.
//
// Note: doing Foundation work inside a signal handler isn't strictly async-signal-safe. This is a
// pragmatic best effort — worst case the report doesn't get written and the app just crashes as it
// would have anyway. It never makes a crash worse.
enum CrashReporter {
    // Resolved once, up front (before any crash), so the handlers don't compute paths mid-crash.
    private static let reportURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("TokenFuel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-crash.txt")
    }()

    static func install() {
        _ = reportURL   // force the path to resolve now, while it's safe

        NSSetUncaughtExceptionHandler { exc in
            CrashReporter.save(kind: "Uncaught exception: \(exc.name.rawValue)",
                               reason: exc.reason ?? "", stack: exc.callStackSymbols)
        }

        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                // Re-entrancy guard: if handling this signal itself trips another one, don't loop
                // or overwrite the first (real) report — just let the default handler finish.
                if CrashReporter.handling { signal(s, SIG_DFL); raise(s); return }
                CrashReporter.handling = true
                CrashReporter.save(kind: "Fatal signal \(CrashReporter.signalName(s)) (\(s))",
                                   reason: "", stack: Thread.callStackSymbols)
                signal(s, SIG_DFL); raise(s)      // restore default handler and let it crash for real
            }
        }
    }

    private static var handling = false

    private static func signalName(_ s: Int32) -> String {
        switch s {
        case SIGABRT: return "SIGABRT"; case SIGILL: return "SIGILL"; case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"; case SIGFPE: return "SIGFPE"; case SIGTRAP: return "SIGTRAP"
        default: return "signal"
        }
    }

    private static func save(kind: String, reason: String, stack: [String]) {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let when = ISO8601DateFormatter().string(from: Date())
        var text = """
        Token Fuel — crash report
        Version \(v) (\(b))  •  \(os)
        \(when)

        \(kind)
        """
        if !reason.isEmpty { text += "\nReason: \(reason)" }
        text += "\n\nBacktrace:\n" + stack.joined(separator: "\n") + "\n"
        try? text.write(to: reportURL, atomically: true, encoding: .utf8)
    }

    // Shown on launch if the previous run left a crash report. Clears it once shown.
    static func presentPendingIfNeeded() {
        guard let text = try? String(contentsOf: reportURL, encoding: .utf8), !text.isEmpty else { return }
        try? FileManager.default.removeItem(at: reportURL)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Token Fuel quit unexpectedly last time"
        alert.informativeText = "A crash report was saved. Copy it and share it with the developer "
            + "(via the Discord) so the bug can be fixed. No data leaves your Mac unless you send it."
        alert.addButton(withTitle: "Copy Report")
        alert.addButton(withTitle: "Dismiss")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false; tv.isVerticallyResizable = true
        tv.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.string = text
        scroll.documentView = tv
        alert.accessoryView = scroll

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
