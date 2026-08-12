import AppKit

// A logical LCD grid. Everything is drawn as hard-edged cells so it reads as a real
// dot-matrix panel. Grid size is passed in so we can run it at higher resolution.
struct LCD {
    let ctx: CGContext
    let ox: CGFloat
    let oy: CGFloat
    let cell: CGFloat
    let W: Int
    let H: Int

    func px(_ x: Int, _ y: Int, _ c: CGColor) {
        if x < 0 || y < 0 || x >= W || y >= H { return }
        ctx.setFillColor(c)
        ctx.fill(CGRect(x: ox + CGFloat(x) * cell, y: oy + CGFloat(y) * cell,
                        width: cell + 0.6, height: cell + 0.6))
    }
    func rectFill(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ c: CGColor) {
        for yy in y0..<(y0+h) { for xx in x0..<(x0+w) { px(xx, yy, c) } }
    }
}

// MARK: - 5×7 pixel font
enum PF {
    static let g: [Character: [String]] = [
        "0":["01110","10001","10011","10101","11001","10001","01110"],
        "1":["00100","01100","00100","00100","00100","00100","01110"],
        "2":["01110","10001","00001","00010","00100","01000","11111"],
        "3":["11111","00010","00100","00010","00001","10001","01110"],
        "4":["00010","00110","01010","10010","11111","00010","00010"],
        "5":["11111","10000","11110","00001","00001","10001","01110"],
        "6":["00110","01000","10000","11110","10001","10001","01110"],
        "7":["11111","00001","00010","00100","01000","01000","01000"],
        "8":["01110","10001","10001","01110","10001","10001","01110"],
        "9":["01110","10001","10001","01111","00001","00010","01100"],
        "A":["01110","10001","10001","11111","10001","10001","10001"],
        "B":["11110","10001","10001","11110","10001","10001","11110"],
        "C":["01110","10001","10000","10000","10000","10001","01110"],
        "D":["11100","10010","10001","10001","10001","10010","11100"],
        "E":["11111","10000","10000","11110","10000","10000","11111"],
        "F":["11111","10000","10000","11110","10000","10000","10000"],
        "G":["01110","10001","10000","10111","10001","10001","01111"],
        "H":["10001","10001","10001","11111","10001","10001","10001"],
        "I":["01110","00100","00100","00100","00100","00100","01110"],
        "J":["00111","00010","00010","00010","00010","10010","01100"],
        "K":["10001","10010","10100","11000","10100","10010","10001"],
        "L":["10000","10000","10000","10000","10000","10000","11111"],
        "M":["10001","11011","10101","10101","10001","10001","10001"],
        "N":["10001","10001","11001","10101","10011","10001","10001"],
        "O":["01110","10001","10001","10001","10001","10001","01110"],
        "P":["11110","10001","10001","11110","10000","10000","10000"],
        "Q":["01110","10001","10001","10001","10101","10010","01101"],
        "R":["11110","10001","10001","11110","10100","10010","10001"],
        "S":["01111","10000","10000","01110","00001","00001","11110"],
        "T":["11111","00100","00100","00100","00100","00100","00100"],
        "U":["10001","10001","10001","10001","10001","10001","01110"],
        "V":["10001","10001","10001","10001","10001","01010","00100"],
        "W":["10001","10001","10001","10101","10101","11011","10001"],
        "X":["10001","10001","01010","00100","01010","10001","10001"],
        "Y":["10001","10001","01010","00100","00100","00100","00100"],
        "Z":["11111","00001","00010","00100","01000","10000","11111"],
        "%":["11000","11001","00010","00100","01000","10011","00011"],
        ".":["00000","00000","00000","00000","00000","01100","01100"],
        ",":["00000","00000","00000","00000","01100","01100","01000"],
        ":":["00000","01100","01100","00000","01100","01100","00000"],
        "/":["00001","00010","00100","00100","00100","01000","10000"],
        "-":["00000","00000","00000","11111","00000","00000","00000"],
        "+":["00000","00100","00100","11111","00100","00100","00000"],
        "·":["00000","00000","00100","01110","00100","00000","00000"],
        ">":["01000","00100","00010","00001","00010","00100","01000"],
        " ":["00000","00000","00000","00000","00000","00000","00000"],
    ]
    static func width(_ s: String, _ scale: Int) -> Int { s.count * 6 * scale - scale }
}

func lcdText(_ lcd: LCD, _ s: String, _ x: Int, _ y: Int, _ c: CGColor, _ scale: Int = 1) {
    var cx = x
    for ch in s.uppercased() {
        let glyph = PF.g[ch] ?? PF.g[" "]!
        for r in 0..<7 {
            let row = Array(glyph[r])
            for col in 0..<5 where row[col] == "1" {
                for sy in 0..<scale { for sx in 0..<scale { lcd.px(cx+col*scale+sx, y+r*scale+sy, c) } }
            }
        }
        cx += 6 * scale
    }
}
func lcdTextC(_ lcd: LCD, _ s: String, _ cx: Int, _ y: Int, _ c: CGColor, _ scale: Int = 1) {
    lcdText(lcd, s, cx - PF.width(s, scale)/2, y, c, scale)
}
func lcdTextR(_ lcd: LCD, _ s: String, _ rx: Int, _ y: Int, _ c: CGColor, _ scale: Int = 1) {
    lcdText(lcd, s, rx - PF.width(s, scale), y, c, scale)
}

func lcdLine(_ lcd: LCD, _ x0i: Int, _ y0i: Int, _ x1: Int, _ y1: Int, _ c: CGColor) {
    var x0 = x0i, y0 = y0i
    let dx = abs(x1 - x0), dy = -abs(y1 - y0)
    let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
    var err = dx + dy
    while true {
        lcd.px(x0, y0, c)
        if x0 == x1 && y0 == y1 { break }
        let e2 = 2 * err
        if e2 >= dy { err += dy; x0 += sx }
        if e2 <= dx { err += dx; y0 += sy }
    }
}

func opColor(_ v: Int, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((v>>16)&0xFF)/255, green: CGFloat((v>>8)&0xFF)/255, blue: CGFloat(v&0xFF)/255, alpha: a).cgColor
}

func lcdGrid(_ lcd: LCD, _ theme: Theme) {
    if theme.opStyle || theme.console != .none { return }   // OP-1 / console screens are emissive — no dot grid
    let grid = theme.lcdOn.withAlphaComponent(0.09).cgColor
    var x = 0
    while x <= lcd.W { var y = 0; while y < lcd.H { lcd.px(x, y, grid); y += 5 }; x += 5 }
    var y = 0
    while y <= lcd.H { var xx = 0; while xx < lcd.W { lcd.px(xx, y, grid); xx += 5 }; y += 5 }
}

