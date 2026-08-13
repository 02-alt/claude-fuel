import AppKit
import AVFoundation
import ServiceManagement
import Sparkle
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    // Show our notifications as banners even though we're a menu-bar agent. The refill notification
    // gets the HALO shield-recharge chime (last 2s) played in code, so we return [.banner] without
    // .sound to keep the notification's own fallback sound from doubling up.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.identifier == Notify.refillID {
            SFX.playTail("shield_recharge", seconds: 2)
            completionHandler([.banner])          // no .sound — the chime is the sound
        } else {
            completionHandler([.banner, .sound])
        }
    }

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var deviceVC: DeviceViewController!
    private var miniWindow: NSWindow?
    private var miniDevice: DeviceView?      // the mini player's DeviceView (contentView is a container)
    private var miniGlass: NSView?           // real NSGlassEffectView body (macOS 26+, translucent themes)
    private var popoverGlass: NSView?        // same, for the menu-bar popover
    private var refuelTimer: Timer?                   // drives the menu-bar refill flourish
    // Sparkle auto-updater: checks the appcast and installs updates in place (no re-download/reinstall).
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ n: Notification) {
        CrashReporter.install()          // trap crashes before anything else can throw
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.imagePosition = .imageLeading
            b.target = self
            b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        deviceVC = DeviceViewController()
        deviceVC.onPopout = { [weak self] in self?.toggleMini() }
        deviceVC.device.onShowIntro = { [weak self] in self?.showIntroBubble() }
        popover.contentViewController = deviceVC
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 660)
        popover.delegate = self          // first time it closes, point people at the menu-bar icon

        UNUserNotificationCenter.current().delegate = self
        if Store.shared.notifyOnReset { Notify.requestAuth() }

        AppModel.shared.onUpdate = { [weak self] in self?.refreshUI() }
        AppModel.shared.onRefuel = { [weak self] in self?.playRefuelAnimation() }
        // The on-LCD SIGN IN key (shown when no Claude login is recognized) routes here.
        NotificationCenter.default.addObserver(self, selector: #selector(signInToClaude),
                                               name: .signInRequested, object: nil)
        AppModel.shared.start()
        refreshUI()

        // restore the mini player if it was open before the last relaunch
        if UserDefaults.standard.bool(forKey: "miniOpen") { showMini() }

        DispatchQueue.main.async { [weak self] in
            CrashReporter.presentPendingIfNeeded()      // show last run's crash report, if any
            self?.maybeOfferMoveToApplications()
        }
    }

    private var welcomePopover: NSPopover?

    // The first time the gauge popover is dismissed, point people back at the menu-bar icon so they
    // know where the app went (it has no Dock icon or window). Fires once, then never again.
    func popoverDidClose(_ notification: Notification) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "didShowWelcome"), let button = statusItem.button else { return }
        d.set(true, forKey: "didShowWelcome")
        // let the popover finish closing before anchoring the bubble to the same icon
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.showWelcomeBubble(from: button)
        }
    }

    // Show the intro bubble anchored to the menu-bar icon. Split out so it can be triggered on
    // demand (the Settings → ADMIN tab) as well as on the first popover close.
    func showWelcomeBubble(from button: NSStatusBarButton) {
        let v = AppDelegate.makeWelcomeContent(target: self, action: #selector(dismissWelcome))
        let vc = NSViewController(); vc.view = v
        let pop = NSPopover(); pop.contentViewController = vc; pop.behavior = .transient
        pop.contentSize = v.frame.size
        welcomePopover = pop
        NSApp.activate(ignoringOtherApps: true)
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // Builds the welcome bubble's content view. Shared by the live popover and the headless
    // `--welcome` preview renderer so both stay identical.
    static func makeWelcomeContent(target: AnyObject?, action: Selector?) -> NSView {
        // Apple HIG for onboarding popovers: a short title, one concise line, one clear action —
        // no words that state the obvious. Sized to hug the trimmed copy.
        let W: CGFloat = 244, H: CGFloat = 108
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        let title = NSTextField(labelWithString: "Token Fuel lives up here ↑")
        title.font = .boldSystemFont(ofSize: 13); title.alignment = .center
        title.frame = NSRect(x: 10, y: 74, width: W-20, height: 20)
        v.addSubview(title)

        let body = NSTextField(labelWithString: "Click the icon to open the gauge.")
        body.font = .systemFont(ofSize: 11); body.textColor = .secondaryLabelColor; body.alignment = .center
        body.frame = NSRect(x: 12, y: 50, width: W-24, height: 18)
        v.addSubview(body)

        let btn = NSButton(title: "Got It", target: target, action: action)
        btn.bezelStyle = .rounded; btn.keyEquivalent = "\r"
        btn.frame = NSRect(x: (W-84)/2, y: 12, width: 84, height: 26)
        v.addSubview(btn)
        return v
    }

    @objc private func dismissWelcome() { welcomePopover?.performClose(nil); welcomePopover = nil }

    // ADMIN tab action: close the device popover, then re-show the intro bubble on the menu-bar icon.
    func showIntroBubble() {
        // Mark it shown first so the popover's own close handler doesn't fire a second bubble.
        UserDefaults.standard.set(true, forKey: "didShowWelcome")
        popover.performClose(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, let b = self.statusItem.button else { return }
            self.showWelcomeBubble(from: b)
        }
    }

    // MARK: - First-run: offer to move into /Applications (fixes Gatekeeper + Login Item)
    private func maybeOfferMoveToApplications() {
        let path = Bundle.main.bundlePath
        let inApps = path.hasPrefix("/Applications/")
            || path.hasPrefix((NSHomeDirectory() as NSString).appendingPathComponent("Applications") + "/")
        let translocated = path.contains("/AppTranslocation/")   // ran from a quarantined download
        guard !inApps else { return }
        // Only nag once (unless macOS translocated us, which means it really needs moving).
        if UserDefaults.standard.bool(forKey: "dismissedMovePrompt") && !translocated { return }

        let a = NSAlert()
        a.messageText = "Move Token Fuel to Applications?"
        a.informativeText = """
        It's running from \(translocated ? "a download location" : "outside your Applications folder").

        Because this app isn't notarized yet, macOS may show a security warning the first time \
        (that's why you might have right-clicked → Open), and "Open at Login" can fail. Moving it to \
        Applications fixes both, and future launches won't warn.
        """
        a.addButton(withTitle: "Move to Applications")
        a.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            moveToApplicationsAndRelaunch()
        } else {
            UserDefaults.standard.set(true, forKey: "dismissedMovePrompt")
        }
    }

    private func moveToApplicationsAndRelaunch() {
        let fm = FileManager.default
        let src = Bundle.main.bundleURL
        var destDir = URL(fileURLWithPath: "/Applications")
        if !fm.isWritableFile(atPath: "/Applications") {
            destDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }
        let dest = destDir.appendingPathComponent(src.lastPathComponent)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
            let strip = Process()                               // best-effort: clear quarantine on the copy
            strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            strip.arguments = ["-dr", "com.apple.quarantine", dest.path]
            try? strip.run(); strip.waitUntilExit()
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
            NSWorkspace.shared.openApplication(at: dest, configuration: cfg) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't move the app."
            a.informativeText = "\(error.localizedDescription)\n\nYou can drag it to Applications manually."
            a.runModal()
        }
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { togglePopover(sender) }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil) }
        else {
            deviceVC.device.goHome()
            // Anchor to the visible icon+text (leading-aligned) rather than the padded button
            // bounds, so the beeper is centered under the menu-bar icon + percentage.
            let iconW: CGFloat = sender.image?.size.width ?? 16
            let titleW = sender.attributedTitle.size().width
            let contentW = iconW + 3 + titleW
            let anchor = NSRect(x: 0, y: 0, width: min(contentW, sender.bounds.width), height: sender.bounds.height)
            popover.show(relativeTo: anchor, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            configurePopoverGlass()          // install the real glass once the popover window exists
            // Opening the app on a console theme boots it like a console. startBoot() self-limits to
            // once per launch (an in-memory latch that resets on relaunch), so it won't replay every
            // time you open the popover, but a fresh launch shows it again.
            if Store.shared.theme.console != .none { deviceVC.device.startBoot() }
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        menu.addItem(refresh)
        menu.addItem(withTitle: (miniWindow?.isVisible ?? false) ? "Hide Mini Player" : "Show Mini Player",
                     action: #selector(toggleMiniMenu), keyEquivalent: "m").target = self
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        // Connection status line + a report you can open to diagnose "can't connect to Claude".
        let conn = NSMenuItem(title: "Connection: \(AppModel.shared.connectionShort().capitalized)",
                              action: #selector(connectionReport), keyEquivalent: "")
        conn.target = self
        conn.image = NSImage(systemSymbolName: AppModel.shared.connectionStatus() == .live
                             ? "wifi" : "wifi.exclamationmark",
                             accessibilityDescription: "Connection")
        menu.addItem(conn)
        // Offer in-app sign-in whenever we're not connected because of the login (no token / expired).
        switch AppModel.shared.connectionStatus() {
        case .noToken, .expired:
            let signIn = NSMenuItem(title: "Sign in to Claude…", action: #selector(signInToClaude), keyEquivalent: "")
            signIn.target = self
            signIn.image = NSImage(systemSymbolName: "person.crop.circle.badge.plus", accessibilityDescription: "Sign in")
            menu.addItem(signIn)
        default: break
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Report a Problem…", action: #selector(reportProblem), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Token Fuel", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() { AppModel.shared.reload(forceLive: true) }
    @objc private func toggleMiniMenu() { toggleMini() }

    // In-app sign-in: opens the browser to Claude's OAuth flow, stores the tokens, and refreshes the
    // gauge — no terminal, no `/login`. Shown when the app isn't connected because of the login.
    @objc private func signInToClaude() {
        NSApp.activate(ignoringOtherApps: true)
        OAuthLogin.signIn { [weak self] result in
            // The throttle case gets its own alert with a "sign in via CLI" escape hatch, since that
            // path shares the same credentials and sidesteps the rate-limited in-app token exchange.
            if case .failure(let err) = result,
               case OAuthLogin.LoginError.rateLimited = err {
                self?.showRateLimitedAlert()
                return
            }
            let a = NSAlert()
            switch result {
            case .success:
                a.messageText = "Signed in to Claude"
                a.informativeText = "Token Fuel is connected. Your usage will refresh in a moment."
                AppModel.shared.reload(forceLive: true)
            case .failure(let err):
                a.messageText = "Couldn't sign in"
                a.informativeText = "\(err)"
                a.alertStyle = .warning
            }
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    // Guidance for the known Anthropic OAuth throttle (a 429 on the token exchange): a flow/IP-level
    // rate limit that hits every app signing in to Claude and gets stickier with repeated retries.
    // The alert follows Apple's HIG — a plain-language title and message (no "429"/"CLI" jargon), a
    // preferred default action on the right and a "Not Now" dismissal on the left — and offers the
    // Claude Code path, which shares the same sign-in Token Fuel reads (installing it first if needed).
    private func showRateLimitedAlert() {
        let haveCLI = ClaudeCLI.isInstalled
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = "Claude is temporarily limiting sign-ins"
        let sharedIntro = "Claude’s servers are limiting how often apps can sign in right now. "
            + "It affects every app and usually clears within a few minutes — waiting and trying again "
            + "often works.\n\n"
        a.informativeText = sharedIntro + (haveCLI
            ? "You can also sign in through Claude Code, Anthropic’s companion app, which uses a "
                + "different path. Token Fuel shares that sign-in, so you only have to do it once. "
                + "This opens the Terminal app for you."
            : "Or Token Fuel can set up Claude Code — Anthropic’s companion app — and sign in that way. "
                + "Token Fuel shares that sign-in, so you only have to do it once. This opens the "
                + "Terminal app and does the setup for you.")
        // First button added is the rightmost / default (Return) — Apple’s spot for the preferred action.
        a.addButton(withTitle: haveCLI ? "Sign In with Claude Code…" : "Install Claude Code…")
        a.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { openTerminalForCLILogin() }
    }

    // Opens Terminal to complete sign-in through the CLI. If the CLI is already installed we just launch
    // it so the user can type `/login`; if it's missing we first run Anthropic's official installer,
    // then launch the freshly-installed binary.
    //
    // We do this by writing a `.command` script and opening it, NOT by driving Terminal with AppleScript.
    // AppleScript control of Terminal needs the Automation (Apple Events) permission, and when that
    // hasn't been granted the script silently fails and the user is left staring at an empty Terminal —
    // exactly the "it opened Terminal but did nothing" bug. Opening a `.command` file just launches
    // Terminal with that document (no Apple Events), so it works with no extra permission.
    private func openTerminalForCLILogin() {
        let script: String
        if ClaudeCLI.isInstalled {
            // Use the resolved absolute path so it runs even if the CLI's dir isn't on Terminal's PATH.
            let claude = ClaudeCLI.installedPath() ?? "claude"
            script = """
                #!/bin/bash
                echo 'Launching Claude Code — type  /login  below to sign in.'
                exec "\(claude)"
                """
        } else {
            // Install first, then launch the freshly-installed binary by full path (~/.local/bin/claude
            // is where the native installer puts it) — the updated PATH isn't active in this same shell.
            script = """
                #!/bin/bash
                echo 'Installing Claude Code (Anthropic official installer)…'
                if ! curl -fsSL https://claude.ai/install.sh | bash; then
                  echo; echo 'Install failed — check your internet connection, then reopen this from Token Fuel.'
                  echo 'Press any key to close.'; read -n 1; exit 1
                fi
                echo; echo '--- Claude Code installed. Launching sign-in — type  /login  below. ---'
                exec "$HOME/.local/bin/claude"
                """
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TokenFuel-signin.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)   // Terminal is the default handler for .command — no Automation prompt
        } catch {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }

    @objc private func checkForUpdates() { updater.checkForUpdates(nil) }

    @objc private func reportProblem() {
        // Copy a short diagnostic (version + connection status + last crash, if any) and open the tracker.
        var diag = "Token Fuel \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
            + " • \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
        diag += AppModel.shared.connectionReport()
        let crash = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TokenFuel/last-crash.txt")
        if let crash, let text = try? String(contentsOf: crash, encoding: .utf8) { diag += "\n\n" + text }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diag, forType: .string)
        if let url = URL(string: "https://github.com/02-alt/claude-fuel/issues/new") { NSWorkspace.shared.open(url) }
    }

    // A human-readable "why can't it connect to Claude?" report. Shows the live-connection status
    // and how to fix it, with buttons to re-check now or copy the details for a bug report.
    @objc private func connectionReport() {
        let m = AppModel.shared
        let report = m.connectionReport()
        let a = NSAlert()
        a.messageText = m.connectionStatus() == .live ? "Connected to Claude" : "Can't connect to Claude"
        a.informativeText = report
        a.alertStyle = m.connectionStatus() == .live ? .informational : .warning
        // When the problem is the login, lead with the one-click fix.
        let offerSignIn = m.connectionStatus() == .noToken || m.connectionStatus() == .expired
        if offerSignIn { a.addButton(withTitle: "Sign in to Claude…") }
        a.addButton(withTitle: "Recheck Now")
        a.addButton(withTitle: "Copy Report")
        a.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        let response = a.runModal()
        if offerSignIn, response == .alertFirstButtonReturn { signInToClaude(); return }
        // Without the sign-in button the remaining buttons shift up by one slot.
        let recheck = offerSignIn ? NSApplication.ModalResponse.alertSecondButtonReturn : .alertFirstButtonReturn
        let copy    = offerSignIn ? NSApplication.ModalResponse.alertThirdButtonReturn  : .alertSecondButtonReturn
        switch response {
        case recheck:
            AppModel.shared.reload(forceLive: true)     // re-fetch; the status line updates next open
        case copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        default: break
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change “Open at Login.”"
            a.informativeText = "Move Token Fuel to your Applications folder and try again.\n\n(\(error.localizedDescription))"
            a.runModal()
        }
    }

    private func refreshUI() {
        let st = AppModel.shared.state, theme = Store.shared.theme
        popover.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        deviceVC.device.update(state: st, theme: theme)
        miniDevice?.update(state: st, theme: theme)
        // The PS2 power-on is NOT replayed on theme switch anymore — that fired the boot (and its
        // chime) while you were still cycling themes in Setup. It now plays when you press Back to the
        // main screen after picking PS2 (see DeviceView's settings "back" handler).
        configureMiniGlass(); configurePopoverGlass()   // react to theme changes (glass body)
        if let b = statusItem.button {
            if refuelTimer == nil {                             // don't stomp the flourish (icon + text)
                b.image = Self.statusIcon(fraction: st.fraction)
                // Don't resize the menu-bar text while the popover is open: the status item is
                // variable-length, so a width change (e.g. the 0% "↻countdown" ticking each second)
                // resizes the button and drags the anchored popover sideways. Freeze the readout
                // until it closes; the fixed-size icon still updates.
                if !popover.isShown { setStatusTitle(Self.percentReadout(st), alpha: 1) }
            }
            b.setAccessibilityLabel("Claude Token Fuel")
            b.setAccessibilityValue(Self.a11yReadout(st))
        }
    }

    // Menu-bar "topping up" flourish, played once when the tank refills. The fuel rises from empty to
    // the live level with an eased fill and a bright green glint, then a brief glow lingers before
    // handing the icon back to refreshUI. Purely cosmetic; safe if it overlaps a real update.
    private func playRefuelAnimation() {
        guard statusItem.button != nil else { return }
        refuelTimer?.invalidate()
        // 1) morph the current readout (e.g. "34%") INTO "Tokens back!", then run the fill, then
        //    morph back to the live readout. Both title transitions are the same crossfade.
        let fromText = Self.percentReadout(AppModel.shared.state)
        crossfadeTitle(from: fromText, to: "Tokens back!", duration: 0.55) { [weak self] in
            self?.runRefuelFill()
        }
    }

    // Middle of the flourish: "Tokens back!" holds while the tank fills empty→full with a fading
    // green glow, then the title crossfades back to the live % / countdown.
    private func runRefuelFill() {
        let target = max(0.5, AppModel.shared.state.fraction)   // where the tank settles (≈full)
        setStatusTitle("Tokens back!", alpha: 1)
        let start = Date(), duration = 1.6
        refuelTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] t in
            guard let self, let b = self.statusItem.button else { t.invalidate(); return }
            let p = min(1, Date().timeIntervalSince(start) / duration)
            if p >= 1 {
                t.invalidate()
                self.crossfadeTitle(from: "Tokens back!",
                                    to: Self.percentReadout(AppModel.shared.state),
                                    duration: 0.55) { [weak self] in
                    self?.refuelTimer = nil
                    self?.refreshUI()                          // back to the live icon + %
                }
                return
            }
            let fp = min(1, p / 0.7)
            let fill = target * (1 - pow(1 - fp, 3))            // ease-out rise
            let glow = pow(1 - fp, 1.5)                         // bright at first, fades out
            b.image = Self.statusIcon(fraction: fill, highlight: glow)
        }
        RunLoop.main.add(refuelTimer!, forMode: .common)
    }

    // Crossfade the menu-bar text from one string to another: `old` fades out to nothing, the string
    // is swapped at zero opacity (so the differing widths don't pop), then `new` fades in. Reads as
    // one label morphing into the other rather than a hard cut. Drives `refuelTimer` so refreshUI
    // won't stomp it mid-transition.
    private func crossfadeTitle(from old: String, to new: String, duration: TimeInterval,
                                completion: @escaping () -> Void) {
        let start = Date()
        refuelTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] t in
            guard let self, self.statusItem.button != nil else { t.invalidate(); return }
            let p = min(1, Date().timeIntervalSince(start) / duration)
            if p < 0.5 { self.setStatusTitle(old, alpha: CGFloat(1 - p / 0.5)) }            // fade out
            else       { self.setStatusTitle(new, alpha: CGFloat((p - 0.5) / 0.5)) }        // fade in
            if p >= 1 { t.invalidate(); completion() }
        }
        RunLoop.main.add(refuelTimer!, forMode: .common)
    }

    // Sets the menu-bar text with a given opacity (labelColor adapts to a light/dark menu bar).
    private func setStatusTitle(_ text: String, alpha: CGFloat) {
        guard let b = statusItem.button else { return }
        let font = b.font ?? NSFont.menuBarFont(ofSize: 0)
        // Resolve the adaptive label colour in the *menu bar's* appearance (dark bar → white text).
        // A raw dynamic labelColor would resolve in the app's aqua appearance and come out black.
        var base = NSColor.labelColor
        b.effectiveAppearance.performAsCurrentDrawingAppearance {
            base = NSColor.labelColor.usingColorSpace(.sRGB) ?? base
        }
        let color = base.withAlphaComponent(max(0, min(1, alpha)))
        b.attributedTitle = NSAttributedString(string: " " + text,
                                               attributes: [.font: font, .foregroundColor: color])
    }

    private func toggleMini() {
        if let w = miniWindow, w.isVisible { hideMini() } else { showMini() }
    }

    private func showMini() {
        let d = UserDefaults.standard
        if miniWindow == nil {
            let miniSize = NSSize(width: 264, height: 377)
            let dev = DeviceView(frame: NSRect(origin: .zero, size: miniSize))
            dev.compact = true
            dev.onClose = { [weak self] in self?.hideMini() }
            dev.update(state: AppModel.shared.state, theme: Store.shared.theme)
            dev.autoresizingMask = [.width, .height]
            miniDevice = dev
            // The mini player's content is a container so a real NSGlassEffectView body can sit
            // *behind* the (transparent) DeviceView, which then only paints the bezel/LCD/screws.
            let container = NSView(frame: NSRect(origin: .zero, size: miniSize))
            container.addSubview(dev)
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: miniSize),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = container
            w.isOpaque = false; w.backgroundColor = .clear
            // Keep the mini screen above everything, including other apps' floating
            // windows. .statusBar sits above .floating/.modalPanel so it stays on top.
            w.level = .statusBar
            // DeviceView handles dragging itself (via performDrag) so a plain click can be a tap
            // on the close button or the screen instead of being swallowed by a window move.
            w.hasShadow = true; w.isMovableByWindowBackground = false
            // .fullScreenAuxiliary lets it stay visible over full-screen apps too.
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.delegate = self
            if d.object(forKey: "miniX") != nil {   // restore last position
                w.setFrameOrigin(NSPoint(x: d.double(forKey: "miniX"), y: d.double(forKey: "miniY")))
            } else if let screen = NSScreen.main {
                let f = screen.visibleFrame
                w.setFrameOrigin(NSPoint(x: f.maxX - miniSize.width - 24, y: f.maxY - miniSize.height - 24))
            }
            miniWindow = w
        }
        configureMiniGlass()
        miniWindow?.orderFront(nil)
        d.set(true, forKey: "miniOpen")
        popover.performClose(nil)
    }

    private func configureMiniGlass() { if let dev = miniDevice { installGlass(behind: dev, &miniGlass) } }

    private func configurePopoverGlass() {
        installGlass(behind: deviceVC.device, &popoverGlass)
        // Let the popover window show the desktop so its glass can sample it.
        if popoverGlass != nil, let win = deviceVC.device.window {
            win.isOpaque = false; win.backgroundColor = .clear
        }
    }

    // Adds/updates a real macOS 26 Liquid Glass body behind `dev` (which then paints only the
    // bezel/screen) for translucent themes; removes it (falling back to the painted CG body)
    // otherwise. Shared by the mini player and the popover. Safe to call repeatedly.
    private func installGlass(behind dev: DeviceView, _ slot: inout NSView?) {
        guard let container = dev.superview else { return }
        dev.frame = container.bounds
        let theme = Store.shared.theme
        var wantGlass = theme.translucent
        if #available(macOS 26.0, *) {} else { wantGlass = false }

        guard wantGlass, #available(macOS 26.0, *) else {          // no real glass → paint the body
            slot?.removeFromSuperview(); slot = nil
            dev.externalGlassBody = false; dev.needsDisplay = true
            return
        }
        let (frame, corner) = dev.externalGlassFrame()
        let glass: NSGlassEffectView
        if let existing = slot as? NSGlassEffectView {
            glass = existing
        } else {
            glass = NSGlassEffectView(frame: frame)
            glass.contentView = GlassPCBInlay(frame: NSRect(origin: .zero, size: frame.size))
            container.addSubview(glass, positioned: .below, relativeTo: dev)
            slot = glass
        }
        glass.frame = frame
        glass.cornerRadius = corner
        glass.tintColor = theme.lcdGlow.withAlphaComponent(0.18)
        if let inlay = glass.contentView as? GlassPCBInlay {
            inlay.frame = NSRect(origin: .zero, size: frame.size)
            inlay.corner = corner
            inlay.theme = theme
            inlay.needsDisplay = true
        }
        dev.externalGlassBody = true; dev.needsDisplay = true
    }

    private func hideMini() {
        miniWindow?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: "miniOpen")
    }

    func windowDidMove(_ n: Notification) {
        guard let w = n.object as? NSWindow, w === miniWindow else { return }
        let o = w.frame.origin
        UserDefaults.standard.set(Double(o.x), forKey: "miniX")
        UserDefaults.standard.set(Double(o.y), forKey: "miniY")
    }

    // Smooth green → orange → red as the tank drains. Interpolates HUE (red 4° → orange 32°
    // → green 135°) so the mid-tones stay vivid instead of going muddy/olive.
    static func fuelColor(_ fraction: Double) -> NSColor {
        let f = max(0, min(1, fraction))
        let hue: CGFloat = f >= 0.5 ? 32 + CGFloat((f-0.5)/0.5) * (135-32)
                                    :  4 + CGFloat(f/0.5) * (32-4)
        return NSColor(hue: hue/360, saturation: 0.85, brightness: 0.92, alpha: 1)
    }

    // A round "fuel tank" that fills to the session fraction and recolours as it drains.
    // Drawn with a resolution-independent handler so it stays crisp on any display.
    // `highlight` (0…1) brightens the tank during the refuel flourish: a stronger surface glint and
    // a soft green glow ring around the tank. 0 = the normal resting icon.
    static func statusIcon(fraction: Double, highlight: Double = 0) -> NSImage {
        let f = max(0, min(1, fraction))
        let hl = max(0, min(1, highlight))
        let color = fuelColor(f)
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let dia: CGFloat = 13
            let c = CGRect(x: (rect.width-dia)/2, y: (rect.height-dia)/2, width: dia, height: dia)
            if hl > 0 {                                            // soft glow behind the tank
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 3 * hl, color: fuelColor(1).withAlphaComponent(0.9 * hl).cgColor)
                ctx.setFillColor(fuelColor(1).withAlphaComponent(0.001).cgColor)
                ctx.fillEllipse(in: c)
                ctx.restoreGState()
            }
            // fluid, clipped to the circle
            ctx.saveGState()
            ctx.addEllipse(in: c); ctx.clip()
            ctx.setFillColor(NSColor.tertiaryLabelColor.withAlphaComponent(0.16).cgColor)
            ctx.fill(c)                                             // faint "empty" tank tint
            let h = c.height * CGFloat(f)
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: c.minX, y: c.minY, width: c.width, height: h))
            if f > 0.03 && f < 0.99 {                              // liquid surface highlight
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.4 + 0.55 * hl).cgColor)
                ctx.fill(CGRect(x: c.minX, y: c.minY + h - (0.75 + hl), width: c.width, height: 0.75 + hl))
            }
            ctx.restoreGState()
            // tank ring (adapts to light/dark menu bar; glows green during the flourish)
            let ring = hl > 0 ? fuelColor(1).blended(withFraction: 1 - hl, of: .labelColor) ?? .labelColor
                              : NSColor.labelColor
            ctx.setStrokeColor(ring.withAlphaComponent(0.55 + 0.35 * hl).cgColor)
            ctx.setLineWidth(1.3)
            ctx.strokeEllipse(in: c.insetBy(dx: 0.65, dy: 0.65))
            return true
        }
        img.isTemplate = false
        return img
    }

    // Spoken by VoiceOver on the menu-bar item.
    static func a11yReadout(_ s: GaugeState) -> String {
        let sess = Int((s.fraction * 100).rounded())
        var p = ["Session \(sess) percent left"]
        if let r = s.resetSeconds { p.append("resets in \(fmtLong(r))") }
        if let wf = s.weekFraction { p.append("weekly \(Int((wf * 100).rounded())) percent left") }
        return p.joined(separator: ", ")
    }

    // Menu-bar text: session%, plus weekly% only if the user enabled "MENU 7D" in Setup.
    // When the session tank is empty, show the refill countdown (↻) instead of "0%".
    static func percentReadout(_ s: GaugeState) -> String {
        let sess = Int((s.fraction * 100).rounded())
        let sessStr: String
        if sess <= 0, let r = s.resetSeconds {
            sessStr = "↻" + shortClock(r)
        } else {
            sessStr = "\(sess)%"
        }
        if Store.shared.menuWeekly, let wf = s.weekFraction {
            return "\(sessStr) · \(Int((wf * 100).rounded()))%"
        }
        return sessStr
    }

    private static func shortClock(_ secs: Int) -> String {
        let h = secs/3600, m = (secs%3600)/60
        if h > 0 { return "\(h):\(String(format: "%02d", m))" }     // 3:10
        return "\(m):\(String(format: "%02d", secs%60))"           // 12:04
    }
}

