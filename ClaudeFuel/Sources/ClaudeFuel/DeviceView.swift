import AppKit
import CoreImage
import QuartzCore

enum Screen { case gauge, stats, settings }

extension Notification.Name {
    // Posted when the user taps SIGN IN on the "not connected" panel; AppDelegate runs the OAuth flow.
    static let signInRequested = Notification.Name("TokenFuel.signInRequested")
}

// The silver "beeper": machined-metal body, a high-res dot-matrix LCD that shows the
// gauge / stats / settings pages, and three soft-key buttons whose labels change per page.
final class DeviceView: NSView {

    var state = GaugeState()
    var theme = Theme.noir
    var compact = false { didSet { setupCompactChrome() } }

    var onPopout: (() -> Void)?     // opens the floating mini-player
    var onClose: (() -> Void)?      // dismisses the floating mini-player (compact close button)
    var onShowIntro: (() -> Void)?  // ADMIN tab: re-show the first-run "look up here ↑" bubble

    // When true, the translucent body is NOT painted here — a real macOS 26 NSGlassEffectView
    // behind this view provides it (see AppDelegate mini-player setup).
    var externalGlassBody = false

    private var closeButton: MiniCloseButton?

    // navigation state (in-screen menus)
    private var screen: Screen = .gauge
    private var statsPage = 0
    private var settingsSel = 0
    private var settingsPage = 0            // 0 = SETUP rows, 1 = REPORT (connection diagnostics)
    private var reportPressed: Int? = nil   // which on-screen REPORT button is held (0 recheck, 1 copy)
    private var signInPressed = false       // the "not signed in" panel's SIGN IN key is held

    // True once we've actually confirmed there's no usable Claude login (no token, or expired and the
    // silent refresh failed). Excludes the pre-fetch "unknown" state so the panel never flashes on launch.
    private var needsSignIn: Bool {
        if forceSignIn { return true }
        switch AppModel.shared.connectionStatus() {
        case .noToken, .expired: return true
        default: return false
        }
    }
    private func signInButtonAt(_ p: CGPoint) -> Bool { gridRectToDesign(SignInUI.button).contains(p) }
    private var copiedUntil: CFTimeInterval = 0   // COPIED-to-clipboard toast expiry

    private let gridW = 120, gridH = 176

    private var displayFraction = 1.0
    private var animFrame = 0
    private var pressed: Int? = nil
    private var btnFlash: [CGFloat] = [0, 0, 0]   // per-key depression: snaps down on press, springs back (can pop <0) on release
    private var btnVel:   [CGFloat] = [0, 0, 0]   // spring velocity per key, so the release overshoots and settles like a real key
    private var buttonRects: [CGRect] = []
    private var lcdRectDesign: CGRect = .zero    // screen area, for tap-to-toggle large print
    private var emblemRectDesign: CGRect = .zero // bottom logo hit area (PS2/Xbox startup-sound easter egg)
    private var anim: Timer?

    private var bootStart: CFTimeInterval = 0            // console power-on anim start (0 = idle)
    private var bootSeam = false                         // Odradek: this boot rolled the rare Seam intro
    // Each console's boot matches its startup clip: ps2_startup (9.0s) vs the trimmed xbox_startup (7.3s).
    // Odradek: the scanner boot syncs to its ~2.4s chime; the rare Seam repatriation runs longer.
    private var bootDuration: CFTimeInterval { theme.console == .xbox ? 7.3 : theme.odradek ? (bootSeam ? 3.9 : 2.4) : 9.0 }
    private let bootFadeIn: CFTimeInterval = 1.2      // after the boot resolves to black, fade the LCD UI up
    private var bootTotal: CFTimeInterval { bootDuration + bootFadeIn }
    private var bootActive: Bool { bootStart > 0 }
    private var themeIDOnSettingsEnter: String?         // theme when Setup was opened → boot on Back if it changed
    private var bootPlayedThisLaunch = false            // boot plays once per app launch; resets on relaunch

    private var designSize: CGSize { compact ? CGSize(width: 280, height: 400) : CGSize(width: 360, height: 660) }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        anim = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in self?.tick() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { anim?.invalidate() }

    func seedNeedle(_ f: Double) { displayFraction = f }
    func update(state: GaugeState, theme: Theme) {
        self.state = state; self.theme = theme
        closeButton?.theme = theme; closeButton?.needsDisplay = true
        needsDisplay = true
    }
    func goHome() { screen = .gauge; settingsPage = 0; needsDisplay = true }

    // Plays the current console's power-on on the LCD — the PS2 orbs→ring→dissolve, or the original
    // Xbox energy-swirl→sphere→XBOX — synced with that console's startup chime. No-op off a console
    // theme or under Reduce Motion / accessibility: the boot is pure motion, so those users just get
    // the Browser straight away.
    // `force` = the user explicitly asked for it (applied a console theme, tapped the emblem) — always
    // replay. Without force it's the automatic first-open trigger, which plays at most once per launch.
    func startBoot(force: Bool = false) {
        guard theme.console != .none || theme.odradek, !reduceMotion, !theme.a11y else { return }
        // No usable Claude login → the .gauge screen shows the sign-in panel, not the console boot
        // (see draw()). Don't fire the startup chime behind it — the boot plays once they're signed in.
        if needsSignIn { return }
        if !force && bootPlayedThisLaunch { return }
        bootPlayedThisLaunch = true
        bootStart = CACurrentMediaTime()
        // Odradek: 1-in-15 boots play the rare silent "Seam" repatriation; the rest are the scanner.
        bootSeam = theme.odradek && Int.random(in: 0..<15) == 0
        if theme.odradek { SFX.play(bootSeam ? "seam_boot" : "odradek_boot", volume: bootSeam ? 0.14 : 0.2) }
        else if theme.console != .none { SFX.play(theme.console == .xbox ? "xbox_startup" : "ps2_startup") }
        screen = .gauge
        needsDisplay = true
    }

    // Click anywhere during the boot to skip it: stop the chime and jump straight to the LCD UI.
    private func skipBoot() {
        guard bootActive else { return }
        bootStart = 0
        SFX.stop(theme.odradek ? (bootSeam ? "seam_boot" : "odradek_boot") : theme.console == .xbox ? "xbox_startup" : "ps2_startup")
        screen = .gauge
        needsDisplay = true
    }
    func previewScreen(_ s: Screen, sel: Int = 0, page: Int = 0) { screen = s; settingsSel = sel; statsPage = page; settingsPage = page }
    var forceSignIn = false   // headless preview of the "not signed in" panel
    func previewBoot(_ elapsed: Double, seam: Bool = false) { bootSeam = seam; screen = .gauge; bootStart = CACurrentMediaTime() - elapsed }  // headless boot-frame preview
    func previewPress(_ i: Int, _ v: CGFloat = 1) { if btnFlash.indices.contains(i) { btnFlash[i] = v } }

    // The mini player floats in a borderless window with nowhere to put a title-bar close
    // control, so it gets its own liquid-glass ✕ where the top-right screw would sit.
    private func setupCompactChrome() {
        guard compact, closeButton == nil else { return }
        let b = MiniCloseButton(frame: .zero)
        b.theme = theme
        b.onClose = { [weak self] in self?.onClose?() }
        addSubview(b)
        closeButton = b
        needsLayout = true
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }

    // The rounded-body rectangle, expressed in this view's (bottom-left) superview coordinates and
    // its corner radius — used to size the real NSGlassEffectView that sits behind the mini player.
    func externalGlassFrame() -> (frame: CGRect, corner: CGFloat) {
        let t = transform(), d = designSize
        let inset: CGFloat = compact ? 6 : 0                    // body inset (matches drawDevice)
        let radius: CGFloat = compact ? 30 : 24                 // body corner
        let w = (d.width - inset*2) * t.scale
        let h = (d.height - inset*2) * t.scale
        let x = inset*t.scale + t.tx
        let y = bounds.height - (inset*t.scale + t.ty) - h      // flip: design is top-left, container bottom-left
        return (CGRect(x: x, y: y, width: w, height: h), radius*t.scale)
    }