func fmtTokens(_ n: Int) -> String {
    let v = Double(n)
    if v >= 1_000_000 { return String(format: "%.1fM", v/1_000_000) }
    if v >= 1_000 { return String(format: "%.0fK", v/1_000) }
    return "\(n)"
}
func fmtClock(_ secs: Int) -> String {
    let h = secs/3600, m = (secs%3600)/60, s = secs%60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

// Wall-clock time-of-day when the window refills (now + secs), e.g. "3:45PM" or "15:45".
// Follows the user's locale for 12/24-hour style; spaces stripped and letters upper-cased so it
// fits the LCD font (which only draws upper-case glyphs).
private let refillTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f
}()
func fmtClockTime(_ secs: Int) -> String {
    let when = Date().addingTimeInterval(Double(secs))
    // Strip every whitespace flavour a locale might insert (regular, non-breaking U+00A0,
    // narrow no-break U+202F) since the LCD font has no space glyph, then upper-case for it.
    let raw = refillTimeFormatter.string(from: when)
    return raw.components(separatedBy: .whitespaces).joined().uppercased()
}

func fmtLong(_ s: Int) -> String {
    let d = s/86400, h = (s%86400)/3600, m = (s%3600)/60
    if d > 0 { return "\(d)D \(h)H" }
    if h > 0 { return "\(h)H \(m)M" }
    return "\(m)M"
}

// One small rotary needle gauge (E→F semicircle). fraction nil = no data (dim, no needle).
func arcGauge(_ lcd: LCD, cx: Double, cy: Double, r: Double, fraction: Double?, on: CGColor, dim: CGColor) {
    var d = 0.0
    while d <= 180 { let a = (180-d) * .pi/180
        lcd.px(Int((cx+cos(a)*r).rounded()), Int((cy-sin(a)*r).rounded()), dim); d += 6 }
    for deg in stride(from: 0.0, through: 180.0, by: 90.0) {
        let a = (180-deg) * .pi/180
        lcdLine(lcd, Int((cx+cos(a)*(r-4)).rounded()), Int((cy-sin(a)*(r-4)).rounded()),
                     Int((cx+cos(a)*r).rounded()), Int((cy-sin(a)*r).rounded()), on)
    }
    lcdText(lcd, "E", Int(cx-r)-4, Int(cy)-3, dim)
    lcdText(lcd, "F", Int(cx+r)-1, Int(cy)-3, dim)
    guard let raw = fraction else { return }
    let f = max(0, min(1, raw))
    let na = (180 - f*180) * .pi/180
    let nx = cx+cos(na)*(r-5), ny = cy-sin(na)*(r-5)
    lcdLine(lcd, Int(cx), Int(cy), Int(nx.rounded()), Int(ny.rounded()), on)
    lcd.rectFill(Int(cx)-1, Int(cy)-1, 3, 3, on)
}

func drawBar(_ lcd: LCD, _ label: String, _ f: Double?, y: Int, on: CGColor, dim: CGColor, hide: Bool = false, h: Int = 13) {
    lcdText(lcd, label, 6, y + (h-7)/2, on)
    let bx = 26, bw = 84, segs = 12
    let col = (f == nil) ? dim : on
    for x in bx...(bx+bw) { lcd.px(x, y, col); lcd.px(x, y+h, col) }
    for yy in y...(y+h) { lcd.px(bx, yy, col); lcd.px(bx+bw, yy, col) }
    guard let f, !hide else { return }
    let lit = Int((max(0, min(1, f)) * Double(segs)).rounded())
    // Distribute segments evenly across the whole interior so a full bar reaches
    // both borders instead of leaving a ragged dead gap on the right.
    let innerL = bx + 2, innerR = bx + bw - 1
    let cell = Double(innerR - innerL) / Double(segs)
    for i in 0..<segs where i < lit {
        let x0 = innerL + Int((Double(i)   * cell).rounded())
        let x1 = innerL + Int((Double(i+1) * cell).rounded())
        // 2-cell gap between segments: at the mini's non-retina scale a 1-cell gap gets eaten by
        // the LCD's cell overdraw and the segments merge into a solid block.
        lcd.rectFill(x0, y+2, max(1, x1 - x0 - 2), h-3, on)
    }
}

// MARK: - Screen: dual fuel gauges (SESSION 5H + WEEKLY 7D), grid 120×176
func drawGaugeScreen(_ lcd: LCD, state: GaugeState, theme: Theme, blinkOn: Bool) {
    let on = theme.lcdOn.cgColor, dim = theme.lcdDimText.cgColor, acc = theme.lcdAccent.cgColor
    let sf = max(0, min(1, state.fraction))

    lcdTextC(lcd, "CLAUDE FUEL", 60, 5, on)
    lcdLine(lcd, 8, 16, 111, 16, dim)

    // Spread the two gauges toward the outer edges (radius trimmed) so their inner
    // "F" and "E" tick labels don't collide into an unreadable "FE" in the middle.
    let lcx = 28.0, rcx = 92.0, gcy = 62.0, gr = 22.0
    lcdTextC(lcd, "SESSION", Int(lcx), 21, on)
    lcdTextC(lcd, "WEEKLY", Int(rcx), 21, acc)
    arcGauge(lcd, cx: lcx, cy: gcy, r: gr, fraction: sf, on: on, dim: dim)
    arcGauge(lcd, cx: rcx, cy: gcy, r: gr, fraction: state.weekFraction, on: acc, dim: dim)

    lcdTextC(lcd, "\(Int((sf*100).rounded()))%", Int(lcx), 78, on, 2)
    if let wf = state.weekFraction {
        lcdTextC(lcd, "\(Int((wf*100).rounded()))%", Int(rcx), 78, acc, 2)
    } else {
        lcdTextC(lcd, "--", Int(rcx), 78, dim, 2)
    }

    lcdTextC(lcd, state.resetSeconds.map { fmtClock($0) } ?? "--", Int(lcx), 95, on)
    lcdTextC(lcd, state.weekResetSeconds.map { fmtLong($0) } ?? "--", Int(rcx), 95, acc)

    lcdLine(lcd, 8, 109, 111, 109, dim)
    lcdTextC(lcd, "PLAN \(state.plan) · \(state.live ? "LIVE" : "EST")", 60, 114, on)

    drawBar(lcd, "5H", sf, y: 130, on: on, dim: dim, hide: state.low && !blinkOn)
    drawBar(lcd, "7D", state.weekFraction, y: 150, on: acc, dim: dim)
}