// Robustly locate a bundled resource WITHOUT `Bundle.module`, which fatalErrors (SIGTRAP) if it
// can't find its SwiftPM sub-bundle — that crashed the app on some machines. This returns nil on
// failure so callers can fall back gracefully instead of the whole app dying.
enum Res {
    static func url(_ name: String, _ ext: String) -> URL? {
        // 1. flattened directly into the app's Resources (how build_app.sh ships them) — most robust
        if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
        // 2. SwiftPM resource sub-bundle (used by `swift run` and headless previews)
        let sub = "ClaudeFuel_ClaudeFuel.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            if let b = Bundle(url: base.appendingPathComponent(sub)),
               let u = b.url(forResource: name, withExtension: ext) { return u }
        }
        return nil
    }
    // Locate a bundled sound by name, trying the formats we ship (trimmed clips are .m4a).
    static func sound(_ name: String) -> URL? {
        for ext in ["m4a", "mp3", "caf", "aiff"] { if let u = url(name, ext) { return u } }
        return nil
    }
}

// Console startup jingles played when the PS2 / Xbox emblem is clicked. Kept at a low volume so
// it's a small easter egg, not a jump-scare. Sounds are cached and retained so playback survives.
enum SFX {
    private static var cache: [String: NSSound] = [:]
    static func play(_ name: String, volume: Float = 0.2) {
        let snd: NSSound
        if let c = cache[name] {
            snd = c
        } else if let url = Res.sound(name),
                  let s = NSSound(contentsOf: url, byReference: true) {
            cache[name] = s; snd = s
        } else { return }
        snd.stop()                     // restart cleanly if it's already playing
        snd.volume = volume
        snd.play()
    }