    override func layout() {
        super.layout()
        guard let b = closeButton else { return }
        let t = transform(), d = designSize
        let sInset: CGFloat = 20                                  // matches the screw inset
        let cx = (d.width - 6 - sInset), cy = (6 + sInset)        // top-right screw position (body inset = 6)
        let r: CGFloat = 14                                       // generous hit target, screw drawn at r 7
        let vr = r * t.scale
        b.frame = CGRect(x: cx*t.scale + t.tx - vr, y: cy*t.scale + t.ty - vr, width: vr*2, height: vr*2)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var blinkOn: Bool { (reduceMotion || theme.a11y) ? true : Int(Date().timeIntervalSince1970 * 2.6) % 2 == 0 }
    private var lastResetShown = Int.min
    private var lastBlink = false

    // Only repaint when something visibly changed — the needle is easing, the countdown
    // ticked, or the low-fuel warning blinked. Idle ⇒ ~0 redraws (energy + Reduce Motion).
    private func tick() {
        var needs = false
        // PS2 power-on: drive its own frames until it ends, then hand off to the Browser.
        if bootActive {
            if CACurrentMediaTime() - bootStart >= bootTotal { bootStart = 0 }
            needs = true
        }
        let target = state.fraction
        if reduceMotion {
            if displayFraction != target { displayFraction = target; needs = true }
        } else {
            let d = target - displayFraction
            if abs(d) > 0.001 { displayFraction += d * 0.18; needs = true }
            else if displayFraction != target { displayFraction = target; needs = true }
        }
        // keep repainting while the "COPIED" toast is up, then one final frame to clear it
        if copiedUntil > 0 { if CACurrentMediaTime() > copiedUntil { copiedUntil = 0 }; needs = true }
        if let r = state.resetSeconds, r != lastResetShown { lastResetShown = r; needs = true }
        if state.low { let b = blinkOn; if b != lastBlink { lastBlink = b; needs = true } }
        // Soft keys behave like real keys: the press snaps down instantly, the release springs back
        // with a slight overshoot (btnFlash dips <0 = the key pops just above flush) before settling.
        for i in btnFlash.indices {
            let held = (pressed == i)
            if reduceMotion {
                let goal: CGFloat = held ? 1 : 0
                if btnFlash[i] != goal { btnFlash[i] = goal; btnVel[i] = 0; needs = true }
                continue
            }
            if held {                                   // pressing: snap to fully-seated in ~2 frames, no bounce
                let d = 1 - btnFlash[i]
                btnVel[i] = 0
                if d > 0.004 { btnFlash[i] += d * 0.6; needs = true }
                else if btnFlash[i] != 1 { btnFlash[i] = 1; needs = true }
            } else {                                    // releasing: underdamped spring toward flush (goal 0) → springy pop-back
                let k: CGFloat = 210, c: CGFloat = 16, dt: CGFloat = 1.0/30
                btnVel[i] += (-k * btnFlash[i] - c * btnVel[i]) * dt
                btnFlash[i] += btnVel[i] * dt
                if abs(btnFlash[i]) > 0.002 || abs(btnVel[i]) > 0.01 { needs = true }
                else if btnFlash[i] != 0 || btnVel[i] != 0 { btnFlash[i] = 0; btnVel[i] = 0; needs = true }
            }
        }
        // console themes have a living background (PS2 sway, Xbox nebula) — repaint the gauge
        // screen at ~15 fps while it's showing. Skipped under Reduce Motion / accessibility.
        if (theme.console != .none || theme.odradek), !reduceMotion, !theme.a11y,
           compact || screen == .gauge, !Store.shared.largePrint {
            animFrame &+= 1
            if animFrame % 2 == 0 { needs = true }
        }
        if needs { needsDisplay = true }
    }

    // MARK: accessibility (VoiceOver)
    override func accessibilityLabel() -> String? { "Claude Token Fuel" }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityValue() -> Any? {
        let s = Int((state.fraction * 100).rounded())
        var parts = ["Session \(s) percent left"]
        if let r = state.resetSeconds { parts.append("resets in \(fmtLong(r))") }
        if let wf = state.weekFraction { parts.append("weekly \(Int((wf * 100).rounded())) percent left") }
        parts.append(state.live ? "live" : "estimated")
        return parts.joined(separator: ", ")
    }

    private func transform() -> (scale: CGFloat, tx: CGFloat, ty: CGFloat) {
        let d = designSize
        let s = min(bounds.width / d.width, bounds.height / d.height)
        return (s, (bounds.width - d.width*s)/2, (bounds.height - d.height*s)/2)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = transform()
        ctx.saveGState(); ctx.translateBy(x: t.tx, y: t.ty); ctx.scaleBy(x: t.scale, y: t.scale)
        drawDevice(ctx); ctx.restoreGState()
    }

    func snapshot(size: CGSize) -> NSImage {
        let img = NSImage(size: size); img.lockFocusFlipped(true)
        if let ctx = NSGraphicsContext.current?.cgContext {
            let d = designSize
            let s = min(size.width/d.width, size.height/d.height)
            ctx.translateBy(x: (size.width-d.width*s)/2, y: (size.height-d.height*s)/2); ctx.scaleBy(x: s, y: s)
            drawDevice(ctx)
        }
        img.unlockFocus(); return img
    }

    // MARK: - drawing
    private func drawDevice(_ ctx: CGContext) {
        let d = designSize
        // In the popover, go full-bleed: the body reaches the view edges and the whole rect is
        // painted opaque so the popover's background can't show through at the sides/corners.
        // Overscan well past the design rect: the popover often sizes the view a hair taller/wider
        // than 360×660, and min-scale centering then leaves thin letterbox bars — filling only the
        // design rect let the popover's neutral background leak through as a ~3px seam along the
        // bottom. The overflow is harmlessly clipped by the popover (and by snapshot bounds).
        // The mini player is a free-floating window, so it keeps rounded, transparent corners.
        if !compact && !externalGlassBody {
            ctx.setFillColor(theme.metalLo.cgColor)
            ctx.fill(CGRect(x: -d.width, y: -d.height, width: d.width*3, height: d.height*3))
        }
        let inset: CGFloat = compact ? 6 : 0
        let body = CGRect(x: inset, y: inset, width: d.width-inset*2, height: d.height-inset*2)
        let radius: CGFloat = compact ? 30 : 24
        let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if externalGlassBody {
            // A real NSGlassEffectView sits behind this (transparent) view and IS the body, so we
            // paint nothing here — just a faint edge stroke so the case outline reads over the glass.
            ctx.addPath(bodyPath); ctx.setStrokeColor(theme.edge.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        } else if theme.translucent {
            drawTranslucentBody(ctx, rect: body, path: bodyPath)
        } else {
            ctx.saveGState(); ctx.addPath(bodyPath); ctx.clip()
            drawVGradient(ctx, rect: body, top: theme.metalHi, mid: theme.metal, bottom: theme.metalLo)
            if !theme.reflective {                       // brushed-metal striations; matte plastic skips them
                ctx.setShouldAntialias(false)
                let brush = NSColor.white.withAlphaComponent(0.04).cgColor
                var yy = body.minY; while yy < body.maxY { ctx.setFillColor(brush); ctx.fill(CGRect(x: body.minX, y: yy, width: body.width, height: 0.5)); yy += 2 }
                ctx.setShouldAntialias(true)
            }
            ctx.restoreGState()
            ctx.addPath(bodyPath); ctx.setStrokeColor(theme.edge.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(1.5); ctx.strokePath()
            // moulded two-part shell: a hairline parting groove just inside the front edge
            if theme.reflective {
                let seam = CGPath(roundedRect: body.insetBy(dx: 5, dy: 5), cornerWidth: radius-4, cornerHeight: radius-4, transform: nil)
                ctx.addPath(seam); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.30).cgColor); ctx.setLineWidth(1); ctx.strokePath()
                let seam2 = CGPath(roundedRect: body.insetBy(dx: 6.2, dy: 6.2), cornerWidth: radius-5, cornerHeight: radius-5, transform: nil)
                ctx.addPath(seam2); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.06).cgColor); ctx.setLineWidth(1); ctx.strokePath()
            }
            if theme.odradek && !compact { drawOdradekFacets(ctx, body) }
        }

        let sInset: CGFloat = compact ? 20 : 26
        var screws = [CGPoint(x: body.minX+sInset, y: body.minY+sInset), CGPoint(x: body.maxX-sInset, y: body.minY+sInset),
                      CGPoint(x: body.minX+sInset, y: body.maxY-sInset), CGPoint(x: body.maxX-sInset, y: body.maxY-sInset)]
        // In the mini player the top-right corner becomes the liquid-glass close button.
        if compact { screws.remove(at: 1) }
        for p in screws { drawScrew(ctx, center: p, r: 7) }

        // screen geometry
        // When a real glass body is behind us, shrink the mini LCD a touch and use a thin bezel so
        // the Liquid Glass frame is actually visible around the screen (instead of the bezel filling
        // the whole body). Otherwise the compact bezel fills the body (keeps the OP-1 "white bar" fix).
        // Keep the LCD at its native size so the pixel grid stays crisp (shrinking it to make room
        // for the glass border broke the segments); just thin the bezel to reveal the glass frame.
        let glassMini = compact && externalGlassBody
        let lcdW: CGFloat = compact ? 240 : 300
        let cell = lcdW / CGFloat(gridW)
        let lcdH = CGFloat(gridH) * cell
        let lcdX = (d.width - lcdW)/2
        let lcdY: CGFloat = compact ? 24 : 66
        let lcdRect = CGRect(x: lcdX, y: lcdY, width: lcdW, height: lcdH)
        lcdRectDesign = lcdRect              // for tap-to-toggle large print
        let bezelDX: CGFloat = compact ? (glassMini ? -8 : -14) : -14
        let bezelDY: CGFloat = compact ? (glassMini ?  -8 : -18) : -14
        let bezelRect = lcdRect.insetBy(dx: bezelDX, dy: bezelDY)

        let bezelPath = CGPath(roundedRect: bezelRect, cornerWidth: 16, cornerHeight: 16, transform: nil)
        ctx.addPath(bezelPath); ctx.setFillColor(theme.bezel.cgColor); ctx.fillPath()
        ctx.addPath(bezelPath); ctx.setStrokeColor(theme.bezelInner.cgColor); ctx.setLineWidth(2); ctx.strokePath()
        ctx.addPath(bezelPath); ctx.setStrokeColor(theme.lcdGlow.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.75); ctx.strokePath()

        let lcdPath = CGPath(roundedRect: lcdRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        if theme.reflective {
            // A real reflective panel doesn't emit light — no glow halo. It just sits in its well.
            ctx.addPath(lcdPath); ctx.setFillColor(theme.lcdBG.cgColor); ctx.fillPath()
        } else {
            ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 20, color: theme.lcdGlow.withAlphaComponent(0.7).cgColor)
            ctx.addPath(lcdPath); ctx.setFillColor(theme.lcdBG.cgColor); ctx.fillPath(); ctx.restoreGState()
        }