// A thin OP-1-style arc: a faint track that fills bright from E up to the needle, in one colour.
func op1Arc(_ lcd: LCD, cx: Double, cy: Double, r: Double, fraction: Double?, color: CGColor) {
    let faint = color.copy(alpha: 0.30) ?? color
    let f = fraction.map { max(0, min(1, $0)) }
    var d = 0.0
    while d <= 180 {
        let a = (180-d) * .pi/180
        let pos = d/180
        let c = (f != nil && pos <= f!) ? color : faint
        lcd.px(Int((cx+cos(a)*r).rounded()), Int((cy-sin(a)*r).rounded()), c); d += 6
    }
    for deg in stride(from: 0.0, through: 180.0, by: 90.0) {
        let a = (180-deg) * .pi/180
        lcdLine(lcd, Int((cx+cos(a)*(r-4)).rounded()), Int((cy-sin(a)*(r-4)).rounded()),
                     Int((cx+cos(a)*r).rounded()), Int((cy-sin(a)*r).rounded()), faint)
    }
    lcdText(lcd, "E", Int(cx-r)-4, Int(cy)-3, faint)
    lcdText(lcd, "F", Int(cx+r)-1, Int(cy)-3, faint)
    guard let f else { return }
    let na = (180 - f*180) * .pi/180
    let nx = cx+cos(na)*(r-5), ny = cy-sin(na)*(r-5)
    lcdLine(lcd, Int(cx), Int(cy), Int(nx.rounded()), Int(ny.rounded()), color)
    lcd.rectFill(Int(cx)-1, Int(cy)-1, 3, 3, color)
}

// MARK: - Screen: OP-1 "FX" style — black OLED, multi-colour neon vector graphics
func drawGaugeScreenOP1(_ lcd: LCD, state: GaugeState, theme: Theme, blinkOn: Bool) {
    let white = theme.lcdOn.cgColor, dim = theme.lcdDimText.cgColor
    let cyan = opColor(0x4EC3E0), magenta = opColor(0xE0559A)
    let green = opColor(0x3DBE52), amber = opColor(0xF5A623)
    let rule = opColor(0x28323F), ink = opColor(0x0A0C10)
    let sf = max(0, min(1, state.fraction))

    lcdTextC(lcd, "CLAUDE FUEL", 60, 5, white)
    lcdLine(lcd, 8, 16, 111, 16, rule)

    let lcx = 28.0, rcx = 92.0, gcy = 62.0, gr = 22.0
    lcdTextC(lcd, "SESSION", Int(lcx), 21, cyan)
    lcdTextC(lcd, "WEEKLY", Int(rcx), 21, magenta)
    op1Arc(lcd, cx: lcx, cy: gcy, r: gr, fraction: sf, color: cyan)
    op1Arc(lcd, cx: rcx, cy: gcy, r: gr, fraction: state.weekFraction, color: magenta)

    lcdTextC(lcd, "\(Int((sf*100).rounded()))%", Int(lcx), 78, cyan, 2)
    if let wf = state.weekFraction {
        lcdTextC(lcd, "\(Int((wf*100).rounded()))%", Int(rcx), 78, magenta, 2)
    } else { lcdTextC(lcd, "--", Int(rcx), 78, dim, 2) }

    lcdTextC(lcd, state.resetSeconds.map { fmtClock($0) } ?? "--", Int(lcx), 95, white)
    lcdTextC(lcd, state.weekResetSeconds.map { fmtLong($0) } ?? "--", Int(rcx), 95, white)

    lcdLine(lcd, 8, 109, 111, 109, rule)
    // status: PLAN value on the left, a LIVE/EST chip on the right (OP-1 status pill)
    lcdText(lcd, "PLAN", 8, 114, dim)
    lcdText(lcd, state.plan, 8 + PF.width("PLAN ", 1), 114, white)
    let tag = state.live ? "LIVE" : "EST"
    let tw = PF.width(tag, 1) + 6, tx = 112 - tw
    lcd.rectFill(tx, 112, tw, 11, state.live ? green : amber)
    lcdText(lcd, tag, tx + 3, 114, ink)

    drawBar(lcd, "5H", sf, y: 130, on: cyan, dim: opColor(0x22384A), hide: state.low && !blinkOn)
    drawBar(lcd, "7D", state.weekFraction, y: 150, on: magenta, dim: opColor(0x22384A))
}

// A label-less segmented block bar with an even edge-to-edge fill (see drawBar) — used by the
// console screens for their memory-card / fuel indicators.
func segBar(_ lcd: LCD, x: Int, y: Int, w: Int, h: Int, _ f: Double?, segs: Int, on: CGColor, dim: CGColor, hide: Bool = false) {
    for xx in x...(x+w) { lcd.px(xx, y, dim); lcd.px(xx, y+h, dim) }
    for yy in y...(y+h) { lcd.px(x, yy, dim); lcd.px(x+w, yy, dim) }
    guard let f, !hide else { return }
    let lit = Int((max(0, min(1, f)) * Double(segs)).rounded())
    let innerL = x + 2, innerR = x + w - 1
    let cell = Double(innerR - innerL) / Double(segs)
    for i in 0..<segs where i < lit {
        let x0 = innerL + Int((Double(i)   * cell).rounded())
        let x1 = innerL + Int((Double(i+1) * cell).rounded())
        lcd.rectFill(x0, y+2, max(1, x1 - x0 - 2), h-3, on)
    }
}

// MARK: - Screen: PlayStation 2 "Browser" — deep-blue panel, memory-card free-space bars,
// and the signature swaying light-columns background. `phase` (seconds) drives the sway.
func drawGaugeScreenPS2(_ lcd: LCD, state: GaugeState, theme: Theme, blinkOn: Bool, phase: Double) {
    let ink = theme.lcdOn.cgColor, dim = theme.lcdDimText.cgColor
    let card = opColor(0x4E86E6)            // PS2 memory-card blue
    let pink = opColor(0xE06CC0)            // ○-button pink, weekly accent
    let sf = max(0, min(1, state.fraction))

    // swaying light columns rising from the bottom edge — the PS2 main-menu backdrop.
    // Distributed edge-to-edge across the full panel width, each column always visible.
    let cols = 26
    for i in 0..<cols {
        let x = Int((Double(i) / Double(cols - 1) * Double(lcd.W - 3)).rounded())
        let h = 20.0 + 30.0 * (0.5 + 0.5 * sin(phase * 0.7 + Double(i) * 0.55))
        let a = 0.10 + 0.10 * (0.5 + 0.5 * sin(phase * 1.1 + Double(i) * 0.9))
        let col = opColor(0x3A6AC8, CGFloat(a))
        let top = lcd.H - Int(h)
        for y in top..<lcd.H { lcd.px(x, y, col); lcd.px(x+1, y, col) }
    }

    lcdTextC(lcd, "BROWSER", 60, 5, ink)
    lcdLine(lcd, 8, 16, 111, 16, dim)

    // SESSION "memory card" — fuel remaining shown as free space
    lcdText(lcd, "SESSION", 8, 22, ink)
    lcdTextR(lcd, "\(Int((sf*100).rounded()))%", 112, 22, ink)
    segBar(lcd, x: 8, y: 34, w: 104, h: 16, sf, segs: 16, on: card, dim: dim, hide: state.low && !blinkOn)
    lcdText(lcd, "FREE", 8, 54, dim)
    lcdTextR(lcd, state.resetSeconds.map { fmtClock($0) } ?? "FULL", 112, 54, ink)

    // WEEKLY "memory card"
    lcdText(lcd, "WEEKLY", 8, 72, pink)
    lcdTextR(lcd, state.weekFraction.map { "\(Int(($0*100).rounded()))%" } ?? "--", 112, 72, pink)
    segBar(lcd, x: 8, y: 84, w: 104, h: 16, state.weekFraction, segs: 16, on: pink, dim: dim)
    lcdText(lcd, "FREE", 8, 104, dim)
    lcdTextR(lcd, state.weekResetSeconds.map { fmtLong($0) } ?? "--", 112, 104, ink)

    lcdLine(lcd, 8, 118, 111, 118, dim)
    lcdText(lcd, "PLAN", 8, 122, dim)
    lcdText(lcd, state.plan, 8 + PF.width("PLAN ", 1), 122, ink)
    lcdTextR(lcd, state.live ? "LIVE" : "EST", 112, 122, dim)
}