    // Stop a cached sound mid-playback (used when the console boot is skipped).
    static func stop(_ name: String) { cache[name]?.stop() }

    // Plays just the last `seconds` of a sound (used for the shield-recharge tail on refill).
    // Uses AVAudioPlayer because it can seek; retained so it isn't deallocated mid-playback.
    private static var tailPlayer: AVAudioPlayer?
    static func playTail(_ name: String, seconds: Double, volume: Float = 0.35) {
        guard let url = Res.sound(name), let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.volume = volume
        p.prepareToPlay()
        p.currentTime = max(0, p.duration - seconds)
        tailPlayer = p
        p.play()
    }
}

// The circuit board shown faintly *inside* the real Liquid Glass body (its contentView), so the
// device keeps its "clear case over a PCB" identity while the glass live-refracts the desktop.
final class GlassPCBInlay: NSView {
    var theme: Theme = .noir
    var corner: CGFloat = 28
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let clip = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        ctx.addPath(clip); ctx.clip()
        if let art = DeviceView.pcbArt {
            ctx.saveGState()
            ctx.setAlpha(0.5)                                  // faint — the glass/desktop stays dominant
            ctx.translateBy(x: 0, y: rect.height); ctx.scaleBy(x: 1, y: -1)   // draw the board upright
            ctx.draw(art, in: rect)
            ctx.restoreGState()
        }
        // a whisper of theme colour so each translucent theme still reads as its own hue
        ctx.setFillColor(theme.lcdGlow.withAlphaComponent(0.12).cgColor); ctx.fill(rect)
    }
}

final class DeviceViewController: NSViewController {
    let device = DeviceView(frame: NSRect(x: 0, y: 0, width: 360, height: 660))
    var onPopout: (() -> Void)?
    override func loadView() {
        device.onPopout = { [weak self] in self?.onPopout?() }
        // Wrap in a container so a real NSGlassEffectView can sit behind the (transparent) device.
        let container = NSView(frame: device.frame)
        device.frame = container.bounds
        device.autoresizingMask = [.width, .height]
        container.addSubview(device)
        view = container
    }
}
