import AppKit

// Headless preview: `ClaudeFuel --render out.png [--theme silver] [--frac 0.62] [--compact]`
func renderPreview(_ args: [String]) {
    guard let ri = args.firstIndex(of: "--render"), ri + 1 < args.count else { exit(2) }
    let out = args[ri + 1]

    func val(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    Store.shared.largePrint = args.contains("--large")
    let theme = Theme.by(id: val("--theme") ?? "clarity")
    let frac = Double(val("--frac") ?? "0.62") ?? 0.62
    let compact = args.contains("--compact")

    var state = GaugeState()
    state.fraction = frac
    state.budget = 2_000_000
    state.used = Int((1 - frac) * 2_000_000)
    state.plan = "MAX5"
    state.resetSeconds = 2*3600 + 34*60 + 5
    state.perModel = [("OPUS", 520_000), ("SONNET", 240_000)]
    if args.contains("--live") {
        state.live = true
        state.weekFraction = 0.96
        state.weekResetSeconds = 3*24*3600 + 6*3600
    }
    if args.contains("--weeklimit") {                 // preview the weekly-limit lockout screen
        state.live = true
        state.weekFraction = 0
        state.weekResetSeconds = 2*24*3600 + 15*3600
    }

    let dev = DeviceView(frame: .zero)
    dev.compact = compact
    dev.state = state
    dev.theme = theme
    dev.seedNeedle(frac)
    switch val("--screen") {
    case "stats":    dev.previewScreen(.stats, page: Int(val("--page") ?? "0") ?? 0)
    case "settings": dev.previewScreen(.settings, sel: Int(val("--sel") ?? "0") ?? 0, page: Int(val("--page") ?? "0") ?? 0)
    case "signin":   dev.forceSignIn = true
    default: break
    }
    if let p = val("--press"), let i = Int(p) { dev.previewPress(i, Double(val("--flash") ?? "1").map { CGFloat($0) } ?? 1) }
    if let b = val("--boot"), let e = Double(b) { dev.previewBoot(e, seam: args.contains("--seam")) }

    let size = compact ? NSSize(width: 560, height: 800) : NSSize(width: 640, height: 1000)
    let img = dev.snapshot(size: size)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
    try? png.write(to: URL(fileURLWithPath: out))
    exit(0)
}

// Headless preview of the first-run welcome bubble, drawn under a mock menu bar with the fuel
// icon, so you can see the "look up here ↑" hint in context: `ClaudeFuel --welcome out.png`
func renderWelcome(_ out: String) {
    let content = AppDelegate.makeWelcomeContent(target: nil, action: nil)
    content.layoutSubtreeIfNeeded()
    // Host the controls in an offscreen window so AppKit renders the button bezel + text properly.
    let host = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    host.contentView = content
    let cImg = NSImage(size: content.bounds.size)
    if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: rep)
        cImg.addRepresentation(rep)
    }

    let cardW = content.frame.width, cardH = content.frame.height
    let barH: CGFloat = 26, arrow: CGFloat = 11, margin: CGFloat = 22
    let W = cardW + margin*2
    let H = barH + arrow + cardH + margin
    let iconCX = W - 74                                   // where the menu-bar icon sits

    let canvas = NSImage(size: NSSize(width: W, height: H)); canvas.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { canvas.unlockFocus(); exit(3) }
    ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    // top menu-bar strip with the live fuel tank icon + "62%"
    ctx.setFillColor(NSColor(white: 0.20, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: H-barH, width: W, height: barH))
    AppDelegate.statusIcon(fraction: 0.62).draw(in: NSRect(x: iconCX-8, y: H-barH+5, width: 16, height: 16))
    let pct = NSAttributedString(string: "62%", attributes: [.font: NSFont.menuBarFont(ofSize: 0),
                                                             .foregroundColor: NSColor.white])
    pct.draw(at: NSPoint(x: iconCX+11, y: H-barH+5))
    // popover card with an upward arrow pointing at the icon
    let card = CGRect(x: margin, y: margin, width: cardW, height: cardH)
    let path = CGMutablePath()
    path.addRoundedRect(in: card, cornerWidth: 12, cornerHeight: 12)
    let ax = min(card.maxX-24, max(card.minX+24, iconCX))
    path.move(to: CGPoint(x: ax-arrow, y: card.maxY))
    path.addLine(to: CGPoint(x: ax, y: card.maxY+arrow))
    path.addLine(to: CGPoint(x: ax+arrow, y: card.maxY))
    path.closeSubpath()
    ctx.addPath(path); ctx.setFillColor(NSColor.windowBackgroundColor.cgColor); ctx.fillPath()
    cImg.draw(in: card)
    canvas.unlockFocus()

    if let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: out)) }
    _ = host
    exit(0)
}

let arguments = CommandLine.arguments
if arguments.contains("--render") {
    renderPreview(arguments)
}
if let i = arguments.firstIndex(of: "--welcome"), i+1 < arguments.count {
    renderWelcome(arguments[i+1])
}
if let i = arguments.firstIndex(of: "--icon"), i+2 < arguments.count {
    // preview the menu-bar tank at several fills on one strip: --icon <path> <f1,f2,...>
    let out = arguments[i+1]
    let fracs = arguments[i+2].split(separator: ",").compactMap { Double($0) }
    let sq: CGFloat = 120, pad: CGFloat = 20
    let W = sq * CGFloat(fracs.count)
    let canvas = NSImage(size: NSSize(width: W, height: sq)); canvas.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: sq).fill()
    for (k, f) in fracs.enumerated() {
        AppDelegate.statusIcon(fraction: f).draw(in: NSRect(x: CGFloat(k)*sq+pad, y: pad, width: sq-2*pad, height: sq-2*pad))
    }
    canvas.unlockFocus()
    if let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: out)) }
    exit(0)
}
if arguments.contains("--live-test") {
    if let u = LiveUsageClient.fetchSync() {
        if let s = u.session { print("SESSION: \(Int((s.remaining*100).rounded()))% left, resets in \(Int(s.resetsAt.timeIntervalSinceNow))s (\(s.utilization)% used)") }
        if let w = u.week { print("WEEK: \(Int((w.remaining*100).rounded()))% left, resets in \(Int(w.resetsAt.timeIntervalSinceNow))s") }
        print("✓ live connection works")
    } else {
        print("✗ live fetch failed (token missing/expired or offline)")
    }
    exit(0)
}
if arguments.contains("--dump") {
    let path = ("~/.claude/projects" as NSString).expandingTildeInPath
    let entries = UsageReader.load(projectsPath: path, includeCacheReads: true)
    print("entries parsed: \(entries.count)")
    if let first = entries.first, let last = entries.last {
        print("span: \(first.date) → \(last.date)")
    }
    print("lifetime tokens: \(entries.reduce(0){$0+$1.tokens})")
    if let b = UsageReader.currentBlock(entries: entries, windowHours: 5) {
        print("current block: used=\(b.used) active=\(b.isActive) start=\(b.start) end=\(b.end)")
        print("resets in: \(Int(b.end.timeIntervalSinceNow))s")
        for (m,t) in b.perModel.sorted(by: {$0.value>$1.value}) { print("  \(m): \(t)") }
    } else { print("no block") }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar-only agent app (no Dock icon)
app.run()