// MARK: - Screen: PS2 power-on. The console's iconic boot, rendered on the little LCD —
// glowing orbs rise out of the dark, gather into a slowly rotating (perspective-squashed)
// ring, then fling outward and dissolve into the Browser. `elapsed`/`duration` in seconds.
// Soft additive glows over the dark panel; caller cross-fades the Browser in underneath at
// the tail. Skipped under Reduce Motion / accessibility (gated by the caller).
func drawPS2Boot(_ lcd: LCD, theme: Theme, elapsed e: Double, duration D: Double) {
    let ctx = lcd.ctx
    let core = theme.lcdOn.usingColorSpace(.sRGB) ?? .white     // near-white orb centre
    let halo = theme.lcdGlow.usingColorSpace(.sRGB) ?? .blue    // blue bloom
    let W = Double(lcd.W), H = Double(lcd.H)
    let cx = W * 0.5, cy = H * 0.44                             // ring centre, a touch high

    func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }
    // one soft additive orb — position + radius in LCD cells, brightness 0…1
    func orb(_ x: Double, _ y: Double, _ r: Double, _ bright: Double) {
        let b = CGFloat(max(0, min(1, bright)))
        if b <= 0.004 { return }
        let p = CGPoint(x: lcd.ox + CGFloat(x) * lcd.cell, y: lcd.oy + CGFloat(y) * lcd.cell)
        let R = CGFloat(r) * lcd.cell
        let cols = [core.withAlphaComponent(b * 0.82).cgColor,
                    halo.withAlphaComponent(b * 0.42).cgColor,
                    halo.withAlphaComponent(0).cgColor] as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols,
                                 locations: [0, 0.26, 1]) else { return }  // small core, wide soft bloom
        ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: R, options: [])
    }

    ctx.saveGState()
    ctx.setShouldAntialias(true)
    ctx.setBlendMode(.plusLighter)

    // Every phase timing below was authored for a 4.8s boot; `s` stretches them proportionally so the
    // animation fills whatever duration D is passed (D = 9.0 to match ps2_startup.m4a) with the exact
    // same look, just slower. Anything already expressed relative to D scales its window by s too.
    let s = D / 4.8

    let N = 9
    let rx = 30.0, ry = 15.0                    // squashed ellipse ring (fake perspective)
    let dissolve = smooth(D - 1.5 * s, D - 0.2 * s, e)   // ring disperses & fades before the app resolves
    let spin = e * 1.15 / s                      // ring rotation (radians) — same total sweep over D

    // soft floor halo that swells as the ring assembles, then fades on dissolve
    orb(cx, cy + 4, 74, smooth(0.4 * s, 2.0 * s, e) * (1 - dissolve) * 0.26)

    for i in 0..<N {
        let a = Double(i) / Double(N) * 2 * .pi + spin
        let tx = cx + cos(a) * rx, ty = cy + sin(a) * ry            // gathered ring target
        let sx = cx + sin(Double(i) * 2.7) * 34                     // birth point: scattered,
        let sy = H + 18 + Double(i % 3) * 12                        // just below the panel
        let rise = smooth((0.15 + Double(i) * 0.05) * s, (1.7 + Double(i) * 0.05) * s, e)  // staggered
        let er = 1 - pow(1 - rise, 3)                              // ease-out
        var x = sx + (tx - sx) * er
        var y = sy + (ty - sy) * er
        x += cos(a) * dissolve * 42                                 // dissolve: drift outward
        y += sin(a) * dissolve * 42
        let bright = rise * (1 - dissolve) * 0.9
        orb(x, y, 8.5 + 3.5 * bright + 1.3 * sin(e * 4 + Double(i)), bright)
    }

    // climax: a big blue wash swells out from the ring to fill the whole panel as it lets go,
    // then fades — the light "expanding into the app" at the end of the boot.
    if dissolve > 0 {
        let bloom = CGFloat(sin(dissolve * .pi))                     // 0 → 1 → 0 across the dissolve
        let p = CGPoint(x: lcd.ox + CGFloat(cx) * lcd.cell, y: lcd.oy + CGFloat(cy) * lcd.cell)
        let R = CGFloat(50 + 115 * dissolve) * lcd.cell             // expands past the panel edges
        let cols = [core.withAlphaComponent(bloom * 0.30).cgColor,
                    halo.withAlphaComponent(bloom * 0.55).cgColor,
                    halo.withAlphaComponent(0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols,
                              locations: [0, 0.4, 1]) {
            ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: R, options: [])
        }
    }

    ctx.restoreGState()
}