        ctx.saveGState(); ctx.addPath(lcdPath); ctx.clip(); ctx.setShouldAntialias(false)
        let lcd = LCD(ctx: ctx, ox: lcdX, oy: lcdY, cell: cell, W: gridW, H: gridH)
        let scr: Screen = compact ? .gauge : screen
        switch scr {
        case .gauge:
            if needsSignIn, !compact {
                // No Claude login recognized on this Mac — offer in-app sign-in instead of a gauge.
                drawSignInScreen(lcd, theme: theme, pressed: signInPressed)
                break
            }
            var s = state; s.fraction = displayFraction
            let phase = (reduceMotion || theme.a11y) ? 0 : Date().timeIntervalSinceReferenceDate
            if theme.console != .none || theme.odradek, bootActive {
                let e = CACurrentMediaTime() - bootStart
                // Resolve to the theme's own gauge screen (PS2 Browser / Xbox blades / Odradek).
                func drawResolved() {
                    if theme.odradek { drawGaugeScreenOdradek(lcd, state: s, theme: theme, blinkOn: blinkOn, phase: phase) }
                    else if theme.console == .xbox { drawGaugeScreenXbox(lcd, state: s, theme: theme, blinkOn: blinkOn, phase: phase) }
                    else { drawGaugeScreenPS2(lcd, state: s, theme: theme, blinkOn: blinkOn, phase: phase) }
                }
                if e >= bootTotal { bootStart = 0; drawResolved() }
                else if e >= bootDuration {
                    // The boot has fully resolved back to black (as it started). Now — and only now —
                    // fade the LCD UI up from that black, so the two never overlap.
                    let f = (e - bootDuration) / bootFadeIn
                    let a = f * f * (3 - 2 * f)
                    if a > 0.004 {
                        ctx.saveGState(); ctx.setAlpha(CGFloat(a))
                        drawResolved()
                        ctx.restoreGState()
                    }
                } else {
                    // Pure boot animation over black — no UI underneath — ending on black at bootDuration.
                    if theme.odradek { (bootSeam ? drawSeamBoot : drawOdradekBoot)(lcd, theme, e, bootDuration) }
                    else if theme.console == .xbox { drawXboxBoot(lcd, theme: theme, elapsed: e, duration: bootDuration) }
                    else { drawPS2Boot(lcd, theme: theme, elapsed: e, duration: bootDuration) }
                }
            }
            // Weekly tokens exhausted (live, no credits to extend): a lockout screen with a big
            // countdown to the next weekly refill, overriding the normal gauge / large-print.
            else if let wf = s.weekFraction, wf <= 0.0005, s.weekResetSeconds != nil {
                drawWeeklyLimitScreen(lcd, state: s, theme: theme)
            }
            else if Store.shared.largePrint, theme.odradek { drawGaugeLargeOdradek(lcd, state: s, theme: theme, blinkOn: blinkOn, phase: phase) }
            else if Store.shared.largePrint { drawGaugeLargeScreen(lcd, state: s, theme: theme, blinkOn: blinkOn) }
            else if theme.console == .ps2 { drawGaugeScreenPS2(lcd, state: s, theme: theme, blinkOn: blinkOn, phase: phase) }
            else if theme.console == .xbox { drawGaugeScreenXbox(lcd, state: s, theme: theme, blinkOn: blinkOn, phase: phase) }
            else if theme.opStyle { drawGaugeScreenOP1(lcd, state: s, theme: theme, blinkOn: blinkOn) }
            else if theme.odradek { drawGaugeScreenOdradek(lcd, state: s, theme: theme, blinkOn: blinkOn, phase: phase) }
            else { drawGaugeScreen(lcd, state: s, theme: theme, blinkOn: blinkOn) }
        case .stats:
            drawStatsScreen(lcd, statsData(), theme: theme, page: statsPage)
        case .settings:
            switch settingsPage {
            case 0:
                drawSettingsScreen(lcd, rows: settingRows(), selected: settingsSel, theme: theme, live: state.live)
            case 2 where Account.isOwner:
                drawAdminScreen(lcd, theme: theme, pressed: reportPressed)
            default:
                drawReportScreen(lcd, AppModel.shared.connectionInfo(), theme: theme,
                                 pressed: reportPressed, copied: copiedUntil > 0)
            }
        }
        if !theme.a11y { lcdGrid(lcd, theme) }        // grid + gloss reduce legibility
        ctx.setShouldAntialias(true)
        if theme.reflective { drawReflectiveSheen(ctx, rect: lcdRect) }
        if !theme.a11y { drawGlass(ctx, rect: lcdRect) }
        ctx.restoreGState()

        guard !compact else { return }

        // soft-key buttons — span the exact screen (bezel) width so the row lines up with the display
        let keys = softKeys(for: screen)
        let bTop = bezelRect.maxY + 16
        let areaX = bezelRect.minX, areaW = bezelRect.width, gap: CGFloat = 12
        let bw = (areaW - gap*2)/3, bh: CGFloat = 60
        buttonRects = []
        for i in 0..<3 {
            let rect = CGRect(x: areaX + CGFloat(i)*(bw+gap), y: bTop, width: bw, height: bh)
            buttonRects.append(rect)
            drawButton(ctx, rect: rect, glyph: keys[i], flash: btnFlash[i])
        }