// The original-Xbox "X" emblem: four green spikes with concave sides meeting at a bright core,
// top-lit like the boot-screen logo, sitting on a silver radial glow. `R` is the tip radius in
// points; `b` (0…1) fades the whole thing. Drawn in normal blend (it's a solid logo, not a bloom),
// so restore any additive state before calling. Reusable for the jewel/blades if we want it there.
func drawXboxX(_ ctx: CGContext, center P: CGPoint, R: CGFloat, b: CGFloat) {
    if b <= 0.004 { return }
    // 1. silver sphere glow behind it (bright centre → black) — present but tight, so the green X
    //    stays the hero rather than being washed out by the halo.
    let glow = [opColor(0xEAF6EC, b * 0.55), opColor(0xAFD8BA, b * 0.16), opColor(0x000000, 0)] as CFArray
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glow, locations: [0, 0.45, 1]) {
        ctx.drawRadialGradient(g, startCenter: P, startRadius: 0, endCenter: P, endRadius: R * 1.5, options: [])
    }
    // 2. concave 4-point star: sharp tips on the diagonals, gentle inward-bowed notches on the axes,
    //    with a solid core where the arms merge — a straight-edged star reads as a shuriken instead.
    func pt(_ deg: Double, _ r: CGFloat) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: P.x + CGFloat(cos(a)) * r, y: P.y + CGFloat(sin(a)) * r)
    }
    let tip = R, notch = R * 0.40, ctrl = R * 0.27     // wide arm bases, gently concave long edges
    let path = CGMutablePath()
    path.move(to: pt(0, notch))
    for k in 1..<8 {
        let v = pt(Double(k) * 45, k % 2 == 0 ? notch : tip)          // even=axis notch, odd=diagonal tip
        path.addQuadCurve(to: v, control: pt(Double(k) * 45 - 22.5, ctrl))
    }
    path.addQuadCurve(to: pt(0, notch), control: pt(-22.5, ctrl))     // close the last concave edge
    path.closeSubpath()
    // 3. fill with a top-lit gradient — bright lime up top, deep green toward the bottom
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let fill = [opColor(0xCDF15A, b), opColor(0x86C82E, b), opColor(0x3C7D18, b)] as CFArray
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: fill, locations: [0, 0.5, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: P.x, y: P.y - R), end: CGPoint(x: P.x, y: P.y + R), options: [])
    }
    // 4. bright core where the arms merge — the hot centre of the logo (still clipped to the star)
    ctx.setBlendMode(.plusLighter)
    let core = [opColor(0xF6FFD4, b * 0.60), opColor(0xCDF15A, b * 0.22), opColor(0xCDF15A, 0)] as CFArray
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: core, locations: [0, 0.5, 1]) {
        ctx.drawRadialGradient(g, startCenter: P, startRadius: 0, endCenter: P, endRadius: R * 0.5, options: [])
    }
    ctx.restoreGState()
}

// Original Xbox (2001) power-on, rendered in the device's green pixel-LCD vocabulary: a green
// energy nucleus swells and pulses while a swirl of sparks spirals inward and coalesces, then it
// ignites in a hot bloom on the audio's chord (~5.2s), resolves to the bevelled "X" sphere + XBOX
// wordmark, and finally recedes to black for the dashboard hand-off. Every window below was
// authored for a 7.3s boot (matches the trimmed xbox_startup clip); `s` scales them so any
// duration D keeps the exact same shape, just faster/slower — same trick as drawPS2Boot.
func drawXboxBoot(_ lcd: LCD, theme: Theme, elapsed e: Double, duration D: Double) {
    let ctx = lcd.ctx
    let W = Double(lcd.W), H = Double(lcd.H)
    let cx = W * 0.5, cy = H * 0.44                             // sphere centre, a touch high

    func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }
    // one soft additive orb — position + radius in LCD cells, brightness 0…1; hot green-white core
    // fading through Xbox green to transparent, matching the blades screen's palette.
    func orb(_ x: Double, _ y: Double, _ r: Double, _ bright: Double) {
        let b = CGFloat(max(0, min(1, bright)))
        if b <= 0.004 { return }
        let p = CGPoint(x: lcd.ox + CGFloat(x) * lcd.cell, y: lcd.oy + CGFloat(y) * lcd.cell)
        let R = CGFloat(r) * lcd.cell
        let cols = [opColor(0xEBFFC0, b * 0.90), opColor(0x8FD628, b * 0.50), opColor(0x2E6E12, 0)] as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols,
                                 locations: [0, 0.30, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: R, options: [])
    }

    ctx.saveGState()
    ctx.setShouldAntialias(true)
    ctx.setBlendMode(.plusLighter)

    let s = D / 7.3
    let build  = smooth(0.0,     2.2 * s, e)       // nucleus swells in
    let gather = smooth(1.6 * s, 4.4 * s, e)       // spark swirl converges to the core
    let ignite = smooth(4.5 * s, 5.2 * s, e)       // energy floods outward at the chord
    let flash  = sin(max(0, min(1, (e - 4.5 * s) / (1.2 * s))) * .pi)   // 0→1→0 bloom over the climax
    let settle = smooth(5.4 * s, 6.2 * s, e)       // sphere calms, XBOX wordmark resolves
    let fade   = smooth(6.4 * s, 7.3 * s, e)       // all light recedes to black for the hand-off
    let vis    = 1 - fade

    // 1. central nucleus that grows through the build; recedes as the logo takes over on settle
    orb(cx, cy, 6 + 20 * build + 5 * gather, (0.35 * build + 0.50 * gather) * vis * (1 - settle))

    // 2. charging ripple rings pulsing outward while it gathers, gone by ignition
    let rp0 = e / s
    for k in 0..<3 {
        let rp = (rp0 * 0.5 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
        let b = CGFloat((1 - rp) * build * (1 - ignite) * 0.45 * vis)
        if b > 0.004 {
            let p = CGPoint(x: lcd.ox + CGFloat(cx) * lcd.cell, y: lcd.oy + CGFloat(cy) * lcd.cell)
            ctx.setLineWidth(1.6 * lcd.cell)
            ctx.setStrokeColor(opColor(0x8FD628, b))
            ctx.addArc(center: p, radius: CGFloat(rp * 70) * lcd.cell, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            ctx.strokePath()
        }
    }

    // 3. swirling sparks spiralling inward — the coalescing energy
    let N = 14
    for i in 0..<N {
        let a = Double(i) / Double(N) * 2 * .pi + e * 1.6 / s           // shared rotation
        let rr = (60 + Double(i % 4) * 8) * (1 - gather) + (3 + 3 * sin(e * 3 + Double(i))) * gather
        let x = cx + cos(a) * rr
        let y = cy + sin(a) * rr * 0.72                                 // squashed for a little perspective
        orb(x, y, 5 + 3 * gather, (0.22 + 0.6 * gather) * (1 - ignite * 0.4) * build * vis * (1 - settle))
    }
    ctx.restoreGState()

    // 4. IGNITION — a hot bloom floods the panel on the chord, then recedes
    if flash > 0.001 {
        ctx.saveGState(); ctx.setBlendMode(.plusLighter); ctx.setShouldAntialias(true)
        let p = CGPoint(x: lcd.ox + CGFloat(cx) * lcd.cell, y: lcd.oy + CGFloat(cy) * lcd.cell)
        let R = CGFloat(30 + 150 * ignite) * lcd.cell                   // expands past the panel edges
        let bloom = CGFloat(flash) * CGFloat(vis)
        let cols = [opColor(0xF2FFD0, bloom * 0.55), opColor(0x8FD628, bloom * 0.65), opColor(0x2E6E12, 0)] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0, 0.45, 1]) {
            ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: R, options: [])
        }
        ctx.restoreGState()
    }

    // 5. the original-Xbox "X" over its silver glow + the XBOX wordmark, once it settles
    if settle > 0.01 {
        let sb = CGFloat(settle * vis)
        let p = CGPoint(x: lcd.ox + CGFloat(cx) * lcd.cell, y: lcd.oy + CGFloat(cy) * lcd.cell)
        ctx.saveGState(); ctx.setShouldAntialias(true)
        drawXboxX(ctx, center: p, R: 17 * lcd.cell, b: sb)
        ctx.restoreGState()
        lcdTextC(lcd, "XBOX", 60, 122, opColor(0x8FD628, sb), 2)         // wordmark below the sphere
    }
}

// MARK: - Screen: original Xbox "blades" — a translucent blade panel over a slow-rotating
// nebula X and rising green sparks, with a bottom command bar. `phase` (seconds) drives motion.
func drawGaugeScreenXbox(_ lcd: LCD, state: GaugeState, theme: Theme, blinkOn: Bool, phase: Double) {
    let ink = theme.lcdOn.cgColor, dim = theme.lcdDimText.cgColor
    let green = opColor(0x8FD628), lime = opColor(0xB6F24A)
    let bladeEdge = opColor(0x3A6E32)
    let sf = max(0, min(1, state.fraction))

    // --- animated background: nebula glow + slow-rotating translucent X + rising sparks ---
    let c = lcd.ctx
    c.saveGState(); c.setShouldAntialias(true)
    let cx = lcd.ox + 60 * lcd.cell, cy = lcd.oy + 84 * lcd.cell
    let neb = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: [opColor(0x2E6E12, 0.55), opColor(0x2E6E12, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(neb, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                         endCenter: CGPoint(x: cx, y: cy), endRadius: 64 * lcd.cell, options: [])
    let ang = phase * 0.22, arm = 48 * lcd.cell
    c.setLineCap(.round); c.setLineWidth(7 * lcd.cell); c.setStrokeColor(opColor(0x6FBF1A, 0.11))
    for k in 0..<2 {
        let a = ang + .pi/4 + Double(k) * .pi/2
        c.move(to: CGPoint(x: cx - CGFloat(cos(a)) * arm, y: cy - CGFloat(sin(a)) * arm))
        c.addLine(to: CGPoint(x: cx + CGFloat(cos(a)) * arm, y: cy + CGFloat(sin(a)) * arm))
    }
    c.strokePath()
    c.restoreGState()
    for i in 0..<16 {                                    // rising green sparks (Xbox boot nebula)
        let sx = (i * 41 + 7) % 114 + 3
        let speed = 5.0 + Double(i % 5) * 3.0
        var y = Double((i * 37) % 176) - phase * speed
        y = y.truncatingRemainder(dividingBy: 176); if y < 0 { y += 176 }
        let tw = 0.20 + 0.35 * (0.5 + 0.5 * sin(phase * 2 + Double(i)))
        let col = opColor(0x8FD628, CGFloat(tw))
        lcd.px(sx, Int(y), col); lcd.px(sx+1, Int(y), col)
    }

    lcdTextC(lcd, "XBOX", 60, 5, ink)

    // centred front blade with slimmer "blades" peeking behind it on both sides
    let bx0 = 11, by0 = 18, bx1 = 109, by1 = 148
    lcd.rectFill(3, 28, 6, 108, opColor(0x081A0C, 0.7))
    lcd.rectFill(111, 28, 6, 108, opColor(0x081A0C, 0.7))
    for yy in 28...136 { lcd.px(9, yy, bladeEdge); lcd.px(111, yy, bladeEdge) }
    // translucent front (selected) blade — lets the rotating X glow through, like a real Xbox blade
    lcd.rectFill(bx0, by0, bx1-bx0, by1-by0, opColor(0x08180C, 0.78))
    for xx in bx0...bx1 { lcd.px(xx, by0, bladeEdge); lcd.px(xx, by1, bladeEdge) }
    for yy in by0...by1 { lcd.px(bx0, yy, bladeEdge); lcd.px(bx1, yy, bladeEdge) }
    lcd.rectFill(bx0, by0, 3, by1-by0, green)            // bright blade spine

    let lx = 18, rx = 102
    lcdText(lcd, "SESSION", lx, 24, ink)
    lcdTextR(lcd, state.live ? "LIVE" : "EST", rx, 24, dim)
    lcdText(lcd, "\(Int((sf*100).rounded()))%", lx, 36, theme.a11y ? ink : lime, 3)
    segBar(lcd, x: lx, y: 66, w: rx-lx, h: 14, sf, segs: 12, on: green, dim: dim, hide: state.low && !blinkOn)
    lcdText(lcd, "REFILL", lx, 88, dim)
    lcdTextR(lcd, state.resetSeconds.map { fmtClock($0) } ?? "FULL", rx, 88, ink)

    lcdLine(lcd, lx, 102, rx, 102, dim)
    lcdText(lcd, "WEEKLY", lx, 108, lime)
    lcdTextR(lcd, state.weekFraction.map { "\(Int(($0*100).rounded()))%" } ?? "--", rx, 108, lime)
    segBar(lcd, x: lx, y: 120, w: rx-lx, h: 10, state.weekFraction, segs: 12, on: lime, dim: dim)
    lcdText(lcd, "WK RST", lx, 136, dim)
    lcdTextR(lcd, state.weekResetSeconds.map { fmtLong($0) } ?? "--", rx, 136, ink)

    // bottom command bar, matching the blade width
    lcd.rectFill(bx0, 154, bx1-bx0, 14, green)
    let barInk = opColor(0x05120A)
    lcdText(lcd, "PLAN", bx0 + 4, 158, barInk)
    lcdText(lcd, state.plan, bx0 + 4 + PF.width("PLAN ", 1), 158, barInk)
}

// MARK: - Screen: large-print gauge (tap the LCD to toggle) — one big focus + huge digits
func drawGaugeLargeScreen(_ lcd: LCD, state: GaugeState, theme: Theme, blinkOn: Bool) {
    let on = theme.lcdOn.cgColor, dim = theme.lcdDimText.cgColor, acc = theme.lcdAccent.cgColor
    let sf = max(0, min(1, state.fraction))

    // green → amber → red as it drains — but accessibility themes stay plain (no red/green reliance)
    let fuel = theme.a11y ? on : AppDelegate.fuelColor(sf).cgColor
    lcdTextC(lcd, "SESSION", 60, 6, dim)
    lcdTextC(lcd, "\(Int((sf*100).rounded()))%", 60, 16, fuel, 4)    // huge session %, 16…44

    // thick fuel bar
    let bx = 12, by = 54, bw = 96, bh = 18, segs = 12
    for x in bx...(bx+bw) { lcd.px(x, by, on); lcd.px(x, by+bh, on) }
    for y in by...(by+bh) { lcd.px(bx, y, on); lcd.px(bx+bw, y, on) }
    if !(state.low && !blinkOn) {
        let lit = Int((sf * Double(segs)).rounded())
        // Even edge-to-edge segments (see drawBar): a full bar reaches the right border.
        let innerL = bx + 2, innerR = bx + bw - 1
        let cell = Double(innerR - innerL) / Double(segs)
        for i in 0..<segs where i < lit {
            let x0 = innerL + Int((Double(i)   * cell).rounded())
            let x1 = innerL + Int((Double(i+1) * cell).rounded())
            lcd.rectFill(x0, by+2, max(1, x1 - x0 - 2), bh-3, fuel)
        }
    }

    // tokens used / tank size for this session window (compact, e.g. "USED 662K/2.5M")
    lcdTextC(lcd, "USED \(fmtTokens(state.used))/\(fmtTokens(state.budget))", 60, 76, on)

    // "REFILL IN" shows a countdown; "REFILL AT" shows the wall-clock time it lands (Store option).
    let atClock = Store.shared.refillClockTime
    lcdTextC(lcd, atClock ? "REFILL AT" : "REFILL IN", 60, 91, dim)
    let refillVal = state.resetSeconds.map { atClock ? fmtClockTime($0) : fmtClock($0) } ?? "FULL"
    lcdTextC(lcd, refillVal, 60, 103, on, 2)  // 103…117

    lcdLine(lcd, 10, 126, 109, 126, dim)
    if let wf = state.weekFraction {
        let wr = state.weekResetSeconds.map { fmtLong($0) } ?? ""
        lcdTextC(lcd, "WEEK \(Int((wf*100).rounded()))%  \(wr)", 60, 132, acc)
    } else {
        lcdTextC(lcd, "PLAN \(state.plan)", 60, 132, dim)
    }
    lcdTextC(lcd, "TAP TO EXIT", 60, 155, dim)
}

// MARK: - Screen: stats
struct StatsData {
    var fraction = 1.0
    var used = 0, budget = 1, today = 0, lifetime = 0
    var plan = "PRO"
    var resetSeconds: Int? = nil
    var cache = false
    var perModel: [(String, Int)] = []
    var live = false
    var weekFraction: Double? = nil
    var weekResetSeconds: Int? = nil
    var connNote: String? = nil   // why we're on a local estimate (nil when LIVE)
}

func drawStatsScreen(_ lcd: LCD, _ s: StatsData, theme: Theme, page: Int) {
    let on = theme.lcdOn.cgColor, dim = theme.lcdDimText.cgColor
    let title = page == 0 ? "STATS" : (page == 1 ? "STATS 2" : "LEGEND")
    if page == 2 {
        lcdTextC(lcd, title, 60, 5, on)
    } else {
        // Left-align the title so the longer "STATS 2" can't grow into the
        // right-aligned LIVE/EST badge (it read as "STATS 2 LIVE" jammed together).
        lcdText(lcd, title, 8, 5, on)
        lcdTextR(lcd, s.live ? "LIVE" : "EST", 112, 5, dim)
    }
    lcdLine(lcd, 8, 16, 111, 16, dim)

    func row(_ label: String, _ value: String, _ y: Int) {
        lcdText(lcd, label, 8, y, on)
        lcdTextR(lcd, value, 112, y, on)
    }
    if page == 0 {
        // confirmed / server-authoritative
        row("SESSION", "\(Int((s.fraction*100).rounded()))% LEFT", 22)
        // tokens left ≈ fuel fraction × the configured tank (an estimate scaled by your tank size)
        row("5H LEFT", fmtTokens(Int(s.fraction * Double(s.budget))), 34)
        row("RESET", s.resetSeconds.map { fmtClock($0) } ?? "--", 46)
        row("WEEK", s.weekFraction.map { "\(Int(($0*100).rounded()))% LEFT" } ?? "--", 58)
        row("PLAN", s.plan, 70)
        // local, unconfirmed (this machine's CLI only)
        lcdLine(lcd, 8, 84, 111, 84, dim)
        lcdTextC(lcd, "LOCAL · THIS MAC", 60, 86, dim)
        row("CLI 5H", fmtTokens(s.used), 100)
        row("CLI 24H", fmtTokens(s.today), 112)
        lcdText(lcd, "BY MODEL", 8, 126, dim)
        var y = 138
        for (name, tok) in s.perModel.prefix(2) {
            lcdText(lcd, name, 8, y, on)
            lcdTextR(lcd, fmtTokens(tok), 112, y, on)
            y += 12
        }
        if s.perModel.isEmpty { lcdTextC(lcd, "IDLE", 60, 140, dim) }
    } else if page == 1 {
        row("WEEK RST", s.weekResetSeconds.map { fmtLong($0) } ?? "--", 28)
        row("SOURCE", s.live ? "LIVE API" : "LOCAL", 42)
        lcdLine(lcd, 8, 58, 111, 58, dim)
        lcdTextC(lcd, "LOCAL · ~30 DAYS", 60, 60, dim)
        row("CLI 30D", fmtTokens(s.lifetime), 74)
        row("CACHE", s.cache ? "ON" : "OFF", 88)
        lcdLine(lcd, 8, 104, 111, 104, dim)
        lcdTextC(lcd, s.live ? "LIVE = OAUTH USAGE" : "EST = LOCAL TOKENS", 60, 108, dim)
        lcdTextC(lcd, "CLI = THIS MAC ONLY", 60, 120, dim)
        // When we're not live, say WHY right here — the full fix is in the menu's Connection Report.
        if let note = s.connNote, !s.live {
            lcdLine(lcd, 8, 136, 111, 136, dim)
            lcdTextC(lcd, "NO CLAUDE LINK", 60, 140, on)
            lcdTextC(lcd, note, 60, 152, on)
        }
    } else {
        // LEGEND — terse "term → meaning" so nothing on the other screens is a mystery
        func def(_ t: String, _ m: String, _ y: Int) { lcdText(lcd, t, 8, y, on); lcdTextR(lcd, m, 112, y, dim) }
        def("SESSION", "5H WINDOW", 24)
        def("WEEK", "7D WINDOW", 40)
        def("LIVE", "REAL USAGE", 56)
        def("EST", "LOCAL EST", 72)
        def("CLI", "THIS MAC", 88)
        def("%", "FUEL LEFT", 104)
        lcdLine(lcd, 8, 122, 111, 122, dim)
        lcdTextC(lcd, "OAUTH + LOCAL", 60, 128, dim)
    }
}

// MARK: - Screen: settings (soft-key navigated)
struct SettingRow { let label: String; let value: String; var estOnly = false }

func drawSettingsScreen(_ lcd: LCD, rows: [SettingRow], selected: Int, theme: Theme, live: Bool) {
    let on = theme.lcdOn.cgColor, dim = theme.lcdDimText.cgColor, bg = theme.lcdBG.cgColor
    lcdTextC(lcd, "SETTINGS", 60, 5, on)
    lcdLine(lcd, 8, 16, 111, 16, dim)

    // 13px rows (kept in sync with settingsRowAt) so the full list fits above the footer at y=149.
    var y = 20
    for (i, r) in rows.enumerated() {
        let inactive = r.estOnly && live          // estimate-only rows do nothing when LIVE
        let value = inactive ? r.value + " EST" : r.value
        if i == selected {
            lcd.rectFill(6, y-2, 108, 12, on)     // inverted highlight
            lcdText(lcd, r.label, 10, y, bg)
            lcdTextR(lcd, value, 110, y, bg)
        } else {
            let c = inactive ? dim : on
            lcdText(lcd, r.label, 10, y, c)
            lcdTextR(lcd, value, 110, y, c)
        }
        y += 13
    }
    lcdLine(lcd, 8, 149, 111, 149, dim)
    lcdTextC(lcd, "TAP ROW TO CHANGE", 60, 154, dim)
}

// MARK: - Screen: settings REPORT tab (connection diagnostics + on-screen buttons)
// Fixed grid rects for the two touch buttons, shared by the drawing here and the hit-testing in
// DeviceView so a tap always lands where the button is drawn.
enum ReportUI {
    static let recheck = CGRect(x: 6,  y: 126, width: 52, height: 22)
    static let copy    = CGRect(x: 62, y: 126, width: 52, height: 22)
}

// A bordered on-LCD button with a centred label; fills solid (label knocked out) when pressed.
func lcdButton(_ lcd: LCD, _ rect: CGRect, _ label: String, on: CGColor, bg: CGColor, pressed: Bool) {
    let x0 = Int(rect.minX), y0 = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
    if pressed { lcd.rectFill(x0, y0, w + 1, h + 1, on) }
    for xx in x0...(x0+w) { lcd.px(xx, y0, on); lcd.px(xx, y0+h, on) }
    for yy in y0...(y0+h) { lcd.px(x0, yy, on); lcd.px(x0+w, yy, on) }
    lcdTextC(lcd, label, x0 + w/2, y0 + (h-7)/2, pressed ? bg : on)
}

func drawReportScreen(_ lcd: LCD, _ info: AppModel.ConnInfo, theme: Theme, pressed: Int?, copied: Bool) {
    let on = theme.lcdOn.cgColor, dim = theme.lcdDimText.cgColor, bg = theme.lcdBG.cgColor
    lcdTextC(lcd, "CONNECTION", 60, 5, on)
    lcdLine(lcd, 8, 16, 111, 16, dim)

    // headline state word(s), centred
    lcdTextC(lcd, info.live ? "CONNECTED" : "NO LINK", 60, 22, on)
    lcdTextC(lcd, info.short, 60, 34, info.live ? dim : on)

    func row(_ label: String, _ value: String, _ y: Int, _ vc: CGColor) {
        lcdText(lcd, label, 8, y, dim); lcdTextR(lcd, value, 112, y, vc)
    }
    let tokenStr = info.tokenFound.map { $0 ? "OK" : "NEEDED" } ?? "--"
    row("SIGN IN", tokenStr, 52, info.tokenFound == false ? on : dim)
    row("SOURCE",  info.live ? "LIVE API" : "LOCAL EST", 66, on)
    row("LAST OK", info.lastOK, 80, on)
    row("CHECKED", info.checked, 94, on)

    lcdLine(lcd, 8, 110, 111, 110, dim)

    // the two touch buttons
    lcdButton(lcd, ReportUI.recheck, "RECHECK", on: on, bg: bg, pressed: pressed == 0)
    lcdButton(lcd, ReportUI.copy,    "COPY",    on: on, bg: bg, pressed: pressed == 1)

    if copied { lcdTextC(lcd, "COPIED TO CLIPBOARD", 60, 156, on) }
    else      { lcdTextC(lcd, "TAP THE BUTTONS", 60, 156, dim) }
}

// MARK: - Screen: main gauge, "not signed in" state (in-app sign-in, no terminal)
enum SignInUI {
    static let button = CGRect(x: 24, y: 92, width: 72, height: 22)   // the big SIGN IN key
}

// Shown on the main screen when no Claude login is recognized on this Mac. Lets the user connect
// their account from inside the app (opens the browser) instead of running `/login` in a terminal.
func drawSignInScreen(_ lcd: LCD, theme: Theme, pressed: Bool) {
    let on = theme.lcdOn.cgColor, dim = theme.lcdDimText.cgColor, bg = theme.lcdBG.cgColor
    lcdTextC(lcd, "TOKEN FUEL", 60, 6, on)
    lcdLine(lcd, 8, 16, 111, 16, dim)

    lcdTextC(lcd, "NOT SIGNED IN", 60, 26, on)

    lcdTextC(lcd, "CONNECT YOUR CLAUDE", 60, 46, dim)
    lcdTextC(lcd, "ACCOUNT TO SEE YOUR", 60, 56, dim)
    lcdTextC(lcd, "REAL FUEL LEVEL.", 60, 66, dim)

    lcdButton(lcd, SignInUI.button, "SIGN IN", on: on, bg: bg, pressed: pressed)

    lcdLine(lcd, 8, 124, 111, 124, dim)
    lcdTextC(lcd, "OPENS YOUR BROWSER", 60, 132, dim)
    lcdTextC(lcd, "NO TERMINAL NEEDED", 60, 144, dim)
    lcdTextC(lcd, "TAP TO SIGN IN", 60, 156, pressed ? on : dim)
}

// MARK: - Screen: settings ADMIN tab (preview the first-run bubble + the sign-in panel)
enum AdminUI {
    static let intro  = CGRect(x: 18, y: 46, width: 84, height: 22)   // SHOW BUBBLE
    static let signin = CGRect(x: 18, y: 76, width: 84, height: 22)   // SHOW SIGN IN
}

func drawAdminScreen(_ lcd: LCD, theme: Theme, pressed: Int?) {
    let on = theme.lcdOn.cgColor, dim = theme.lcdDimText.cgColor, bg = theme.lcdBG.cgColor
    lcdTextC(lcd, "ADMIN", 60, 5, on)
    lcdLine(lcd, 8, 16, 111, 16, dim)

    lcdTextC(lcd, "PREVIEW SCREENS", 60, 28, dim)

    lcdButton(lcd, AdminUI.intro,  "SHOW BUBBLE",  on: on, bg: bg, pressed: pressed == 0)
    lcdButton(lcd, AdminUI.signin, "SHOW SIGN IN", on: on, bg: bg, pressed: pressed == 1)

    lcdLine(lcd, 8, 120, 111, 120, dim)
    let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "DEV"
    lcdText(lcd, "VERSION", 8, 126, dim); lcdTextR(lcd, ver, 112, 126, on)
    lcdTextC(lcd, "TAP A BUTTON", 60, 156, dim)
}