        // signature badge in the open space below the soft keys
        let emblemY = (bTop + bh + body.maxY) / 2
        emblemRectDesign = CGRect(x: d.width/2 - 74, y: emblemY - 22, width: 148, height: 44)
        drawEmblem(ctx, center: CGPoint(x: d.width/2, y: emblemY))
    }

    private func drawEmblem(_ ctx: CGContext, center: CGPoint) {
        switch theme.emblem {
        case .none:  break
        case .ps2:   drawPSButtons(ctx, center: center)
        case .xbox:  drawXboxJewel(ctx, center: center, r: 12)
        case .op1:   drawOP1Knobs(ctx, center: center)
        case .powerRing: drawPowerRing(ctx, center: center, r: 12)
        case .pager: drawPagerBadge(ctx, center: center)
        case .odradek: drawOdradek(ctx, center: center)
        }
    }

    // Faceted flanks (Ventura-style): angular beveled panels sculpted into the side margins beside
    // the screen — a light top bevel + shadowed lower edge — plus a small orange 12-o'clock accent.
    private func drawOdradekFacets(_ ctx: CGContext, _ body: CGRect) {
        let light = NSColor.white.withAlphaComponent(0.11).cgColor
        let shadow = NSColor.black.withAlphaComponent(0.6).cgColor
        let panel = NSColor.black.withAlphaComponent(0.30).cgColor
        let y0 = body.minY + body.height * 0.17, y1 = body.maxY - body.height * 0.17
        let n = 3, gap = body.height * 0.02
        let h = (y1 - y0 - gap * CGFloat(n - 1)) / CGFloat(n)
        let slant = h * 0.26
        for side in 0..<2 {
            let outer = side == 0 ? body.minX + 4 : body.maxX - 4
            let inner = side == 0 ? body.minX + 28 : body.maxX - 28
            for i in 0..<n {
                let ty = y0 + (h + gap) * CGFloat(i), by = ty + h
                let p = CGMutablePath()
                p.move(to: CGPoint(x: outer, y: ty + slant))
                p.addLine(to: CGPoint(x: inner, y: ty))
                p.addLine(to: CGPoint(x: inner, y: by))
                p.addLine(to: CGPoint(x: outer, y: by - slant))
                p.closeSubpath()
                ctx.addPath(p); ctx.setFillColor(panel); ctx.fillPath()
                ctx.setLineWidth(1.2); ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: outer, y: ty + slant)); ctx.addLine(to: CGPoint(x: inner, y: ty))
                ctx.setStrokeColor(light); ctx.strokePath()
                ctx.move(to: CGPoint(x: inner, y: by)); ctx.addLine(to: CGPoint(x: outer, y: by - slant))
                ctx.setStrokeColor(shadow); ctx.strokePath()
            }
        }
        // orange 12-o'clock accent above the screen
        ctx.setFillColor(hexC(0xE8763A))
        ctx.fill(CGRect(x: body.midX - 2, y: body.minY + body.height * 0.055, width: 4, height: body.height * 0.02))
    }

    // The Odradek scanner badge: an orange sensor "cross" (four flat blades around a lit core) over a
    // soft glow, flanked by hazard ticks — the black-and-orange kit clipped to Sam's shoulder.
    private func drawOdradek(_ ctx: CGContext, center c: CGPoint) {
        let cyan = hexC(0xE8763A), cyanHi = hexC(0xF0A84B), dark = hexC(0x0A0806)
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [cyan.copy(alpha: 0.42)!, cyan.copy(alpha: 0)!] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 34, options: [])
        }
        // hazard ticks flanking the scanner (utility-kit markings)
        ctx.setStrokeColor(cyan.copy(alpha: 0.65)!); ctx.setLineWidth(2); ctx.setLineCap(.round)
        for s in [-1.0, 1.0] as [CGFloat] {
            for k in 0..<3 {
                let x = c.x + s * (30 + CGFloat(k) * 7)
                ctx.move(to: CGPoint(x: x - 3, y: c.y - 6)); ctx.addLine(to: CGPoint(x: x + 3, y: c.y + 6)); ctx.strokePath()
            }
        }
        // four sensor blades radiating from the core (the open scanner)
        let gap: CGFloat = 4, len: CGFloat = 12, halfW: CGFloat = 2.6
        func blade(_ dx: CGFloat, _ dy: CGFloat) {
            ctx.saveGState(); ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: atan2(dy, dx))
            let r = CGRect(x: gap, y: -halfW, width: len, height: halfW * 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: halfW, cornerHeight: halfW, transform: nil))
            ctx.setFillColor(cyan); ctx.fillPath()
            ctx.setFillColor(cyanHi); ctx.fillEllipse(in: CGRect(x: gap + len - 3, y: -1.6, width: 3.2, height: 3.2))
            ctx.restoreGState()
        }
        blade(0, -1); blade(0, 1); blade(-1, 0); blade(1, 0)
        // central housing + lit core
        let h = CGRect(x: c.x - 5.5, y: c.y - 5.5, width: 11, height: 11)
        ctx.addPath(CGPath(roundedRect: h, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        ctx.setFillColor(dark); ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: h, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        ctx.setStrokeColor(cyan); ctx.setLineWidth(1.4); ctx.strokePath()
        ctx.setFillColor(cyanHi); ctx.fillEllipse(in: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4))
    }

    // The OP-1's four signature encoder knobs: blue / green / white / orange caps, each with a
    // ringed metal collar and a lighter slotted indicator.
    private func drawOP1Knobs(_ ctx: CGContext, center: CGPoint) {
        let r: CGFloat = 8, gap: CGFloat = 24
        let caps = [hexC(0x36A6E0), hexC(0x3DBE52), hexC(0xF1F2F4), hexC(0xF5601E)]
        let angles: [CGFloat] = [.pi*0.62, .pi*1.15, .pi*1.75, .pi*0.35]   // varied like the real unit
        for (i, cap) in caps.enumerated() {
            let c = CGPoint(x: center.x + (CGFloat(i) - 1.5) * gap, y: center.y)
            let box = CGRect(x: c.x-r, y: c.y-r, width: r*2, height: r*2)
            // metal collar
            ctx.setFillColor(hexC(0xBFC2C8)); ctx.fillEllipse(in: box.insetBy(dx: -1.5, dy: -1.5))
            // coloured cap with a soft top-light
            ctx.saveGState(); ctx.addEllipse(in: box); ctx.clip()
            ctx.setFillColor(cap); ctx.fill(box)
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [hexC(0xFFFFFF, 0.45), hexC(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: c.x-r*0.35, y: c.y-r*0.4), startRadius: 0,
                                   endCenter: c, endRadius: r*1.4, options: [])
            ctx.restoreGState()
            ctx.addEllipse(in: box); ctx.setStrokeColor(hexC(0x000000, 0.18)); ctx.setLineWidth(0.8); ctx.strokePath()
            // slotted indicator (lighter for coloured caps, dark for the white cap)
            let slot = i == 2 ? hexC(0x9A9DA3) : hexC(0xFFFFFF, 0.85)
            let a = angles[i], len = r*0.62
            ctx.setStrokeColor(slot); ctx.setLineWidth(r*0.32); ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: c.x - cos(a)*len, y: c.y - sin(a)*len))
            ctx.addLine(to: CGPoint(x: c.x + cos(a)*len, y: c.y + sin(a)*len))
            ctx.strokePath()
        }
    }

    // △ ○ ✕ □ face buttons in their classic PlayStation colours, outlined and softly lit.
    private func drawPSButtons(_ ctx: CGContext, center: CGPoint) {
        let r: CGFloat = 6, gap: CGFloat = 22
        let green = hexC(0x59C3A5), red = hexC(0xE24A5B), blue = hexC(0x5A7BE0), pink = hexC(0xE05BA8)
        for (i, col) in [green, red, blue, pink].enumerated() {
            let cx = center.x + (CGFloat(i) - 1.5) * gap, cy = center.y
            ctx.saveGState()
            ctx.setStrokeColor(col); ctx.setLineWidth(1.7); ctx.setLineJoin(.round); ctx.setLineCap(.round)
            ctx.setShadow(offset: .zero, blur: 4, color: col)
            switch i {
            case 0:  // triangle
                ctx.move(to: CGPoint(x: cx, y: cy - r))
                ctx.addLine(to: CGPoint(x: cx + r*0.92, y: cy + r*0.72))
                ctx.addLine(to: CGPoint(x: cx - r*0.92, y: cy + r*0.72))
                ctx.closePath(); ctx.strokePath()
            case 1:  // circle
                ctx.strokeEllipse(in: CGRect(x: cx - r*0.85, y: cy - r*0.85, width: r*1.7, height: r*1.7))
            case 2:  // cross
                ctx.move(to: CGPoint(x: cx - r*0.8, y: cy - r*0.8)); ctx.addLine(to: CGPoint(x: cx + r*0.8, y: cy + r*0.8))
                ctx.move(to: CGPoint(x: cx + r*0.8, y: cy - r*0.8)); ctx.addLine(to: CGPoint(x: cx - r*0.8, y: cy + r*0.8))
                ctx.strokePath()
            default: // square
                ctx.stroke(CGRect(x: cx - r*0.72, y: cy - r*0.72, width: r*1.44, height: r*1.44))
            }
            ctx.restoreGState()
        }
    }

    // Original Xbox "jewel": a dark green dome with a radial glow and a bright bevelled X.
    private func drawXboxJewel(_ ctx: CGContext, center: CGPoint, r: CGFloat) {
        let lime = hexC(0xB6F24A)
        // slow "breathing" pulse of the jewel, matched to the blades screen (stilled under Reduce Motion)
        let pulse = reduceMotion ? 0.5 : (0.5 + 0.5 * sin(Date().timeIntervalSinceReferenceDate * 1.5))
        // radial nebula glow
        ctx.saveGState()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [hexC(0x77C312, 0.40 + 0.30 * CGFloat(pulse)), hexC(0x77C312, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: r*(1.6 + 0.4 * CGFloat(pulse)), options: [])
        ctx.restoreGState()
        // dark dome
        let dome = CGRect(x: center.x - r, y: center.y - r, width: r*2, height: r*2)
        ctx.saveGState(); ctx.addEllipse(in: dome); ctx.clip()
        let dg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [hexC(0x14260C), hexC(0x050A03)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(dg, startCenter: CGPoint(x: center.x - r*0.3, y: center.y - r*0.3), startRadius: 0,
                               endCenter: center, endRadius: r, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
        ctx.addEllipse(in: dome); ctx.setStrokeColor(hexC(0x77C312, 0.8)); ctx.setLineWidth(1.2); ctx.strokePath()
        // the X
        ctx.saveGState()
        ctx.setStrokeColor(lime); ctx.setLineWidth(r*0.3); ctx.setLineCap(.round)
        ctx.setShadow(offset: .zero, blur: 5, color: lime)
        let d = r*0.55
        ctx.move(to: CGPoint(x: center.x - d, y: center.y - d)); ctx.addLine(to: CGPoint(x: center.x + d, y: center.y + d))
        ctx.move(to: CGPoint(x: center.x + d, y: center.y - d)); ctx.addLine(to: CGPoint(x: center.x - d, y: center.y + d))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func hexC(_ v: Int, _ a: CGFloat = 1) -> CGColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF)/255, green: CGFloat((v >> 8) & 0xFF)/255,
                blue: CGFloat(v & 0xFF)/255, alpha: a).cgColor
    }

    // The icon drawn on each of the three soft keys, per page (the glyph alone signals the action).
    private func softKeys(for s: Screen) -> [String] {
        switch s {
        case .gauge:    return ["chart", "gear", "popout"]
        case .stats:    return ["back", "page", "popout"]
        // Settings keys are navigation-only now: back, switch tab (SETUP/REPORT), pop-out.
        // Values are changed by tapping the rows; the REPORT tab has its own on-screen buttons.
        case .settings: return ["back", "page", "popout"]
        }
    }

    // MARK: data for screens
    private func statsData() -> StatsData {
        var s = StatsData()
        s.fraction = state.fraction; s.used = state.used; s.budget = state.budget
        s.plan = state.plan; s.resetSeconds = state.resetSeconds; s.perModel = state.perModel
        s.today = AppModel.shared.todayTokens; s.lifetime = AppModel.shared.lifetimeTokens
        s.cache = Store.shared.includeCacheReads
        s.live = state.live; s.weekFraction = state.weekFraction; s.weekResetSeconds = state.weekResetSeconds
        if !state.live { s.connNote = AppModel.shared.connectionShort() }
        return s
    }

    // Calibrate the EST tank from real data: how many local tokens equal a full window =
    // tokens used this window ÷ fraction of the window the server says is used. Needs a live
    // reading and enough usage (>3%) to be meaningful; result rounded to a tidy 1M and clamped.
    private func autoTankSuggestion() -> Int? {
        guard state.live, state.used > 0 else { return nil }
        let usedFrac = 1 - max(0, min(1, state.fraction))
        guard usedFrac > 0.03 else { return nil }
        let raw = (Double(state.used) / usedFrac / 1_000_000).rounded() * 1_000_000
        return min(500_000_000, max(1_000_000, Int(raw)))
    }

    private func settingRows() -> [SettingRow] {
        let st = Store.shared
        let planVal = st.isAutoPlan ? "AUTO \(st.plan.name)" : st.plan.name
        return [
            SettingRow(label: "PLAN",   value: planVal),
            SettingRow(label: "TANK",   value: fmtTokens(st.budget), estOnly: true),
            SettingRow(label: "AUTO TANK", value: st.autoTank ? "ON" : "OFF"),
            SettingRow(label: "WINDOW", value: "\(Int(st.windowHours))H", estOnly: true),
            SettingRow(label: "CACHE",  value: st.includeCacheReads ? "ON" : "OFF"),
            SettingRow(label: "MENU 7D", value: st.menuWeekly ? "ON" : "OFF"),
            SettingRow(label: "NOTIFY", value: st.notifyOnReset ? "ON" : "OFF"),
            SettingRow(label: "BIG TEXT", value: st.largePrint ? "ON" : "OFF"),
            SettingRow(label: "REFILL", value: st.refillClockTime ? "AT" : "IN"),
            SettingRow(label: "THEME",  value: st.theme.name.uppercased()),
        ]
    }
    private var settingCount: Int { settingRows().count }

    // Settings tabs: SETUP + REPORT for everyone; the developer-only ADMIN tab is added only on the
    // owner's Claude account (see Account.isOwner), so it stays hidden for anyone else who installs it.
    private var settingsPageCount: Int { Account.isOwner ? 3 : 2 }

    private static let tankSteps = [1_000_000, 2_000_000, 5_000_000, 10_000_000, 20_000_000, 30_000_000, 50_000_000, 80_000_000, 120_000_000, 200_000_000]
    private static let windowSteps: [Double] = [1,2,3,4,5,6,8,12,24]

    private func changeSetting(_ i: Int) {
        let st = Store.shared
        switch i {
        case 0:
            let ids = ["auto"] + Plan.all.map { $0.id }
            let k = ids.firstIndex(of: st.planID) ?? 0
            st.planID = ids[(k+1) % ids.count]
            st.applyPlanDefaults()
        case 1:
            let cur = Self.tankSteps.firstIndex(where: { $0 >= st.budget }) ?? Self.tankSteps.count-1
            st.budget = Self.tankSteps[(cur+1) % Self.tankSteps.count]
        case 2:   // AUTO TANK — toggle continuous calibration; apply once immediately when turned on
            st.autoTank.toggle()
            if st.autoTank, let t = autoTankSuggestion() { st.budget = t }
        case 3:
            let cur = Self.windowSteps.firstIndex(where: { $0 >= st.windowHours }) ?? 0
            st.windowHours = Self.windowSteps[(cur+1) % Self.windowSteps.count]
        case 4:
            st.includeCacheReads.toggle()
        case 5:
            st.menuWeekly.toggle()
        case 6:
            st.notifyOnReset.toggle()
            if st.notifyOnReset { Notify.requestAuth() }
        case 7:
            st.largePrint.toggle()
        case 8:   // REFILL — big-text gauge shows the wall-clock refill time ("AT") vs a countdown ("IN")
            st.refillClockTime.toggle()
        case 9:
            let ids = Theme.all.map { $0.id }
            let k = ids.firstIndex(of: st.themeID) ?? 0
            st.themeID = ids[(k+1) % ids.count]
        default: break
        }
        needsDisplay = true
    }

    // MARK: drawing helpers
    private func drawVGradient(_ ctx: CGContext, rect: CGRect, top: NSColor, mid: NSColor, bottom: NSColor) {
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [top.cgColor, mid.cgColor, bottom.cgColor] as CFArray, locations: [0,0.42,1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
    }

    // See-through "liquid glass" body: a circuit board seen through a thick tinted pane.
    // Rebuilt around the physics that make real transparent plastic read as glass (researched
    // from Apple Liquid Glass / Prismal / realglass): a *blurred* interior (frost bends & concentrates
    // light), edge lensing (thick rounded edges act as a lens → dark refraction band + bright rim),
    // a tight Blinn-Phong specular hotspot (not a flat wash), and a Fresnel rim with chromatic fringe.
    private func drawTranslucentBody(_ ctx: CGContext, rect: CGRect, path: CGPath) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let base = theme.lcdGlow.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.4, green: 0.9, blue: 0.2, alpha: 1)
        // shade < 0 darkens toward black, > 0 lightens toward white
        func t(_ shade: CGFloat, _ alpha: CGFloat) -> CGColor {
            let m = shade >= 0 ? (base.blended(withFraction: shade, of: .white) ?? base)
                               : (base.blended(withFraction: -shade, of: .black) ?? base)
            return m.withAlphaComponent(alpha).cgColor
        }
        let corner: CGFloat = compact ? 30 : 24
        ctx.saveGState(); ctx.addPath(path); ctx.clip()

        // 1. interior circuit board, blurred as if sunk behind thick frosted resin (depth cue)
        drawBlurredPCB(ctx, rect, blur: compact ? 2.4 : 3.6)

        // 2. coloured glass tint — clearer at the top, saturating & darkening toward the bottom,
        //    giving the pane volume instead of a flat colour film
        let tint = CGGradient(colorsSpace: cs, colors: [t(0.34, 0.16), t(-0.14, 0.40), t(-0.55, 0.64)] as CFArray,
                              locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(tint, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        // 3. faint iridescence (kept subtle — heavy rainbow foil is what read as cheap)
        drawHoloSheen(ctx, rect)
        // 4. uniform frost haze (per-theme strength)
        ctx.setFillColor(t(0.5, CGFloat(theme.frost))); ctx.fill(rect)

        // 5. EDGE LENSING — the single biggest "thick glass" cue. A soft dark refraction band hugs
        //    the whole inner perimeter (light bends away from the eye at the curved edge).
        let lensW: CGFloat = compact ? 16 : 22
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()                                   // keep it inside the body
        ctx.setShadow(offset: .zero, blur: lensW, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        // stroke the perimeter with a wide clear line whose *shadow* paints the inner darkening
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: -lensW, dy: -lensW), cornerWidth: corner+lensW, cornerHeight: corner+lensW, transform: nil))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.9).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        // 6. soft ambient sky-light falling from the top (broad, low)
        let ambient = CGGradient(colorsSpace: cs, colors: [NSColor.white.withAlphaComponent(0.14).cgColor,
                                                           NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.45])!
        ctx.drawLinearGradient(ambient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])

        // 7. tight specular HOTSPOT (Blinn-Phong): a crisp bright reflection near the top-right,
        //    plus a soft secondary bloom — replaces the old flat diagonal gloss wash
        let hot = CGPoint(x: rect.minX + rect.width*0.72, y: rect.minY + rect.height*0.16)
        ctx.setBlendMode(.plusLighter)
        let spec = CGGradient(colorsSpace: cs, colors: [NSColor.white.withAlphaComponent(0.95).cgColor,
                                                        NSColor.white.withAlphaComponent(0.5).cgColor,
                                                        NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.25, 1])!
        ctx.drawRadialGradient(spec, startCenter: hot, startRadius: 0, endCenter: hot, endRadius: rect.width*0.34, options: [])
        ctx.setBlendMode(.normal)
        ctx.restoreGState()

        // 8. FRESNEL RIM — bright, crisp edge that's strongest along the top, with a hair of
        //    chromatic dispersion (cyan/magenta offset) like light splitting through the glass lip.
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        let inner = CGPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: corner-1.5, cornerHeight: corner-1.5, transform: nil)
        var down = CGAffineTransform(translationX: 0, y: 0.8)
        var up = CGAffineTransform(translationX: 0, y: -0.8)
        if let cyan = inner.copy(using: &down) {
            ctx.addPath(cyan); ctx.setStrokeColor(NSColor(srgbRed: 0.5, green: 0.9, blue: 1, alpha: 0.35).cgColor)
            ctx.setLineWidth(1); ctx.strokePath()
        }
        if let magenta = inner.copy(using: &up) {
            ctx.addPath(magenta); ctx.setStrokeColor(NSColor(srgbRed: 1, green: 0.5, blue: 0.9, alpha: 0.3).cgColor)
            ctx.setLineWidth(1); ctx.strokePath()
        }
        // top-weighted white inner highlight (bright at the top lip, fading down the sides)
        let rimGrad = CGGradient(colorsSpace: cs, colors: [NSColor.white.withAlphaComponent(0.6).cgColor,
                                                          NSColor.white.withAlphaComponent(0.12).cgColor] as CFArray, locations: [0, 1])!
        ctx.saveGState(); ctx.addPath(inner); ctx.setLineWidth(1.4); ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(rimGrad, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        ctx.restoreGState()
        ctx.restoreGState()

        // 9. crisp outer edge stroke (the polished lip catching the light)
        ctx.addPath(path); ctx.setStrokeColor(t(0.55, 0.85)); ctx.setLineWidth(1.5); ctx.strokePath()
    }

    // Renders the deterministic PCB once, Gaussian-blurs it so it reads as sunk behind thick
    // frosted resin, and caches the result (the board is deterministic + theme-independent, so it
    // only depends on size + blur). Falls back to a sharp board if the offscreen pass fails.
    private static let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
    // The bundled photoreal board (matches the body's 0.545 aspect). Loaded once.
    static let pcbArt: CGImage? = {
        guard let url = Res.url("pcb", "png"),                     // nil-safe: never crashes if missing
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }()
    // Keyed by size+blur so the popover and the mini player (different sizes, possibly both open)
    // each keep their own cached board instead of thrashing a single slot every frame.
    private static var blurredPCBCache: [String: CGImage] = [:]
    private func drawBlurredPCB(_ ctx: CGContext, _ rect: CGRect, blur: CGFloat) {
        let scale: CGFloat = 2
        let w = Int((rect.width*scale).rounded()), h = Int((rect.height*scale).rounded())
        guard w > 0, h > 0 else { drawPCB(ctx, rect); return }
        let key = "\(w)x\(h)@\(blur)"
        if let cached = Self.blurredPCBCache[key] {
            drawImageUpright(ctx, cached, in: rect); return
        }
        guard let bmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { drawPCB(ctx, rect); return }
        bmp.scaleBy(x: scale, y: scale)
        bmp.translateBy(x: -rect.minX, y: -rect.minY)
        // Real board art if present (bmp is y-up, so the image draws right-side-up here);
        // otherwise fall back to the procedural circuit board.
        // Overscan the photo: it has near-square, dark-bordered corners baked in, tighter than the
        // rounded body clip. Bleeding it past the edge pushes those baked corners outside the clip so
        // the body's own radius governs the corner (filled with board content, no green corner halo).
        if let art = Self.pcbArt {
            let bleed = rect.width * 0.04
            bmp.draw(art, in: rect.insetBy(dx: -bleed, dy: -bleed))
        } else { drawPCB(bmp, rect) }
        guard let raw = bmp.makeImage() else { drawPCB(ctx, rect); return }
        let ci = CIImage(cgImage: raw)
        let blurred = ci.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur*scale])
            .cropped(to: ci.extent)
        guard let out = Self.ciCtx.createCGImage(blurred, from: ci.extent) else { drawPCB(ctx, rect); return }
        if Self.blurredPCBCache.count > 4 { Self.blurredPCBCache.removeAll() }   // tiny cap
        Self.blurredPCBCache[key] = out
        drawImageUpright(ctx, out, in: rect)
    }

    // Draws a CGImage right-side-up into the (flipped, top-left origin) device context.
    private func drawImageUpright(_ ctx: CGContext, _ img: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    // A glowing power-symbol jewel in the theme's glow colour (translucent consoles).
    private func drawPowerRing(_ ctx: CGContext, center: CGPoint, r: CGFloat) {
        let glow = theme.lcdGlow
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [glow.withAlphaComponent(0.55).cgColor, glow.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: r*1.9, options: [])
        let dome = CGRect(x: center.x-r, y: center.y-r, width: r*2, height: r*2)
        ctx.setFillColor(hexC(0x0A140A)); ctx.fillEllipse(in: dome)
        ctx.setStrokeColor(glow.withAlphaComponent(0.8).cgColor); ctx.setLineWidth(1.2); ctx.strokeEllipse(in: dome)
        ctx.saveGState()
        ctx.setStrokeColor(glow.cgColor); ctx.setLineWidth(2); ctx.setLineCap(.round)
        ctx.setShadow(offset: .zero, blur: 5, color: glow.cgColor)
        ctx.addArc(center: center, radius: r*0.5, startAngle: .pi * -0.32, endAngle: .pi * 1.32, clockwise: false)
        ctx.strokePath()
        ctx.move(to: CGPoint(x: center.x, y: center.y - r*0.72)); ctx.addLine(to: CGPoint(x: center.x, y: center.y - r*0.05)); ctx.strokePath()
        ctx.restoreGState()
    }

    // Iridescent holographic sheen: crossed rainbow sweeps added with plusLighter so the board
    // shimmers like foil / an oil slick, plus a couple of fine diagonal sparkle streaks.
    private func drawHoloSheen(_ ctx: CGContext, _ rect: CGRect) {
        let cs = CGColorSpaceCreateDeviceRGB()
        func spectrum(_ a: CGFloat) -> CGGradient {
            let hues: [CGFloat] = [0.83, 0.66, 0.52, 0.34, 0.15, 0.07, 0.92]
            let cols = hues.map { NSColor(hue: $0, saturation: 0.85, brightness: 1, alpha: a).cgColor } as CFArray
            return CGGradient(colorsSpace: cs, colors: cols, locations: [0, 0.18, 0.36, 0.54, 0.72, 0.86, 1])!
        }
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        // A single faint diagonal iridescence sweep — enough to hint at an oil-slick sheen without
        // the heavy crossed rainbows + sparkle streaks that made the old body read as cheap foil.
        ctx.drawLinearGradient(spectrum(0.05), start: CGPoint(x: rect.minX, y: rect.minY),
                               end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        ctx.restoreGState()
    }

    // A deterministic printed-circuit board: traces, gold vias, ICs, capacitors, silkscreen.
    private func drawPCB(_ ctx: CGContext, _ rect: CGRect) {
        func c(_ r: Double,_ g: Double,_ b: Double,_ a: Double = 1) -> CGColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor }
        var s: UInt64 = 0xB16B00B5DEADBEEF
        func rnd() -> CGFloat { s = s &* 2862933555777941757 &+ 3037000493; return CGFloat((s >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF) }
        func rr(_ a: CGFloat,_ b: CGFloat) -> CGFloat { a + (b-a)*rnd() }

        ctx.setFillColor(c(0.03, 0.15, 0.07)); ctx.fill(rect)

        // routed traces (L-shaped)
        ctx.setLineCap(.round)
        for _ in 0..<46 {
            let gold = rnd() < 0.45
            ctx.setStrokeColor(gold ? c(0.70, 0.54, 0.24, 0.8) : c(0.16, 0.42, 0.22, 0.85))
            ctx.setLineWidth(gold ? 1.6 : 1.2)
            let x0 = rr(rect.minX+8, rect.maxX-8), y0 = rr(rect.minY+8, rect.maxY-8)
            let d1: CGFloat = rnd() < 0.5 ? -1 : 1, d2: CGFloat = rnd() < 0.5 ? -1 : 1
            let l1 = rr(20, 90), l2 = rr(10, 70)
            ctx.beginPath(); ctx.move(to: CGPoint(x: x0, y: y0))
            if rnd() < 0.5 {
                let x1 = x0 + l1*d1
                ctx.addLine(to: CGPoint(x: x1, y: y0)); ctx.addLine(to: CGPoint(x: x1, y: y0 + l2*d2))
            } else {
                let y1 = y0 + l1*d1
                ctx.addLine(to: CGPoint(x: x0, y: y1)); ctx.addLine(to: CGPoint(x: x0 + l2*d2, y: y1))
            }
            ctx.strokePath()
        }
        // gold vias
        for _ in 0..<72 {
            let x = rr(rect.minX+6, rect.maxX-6), y = rr(rect.minY+6, rect.maxY-6)
            ctx.setFillColor(c(0.72, 0.55, 0.24)); ctx.fillEllipse(in: CGRect(x: x-2, y: y-2, width: 4, height: 4))
            ctx.setFillColor(c(0.05, 0.12, 0.06)); ctx.fillEllipse(in: CGRect(x: x-0.8, y: y-0.8, width: 1.6, height: 1.6))
        }
        // black ICs with pins
        for _ in 0..<6 {
            let w = rr(28, 58), h = rr(22, 44)
            let x = rr(rect.minX+16, rect.maxX-16-w), y = rr(rect.minY+34, rect.maxY-34-h)
            let chip = CGRect(x: x, y: y, width: w, height: h)
            ctx.setFillColor(c(0.60, 0.62, 0.66))
            var px = x+4; while px < x+w-3 { ctx.fill(CGRect(x: px, y: y-3, width: 2, height: 3)); ctx.fill(CGRect(x: px, y: y+h, width: 2, height: 3)); px += 5 }
            ctx.setFillColor(c(0.06, 0.07, 0.08)); ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
            ctx.setStrokeColor(c(0.22, 0.24, 0.26)); ctx.setLineWidth(0.8); ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.strokePath()
            ctx.setFillColor(c(0.5, 0.5, 0.55)); ctx.fillEllipse(in: CGRect(x: x+4, y: y+4, width: 3, height: 3))
        }
        // capacitors
        let caps = [c(0.08, 0.09, 0.12), c(0.10, 0.20, 0.50), c(0.50, 0.30, 0.10)]
        for _ in 0..<14 {
            let x = rr(rect.minX+10, rect.maxX-10), y = rr(rect.minY+22, rect.maxY-22), rad = rr(4, 7)
            ctx.setFillColor(caps[Int(rnd()*2.99)]); ctx.fillEllipse(in: CGRect(x: x-rad, y: y-rad, width: rad*2, height: rad*2))
            ctx.setStrokeColor(c(0.6, 0.6, 0.65, 0.6)); ctx.setLineWidth(0.8)
            ctx.beginPath(); ctx.move(to: CGPoint(x: x-rad*0.6, y: y)); ctx.addLine(to: CGPoint(x: x+rad*0.6, y: y)); ctx.strokePath()
        }
        // electrolytic capacitor banks (rows of cylinders)
        for _ in 0..<3 {
            let n = Int(rr(3, 6))
            let cy0 = rr(rect.minY+14, rect.maxY-14)
            let cx0 = rr(rect.minX+14, rect.maxX-14 - CGFloat(n)*14)
            for k in 0..<n {
                let x = cx0 + CGFloat(k)*14, rad: CGFloat = 6
                let box = CGRect(x: x-rad, y: cy0-rad, width: rad*2, height: rad*2)
                ctx.setFillColor(c(0.10, 0.11, 0.14)); ctx.fillEllipse(in: box)
                ctx.setStrokeColor(c(0.55, 0.56, 0.60, 0.7)); ctx.setLineWidth(0.8); ctx.strokeEllipse(in: box)
                ctx.setFillColor(c(0.70, 0.70, 0.72, 0.5)); ctx.fill(CGRect(x: x-rad*0.7, y: cy0-0.5, width: rad*1.4, height: 1))
            }
        }
        // connector headers (black block with gold pins)
        for _ in 0..<3 {
            let w = rr(24, 44), h: CGFloat = 8
            let x = rr(rect.minX+12, rect.maxX-12-w), y = rr(rect.minY+16, rect.maxY-16)
            ctx.setFillColor(c(0.05, 0.06, 0.07)); ctx.fill(CGRect(x: x, y: y, width: w, height: h))
            ctx.setFillColor(c(0.55, 0.44, 0.20)); var px = x+3; while px < x+w-2 { ctx.fill(CGRect(x: px, y: y+2, width: 2, height: h-4)); px += 5 }
        }
        // silkscreen ticks
        ctx.setStrokeColor(c(0.80, 0.85, 0.80, 0.22)); ctx.setLineWidth(0.7)
        for _ in 0..<26 {
            let x = rr(rect.minX+8, rect.maxX-16), y = rr(rect.minY+8, rect.maxY-8)
            ctx.beginPath(); ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + rr(4, 10), y: y)); ctx.strokePath()
        }
    }
    private func drawGlass(_ ctx: CGContext, rect: CGRect) {
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0,0.5])!
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY),
                               end: CGPoint(x: rect.minX+rect.width*0.5, y: rect.minY+rect.height*0.6), options: [])
    }
    // Reflective-LCD depth: a shadow along the top/left where the glass sits below the bezel
    // lip, plus a faint EL-backlight bleed rising from the bottom edge. Called inside the clip.
    private func drawReflectiveSheen(_ ctx: CGContext, rect: CGRect) {
        let topShade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [NSColor.black.withAlphaComponent(0.22).cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(topShade, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.minX, y: rect.minY + 20), options: [])
        ctx.drawLinearGradient(topShade, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.minX + 16, y: rect.minY), options: [])
        let el = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [theme.lcdGlow.withAlphaComponent(0).cgColor, theme.lcdGlow.withAlphaComponent(0.14).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(el, start: CGPoint(x: rect.minX, y: rect.maxY - 34), end: CGPoint(x: rect.minX, y: rect.maxY), options: [])
    }
    // Moulded speaker grille with a red alert LED — the beeper's face badge.
    private func drawPagerBadge(_ ctx: CGContext, center: CGPoint) {
        let cols = 6, rows = 3, sp: CGFloat = 6, r: CGFloat = 1.7
        let gw = CGFloat(cols-1)*sp
        let ox = center.x - gw/2 - 16, oy = center.y - CGFloat(rows-1)*sp/2
        for row in 0..<rows { for col in 0..<cols {
            let p = CGRect(x: ox + CGFloat(col)*sp - r, y: oy + CGFloat(row)*sp - r, width: r*2, height: r*2)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor); ctx.fillEllipse(in: p)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.05).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.minX, y: p.minY-0.6, width: r*2, height: r*2))
        }}
        // red alert LED behind a clear prism, to the right of the grille
        let led = CGPoint(x: ox + gw + 22, y: center.y)
        ctx.saveGState()
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [hexC(0xFF3B30, 0.55), hexC(0xFF3B30, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: led, startRadius: 0, endCenter: led, endRadius: 11, options: [])
        ctx.setFillColor(hexC(0xE0241B)); ctx.fillEllipse(in: CGRect(x: led.x-3.4, y: led.y-3.4, width: 6.8, height: 6.8))
        ctx.setFillColor(hexC(0xFFA59E, 0.9)); ctx.fillEllipse(in: CGRect(x: led.x-1.6, y: led.y-2.1, width: 2.6, height: 2.6))
        ctx.restoreGState()
    }
    private func drawScrew(_ ctx: CGContext, center: CGPoint, r: CGFloat) {
        let rect = CGRect(x: center.x-r, y: center.y-r, width: r*2, height: r*2)
        ctx.saveGState(); ctx.addEllipse(in: rect); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [theme.screwHi.cgColor, theme.screwLo.cgColor] as CFArray, locations: [0,1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        ctx.restoreGState()
        ctx.addEllipse(in: rect); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.4).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        ctx.saveGState(); ctx.translateBy(x: center.x, y: center.y); ctx.rotate(by: .pi/5)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor); ctx.fill(CGRect(x: -r*0.6, y: -0.9, width: r*1.2, height: 1.8)); ctx.restoreGState()
    }
    // A plain high-contrast key: a solid black-or-white button with the opposite-colour icon,
    // matching the theme (dark themes → white-on-black, light themes → black-on-white). `flash`
    // (0…1) is the neutral press animation — the key tints toward its icon colour and nudges down.
    private func drawButton(_ ctx: CGContext, rect: CGRect, glyph: String, flash: CGFloat) {
        let dark = theme.isDark
        let bg = dark ? NSColor(white: 0.09, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        let fg = dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.10, alpha: 1)

        // `flash` is the depression: 1 = fully seated, 0 = flush, slightly <0 during the spring-back pop.
        let sink = max(0, flash)          // how far the key is pressed into its well
        let pop  = max(0, -flash)         // spring-back overshoot above flush

        let wellPath = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.saveGState(); ctx.addPath(wellPath); ctx.clip()
        ctx.setFillColor(bg.cgColor); ctx.fill(rect)
        // Top gloss so it isn't dead flat. It dims as the key sinks (the light gets occluded) and
        // flares a touch brighter on the release pop, selling the rise back to flush.
        let glossA = max(0, 0.05 * (1 - sink*0.85) + 0.04 * pop)
        let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [(dark ? NSColor.white : NSColor.black).withAlphaComponent(glossA).cgColor,
                                        NSColor.clear.cgColor] as CFArray, locations: [0, 0.5])!
        ctx.drawLinearGradient(gloss, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])
        // Pressed = tint toward the icon colour so the press reads on both black and white keys...
        if sink > 0.01 {
            ctx.setFillColor(fg.withAlphaComponent(0.16 * sink).cgColor)
            ctx.fill(rect)
            // ...plus an inset ambient-occlusion shadow down the top inner edge: the depth cue that
            // makes the key read as sunk *into* the body rather than merely darkened.
            let ao = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [NSColor.black.withAlphaComponent(0.34 * sink).cgColor,
                                         NSColor.clear.cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(ao, start: CGPoint(x: rect.midX, y: rect.minY),
                                   end: CGPoint(x: rect.midX, y: rect.minY + rect.height*0.55), options: [])
        }
        ctx.restoreGState()
        // thin edge to seat the key in the body — reads a hair deeper while held
        ctx.addPath(wellPath)
        ctx.setStrokeColor((dark ? NSColor.white.withAlphaComponent(0.10 - 0.04*sink)
                                 : NSColor.black.withAlphaComponent(0.18 + 0.10*sink)).cgColor)
        ctx.setLineWidth(1); ctx.strokePath()

        // Centred icon: travels down with the depression (and lifts on the pop), and shrinks a hair
        // when fully seated so it reads as receding into the surface.
        drawGlyph(ctx, glyph, center: CGPoint(x: rect.midX, y: rect.midY + flash*2.2),
                  s: 22 * (1 - sink*0.05), color: fg)
    }
    // Minimal vector icons drawn on the physical soft keys (crisp, theme-tinted, no bitmap).
    private func drawGlyph(_ ctx: CGContext, _ id: String, center c: CGPoint, s: CGFloat, color: NSColor) {
        let h = s/2
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor); ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(1.8); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        switch id {
        case "chart":                                   // three rising bars
            let w = s*0.2
            for (i, frac) in [0.5, 0.75, 1.0].enumerated() {
                let bh = h*2*CGFloat(frac)*0.8
                let x = c.x - w*1.6 + CGFloat(i)*w*1.6
                ctx.fill(CGRect(x: x - w/2, y: c.y + h*0.8 - bh, width: w, height: bh))
            }
        case "gear":                                    // ring with teeth + hub
            let r = h*0.52
            for k in 0..<8 {
                let a = CGFloat(k) * .pi/4
                ctx.move(to: CGPoint(x: c.x + cos(a)*r*1.02, y: c.y + sin(a)*r*1.02))
                ctx.addLine(to: CGPoint(x: c.x + cos(a)*r*1.5, y: c.y + sin(a)*r*1.5))
            }
            ctx.strokePath()
            ctx.strokeEllipse(in: CGRect(x: c.x-r, y: c.y-r, width: r*2, height: r*2))
            ctx.fillEllipse(in: CGRect(x: c.x-r*0.32, y: c.y-r*0.32, width: r*0.64, height: r*0.64))
        case "popout":                                  // window with an arrow leaving it
            let b = CGRect(x: c.x - h*0.85, y: c.y - h*0.35, width: h*1.15, height: h*1.15)
            ctx.stroke(b)
            ctx.move(to: CGPoint(x: c.x + h*0.05, y: c.y - h*0.15))
            ctx.addLine(to: CGPoint(x: c.x + h*0.9, y: c.y - h*0.95)); ctx.strokePath()
            let tip = CGPoint(x: c.x + h*0.9, y: c.y - h*0.95)
            ctx.move(to: CGPoint(x: tip.x - h*0.5, y: tip.y)); ctx.addLine(to: tip)
            ctx.addLine(to: CGPoint(x: tip.x, y: tip.y + h*0.5)); ctx.strokePath()
        case "back":  chevron(ctx, c: c, h: h, dir: .left)
        case "page":  chevron(ctx, c: c, h: h, dir: .right)
        default: break
        }
        ctx.restoreGState()
    }
    private enum ChevDir { case left, right }
    private func chevron(_ ctx: CGContext, c: CGPoint, h: CGFloat, dir: ChevDir) {
        switch dir {
        case .left:
            ctx.move(to: CGPoint(x: c.x + h*0.3, y: c.y - h*0.6))
            ctx.addLine(to: CGPoint(x: c.x - h*0.35, y: c.y))
            ctx.addLine(to: CGPoint(x: c.x + h*0.3, y: c.y + h*0.6))
        case .right:
            ctx.move(to: CGPoint(x: c.x - h*0.3, y: c.y - h*0.6))
            ctx.addLine(to: CGPoint(x: c.x + h*0.35, y: c.y))
            ctx.addLine(to: CGPoint(x: c.x - h*0.3, y: c.y + h*0.6))
        }
        ctx.strokePath()
    }
    // MARK: interaction
    private func designPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil); let t = transform()
        return CGPoint(x: (p.x - t.tx)/t.scale, y: (p.y - t.ty)/t.scale)
    }

    // Which settings row (if any) sits under a design-space point — the whole LCD is touchable,
    // so tapping a row selects and toggles it directly instead of cycling with the soft keys.
    // Rows are drawn at LCD grid y = 20 + i*13 (see drawSettingsScreen); map the tap back to the
    // grid via the stored LCD rect and find the band it falls in.
    private func settingsRowAt(_ p: CGPoint) -> Int? {
        guard lcdRectDesign.width > 0 else { return nil }
        let cell = lcdRectDesign.width / CGFloat(gridW)
        let gx = (p.x - lcdRectDesign.minX) / cell
        let gy = (p.y - lcdRectDesign.minY) / cell
        guard gx >= 4, gx <= 116 else { return nil }
        for i in 0..<settingCount {
            let top = CGFloat(18 + i*13)
            if gy >= top && gy < top + 13 { return i }
        }
        return nil
    }

    // Convert an LCD-grid rect (as used by the screen drawing) into a design-space rect, so a tap
    // can be tested against on-screen touch buttons drawn in grid coordinates.
    private func gridRectToDesign(_ r: CGRect) -> CGRect {
        guard lcdRectDesign.width > 0 else { return .zero }
        let cell = lcdRectDesign.width / CGFloat(gridW)
        return CGRect(x: lcdRectDesign.minX + r.minX*cell, y: lcdRectDesign.minY + r.minY*cell,
                      width: r.width*cell, height: r.height*cell)
    }

    // Which REPORT-tab touch button (0 = recheck, 1 = copy) is under a design-space point.
    private func reportButtonAt(_ p: CGPoint) -> Int? {
        if gridRectToDesign(ReportUI.recheck).contains(p) { return 0 }
        if gridRectToDesign(ReportUI.copy).contains(p) { return 1 }
        return nil
    }

    // Whether the ADMIN tab's "SHOW BUBBLE" button is under a design-space point.
    private func adminButtonAt(_ p: CGPoint) -> Int? {
        if gridRectToDesign(AdminUI.intro).contains(p) { return 0 }
        if gridRectToDesign(AdminUI.signin).contains(p) { return 1 }
        return nil
    }

    // Fire a REPORT-tab button: recheck the live connection, or build + copy the diagnostic report.
    private func triggerReportButton(_ b: Int) {
        if b == 0 {
            AppModel.shared.reload(forceLive: true)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AppModel.shared.connectionReport(), forType: .string)
            copiedUntil = CACurrentMediaTime() + 1.8
        }
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        if bootActive { return }        // during the boot a press does nothing but arm the skip (see mouseUp)
        let p = designPoint(event)
        pressed = buttonRects.firstIndex { $0.contains(p) }
        // press feedback for the on-screen buttons on the REPORT / ADMIN tabs
        if pressed == nil, !compact, screen == .settings {
            if settingsPage == 1 { reportPressed = reportButtonAt(p) }
            else if settingsPage == 2, Account.isOwner, let b = adminButtonAt(p) { reportPressed = b }
        }
        if pressed == nil, !compact, screen == .gauge, needsSignIn, signInButtonAt(p) { signInPressed = true }
        // Odradek theme: a soft "inventory select" click when you press a button or the screen
        if theme.odradek, pressed != nil || reportPressed != nil || signInPressed || lcdRectDesign.contains(p) {
            SFX.play("odradek_click", volume: 0.3)
        }
        needsDisplay = true
    }
    // The mini player has no title bar, so we move it ourselves: a real drag starts a window
    // move, while a press that never drags falls through to mouseUp and counts as a tap. This
    // keeps "drag to reposition" and "tap the screen" from fighting each other.
    override func mouseDragged(with event: NSEvent) {
        if compact { window?.performDrag(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; reportPressed = nil; signInPressed = false; needsDisplay = true }
        if bootActive { skipBoot(); return }        // a click during the boot skips it
        let p = designPoint(event)
        if let i = pressed, buttonRects.indices.contains(i), buttonRects[i].contains(p) {
            switch screen {
            case .gauge:
                forceSignIn = false        // leaving the (possibly admin-previewed) sign-in panel
                if i == 0 { screen = .stats; statsPage = 0 }
                else if i == 1 { screen = .settings; settingsSel = 0; themeIDOnSettingsEnter = theme.id }
                else { onPopout?() }
            case .stats:
                if i == 0 { screen = .gauge }
                else if i == 1 { statsPage = (statsPage + 1) % 3 }
                else { onPopout?() }
            case .settings:
                if i == 0 {
                    // Back to the main screen. If you just switched TO a console theme in here, play its
                    // power-on now (not while cycling themes). Only when the theme actually changed.
                    let themeChanged = theme.id != themeIDOnSettingsEnter
                    screen = .gauge; settingsPage = 0
                    if themeChanged, theme.console != .none || theme.odradek { startBoot(force: true) }
                }
                else if i == 1 { settingsPage = (settingsPage + 1) % settingsPageCount }   // cycle SETUP → REPORT → ADMIN
                else { onPopout?() }
            }
        } else if lcdRectDesign.contains(p) {
            // The LCD itself is touchable. What a tap does depends on the page.
            if !compact, screen == .gauge, needsSignIn {
                if signInButtonAt(p) {                // tap SIGN IN on the "not connected" panel
                    NotificationCenter.default.post(name: .signInRequested, object: nil)
                }
            } else if compact || screen == .gauge {
                Store.shared.largePrint.toggle()      // tap the screen to switch large-print on/off
            } else if screen == .stats {
                statsPage = (statsPage + 1) % 3       // tap anywhere on stats to page through
            } else if screen == .settings {
                if settingsPage == 0, let i = settingsRowAt(p) {
                    settingsSel = i                   // tap a row to select it…
                    let inactive = settingRows()[i].estOnly && state.live   // …and change it, unless it's an
                    if !inactive { changeSetting(i) } // EST-only row disabled while LIVE
                } else if settingsPage == 1, let b = reportButtonAt(p) {
                    triggerReportButton(b)            // RECHECK / COPY on the REPORT tab
                } else if settingsPage == 2, Account.isOwner, let b = adminButtonAt(p) {
                    if b == 0 { onShowIntro?() }       // ADMIN: re-show the intro bubble
                    else { forceSignIn = true; screen = .gauge }   // ADMIN: preview the sign-in panel
                }
            }
        } else if emblemRectDesign.contains(p) {  // click the bottom logo → replay the console power-on
            if theme.console != .none || theme.odradek { startBoot(force: true) }
        }
    }
}

// A small frosted "liquid glass" disc with an ✕, used only by the mini player so it can be
// dismissed without opening the status-bar menu. It's a real subview (not painted into the
// device canvas) so isMovableByWindowBackground keeps dragging the body while clicks here
// register — mouseDownCanMoveWindow is false so the window doesn't hijack the press.
final class MiniCloseButton: NSView {
    var theme = Theme.noir { didSet { needsDisplay = true } }
    var onClose: (() -> Void)?

    private var pressed = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent)  { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false; needsDisplay = true
        if inside { onClose?() }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Close mini player" }
    override func accessibilityPerformPress() -> Bool { onClose?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let disc = bounds.insetBy(dx: 1.5, dy: 1.5)
        let c = CGPoint(x: disc.midX, y: disc.midY), r = disc.width/2

        // soft outer glow so the button reads against the busy gauge screen
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: pressed ? 3 : 6,
                      color: (hovering ? NSColor(srgbRed: 0.95, green: 0.32, blue: 0.28, alpha: 0.9) : NSColor.black.withAlphaComponent(0.55)).cgColor)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.001).cgColor)
        ctx.fillEllipse(in: disc)
        ctx.restoreGState()

        // The disc always floats over the dark LCD, so it's styled light-on-dark regardless of
        // theme: a frosted glass fill, turning red like a title-bar close control on hover.
        let hoverRed = NSColor(srgbRed: 0.92, green: 0.31, blue: 0.28, alpha: 1)
        let fillTop = (hovering ? hoverRed.withAlphaComponent(0.92) : NSColor.white.withAlphaComponent(pressed ? 0.42 : 0.30))
        let fillBot = (hovering ? hoverRed.withAlphaComponent(0.68) : NSColor.white.withAlphaComponent(pressed ? 0.20 : 0.12))

        ctx.saveGState()
        ctx.addEllipse(in: disc); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [fillTop.cgColor, fillBot.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: c.x, y: disc.minY), end: CGPoint(x: c.x, y: disc.maxY), options: [])
        // glassy top highlight
        let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [NSColor.white.withAlphaComponent(0.55).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                            locations: [0, 1])!
        ctx.drawRadialGradient(hl, startCenter: CGPoint(x: c.x, y: disc.minY + r*0.35), startRadius: 0,
                               endCenter: CGPoint(x: c.x, y: disc.minY + r*0.35), endRadius: r*1.1, options: [])
        ctx.restoreGState()

        // bright rim
        ctx.addEllipse(in: disc)
        ctx.setStrokeColor((hovering ? hoverRed : NSColor.white.withAlphaComponent(0.6)).cgColor)
        ctx.setLineWidth(pressed ? 1.6 : 1.2)
        ctx.strokePath()

        // the ✕
        let glyph: NSColor = hovering ? .white : NSColor.white.withAlphaComponent(0.92)
        let k = r * (pressed ? 0.36 : 0.42)
        ctx.setStrokeColor(glyph.cgColor); ctx.setLineWidth(1.8); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: c.x - k, y: c.y - k)); ctx.addLine(to: CGPoint(x: c.x + k, y: c.y + k))
        ctx.move(to: CGPoint(x: c.x + k, y: c.y - k)); ctx.addLine(to: CGPoint(x: c.x - k, y: c.y + k))
        ctx.strokePath()
    }
}
