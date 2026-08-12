import AppKit
import Combine

// MARK: - Gauge state passed to the renderer

struct GaugeState {
    var fraction: Double = 1        // fuel remaining, 0…1
    var used: Int = 0               // tokens consumed in current window (local estimate)
    var budget: Int = 1_000_000     // "tank" size for the plan/window
    var plan: String = "PRO"        // plan name shown on the LCD
    var resetSeconds: Int? = nil    // seconds until the session window refuels (nil = idle)
    var perModel: [(String, Int)] = []

    // live (real, server-side) data from the OAuth usage endpoint
    var live = false
    var weekFraction: Double? = nil
    var weekResetSeconds: Int? = nil

    var low: Bool { fraction < 0.16 }
}

// MARK: - Plans

struct Plan {
    let id: String
    let name: String          // shown on LCD (kept short)
    let defaultBudget: Int    // tokens per window (user-editable estimate)

    static let all: [Plan] = [
        Plan(id: "free", name: "FREE", defaultBudget:   2_000_000),
        Plan(id: "pro",  name: "PRO",  defaultBudget:  15_000_000),
        Plan(id: "max5", name: "MAX5", defaultBudget:  50_000_000),
        Plan(id: "max20",name: "MAX20",defaultBudget: 200_000_000),
        Plan(id: "api",  name: "API",  defaultBudget:  10_000_000),
    ]
    static func by(id: String) -> Plan { all.first { $0.id == id } ?? all[1] }
}

// MARK: - Theme

enum Emblem { case none, ps2, xbox, op1, powerRing, pager }   // signature badge drawn on the body
enum ConsoleUI { case none, ps2, xbox }                       // console-authentic animated gauge screen

struct Theme {
    let id: String
    let name: String
    // metal body
    let metalHi, metal, metalLo, edge: NSColor
    let screwHi, screwLo: NSColor
    let brand: NSColor
    let bezel, bezelInner: NSColor
    // buttons
    let btnHi, btnLo, btnGlyph: NSColor
    // lcd
    let lcdBG, lcdOn: NSColor
    let lcdGlow: NSColor
    let lcdAccent: NSColor      // second colour, used for the WEEKLY gauge

    /// Secondary/"dim" ink derived to stay legible on lcdBG for ANY theme (≈ halfway to lcdOn,
    /// which keeps it well above Apple's 4.5:1 contrast minimum).
    /// The accessibility theme pushes it brighter to reach WCAG AAA (7:1) even for secondary text.
    var lcdDimText: NSColor { lcdBG.blended(withFraction: a11y ? 0.72 : 0.5, of: lcdOn) ?? lcdOn }
    /// Whether the body reads as dark — used to tint the popover chrome to match.
    var isDark: Bool { (metal.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) < 0.45 }
    var emblem: Emblem = .none  // signature badge on the body (PS2 face buttons, Xbox jewel)
    var translucent = false     // see-through "liquid glass" body over a circuit board
    var frost: Double = 0.05    // uniform frost haze strength for translucent bodies
    var a11y = false            // accessibility mode: no grid/gloss/blink, brighter secondary ink
    var reflective = false      // real reflective LCD: dark ink on a pale panel, recessed (no glow halo)
    var opStyle = false         // OP-1 "FX" screen: black OLED with multi-colour neon vector graphics
    var console: ConsoleUI = .none  // console-authentic animated gauge (PS2 Browser / Xbox blades)

    // Black "beeper" body with a bright cool-white screen — matches the original ref.
    static let noir = Theme(
        id: "noir", name: "Noir",
        metalHi: hex(0x34353B), metal: hex(0x191A1F), metalLo: hex(0x050506), edge: hex(0x45474F),
        screwHi: hex(0x5B5D65), screwLo: hex(0x0A0B0D),
        brand: hex(0x8B9099),
        bezel: hex(0x0A0B0D), bezelInner: hex(0x000000),
        btnHi: hex(0x2D2F35), btnLo: hex(0x101116), btnGlyph: hex(0xC6CCD4),
        lcdBG: hex(0xA7ADB0), lcdOn: hex(0x1E2229),
        lcdGlow: hex(0xC6CDD4), lcdAccent: hex(0x1E2229), emblem: .pager, reflective: true
    )

    // Teenage Engineering OP-1: pale aluminium body, dark screen, and the signature
    // blue / green / white / orange encoder knobs (drawn as the emblem). Orange accent.
    static let op1 = Theme(
        id: "op1", name: "OP-1",
        metalHi: hex(0xF5F6F7), metal: hex(0xE3E4E7), metalLo: hex(0xC6C8CD), edge: hex(0xAEB1B7),
        screwHi: hex(0xFBFBFC), screwLo: hex(0xB2B5BB),
        brand: hex(0x8A8D93),
        bezel: hex(0x121317), bezelInner: hex(0x000000),
        btnHi: hex(0xF3F4F5), btnLo: hex(0xCFD1D6), btnGlyph: hex(0x5A5D63),
        lcdBG: hex(0x0A0C10), lcdOn: hex(0xEAF0F6),
        lcdGlow: hex(0x2C7290), lcdAccent: hex(0xE0559A), emblem: .op1, opStyle: true
    )

    // Original PlayStation 2: matte-black deck with the signature deep-blue disc glow. The screen
    // recreates the PS2 "Browser" — a dark-blue panel with memory-card free-space bars and the
    // swaying light-columns background. ○-button pink is the weekly accent.
    static let ps2 = Theme(
        id: "ps2", name: "PS2",
        metalHi: hex(0x2B2D34), metal: hex(0x131419), metalLo: hex(0x030305), edge: hex(0x36435E),
        screwHi: hex(0x46536B), screwLo: hex(0x080A0E),
        brand: hex(0x4C86E0),
        bezel: hex(0x05080E), bezelInner: hex(0x081426),
        btnHi: hex(0x232630), btnLo: hex(0x0A0B10), btnGlyph: hex(0x6C9BEA),
        lcdBG: hex(0x040A18), lcdOn: hex(0xDCE9FF),
        lcdGlow: hex(0x4E86E6), lcdAccent: hex(0x9FC0FF), emblem: .ps2, console: .ps2
    )

    // Original Xbox: black chassis with the green "jewel". The screen recreates the Xbox
    // "blades" dashboard — a translucent blade panel over a slow-rotating nebula X and rising
    // green sparks, with a bottom command bar. Lime is the weekly accent.
    static let xbox = Theme(
        id: "xbox", name: "Xbox",
        metalHi: hex(0x252C24), metal: hex(0x111512), metalLo: hex(0x030403), edge: hex(0x33512F),
        screwHi: hex(0x3F4C3A), screwLo: hex(0x070A07),
        brand: hex(0x8FC91E),
        bezel: hex(0x050A05), bezelInner: hex(0x0A1608),
        btnHi: hex(0x1E2419), btnLo: hex(0x090C08), btnGlyph: hex(0x9AD62B),
        lcdBG: hex(0x03140A), lcdOn: hex(0xE6F6D8),
        lcdGlow: hex(0x7FC81E), lcdAccent: hex(0xB6F24A), emblem: .xbox, console: .xbox
    )

    // Translucent "crystal" console — a circuit board seen through green liquid glass.
    static let xray = Theme(
        id: "xray", name: "X-Ray",
        metalHi: hex(0x1E5B2E), metal: hex(0x123D1E), metalLo: hex(0x06170C), edge: hex(0x7CFF4A),
        screwHi: hex(0x2C3A2C), screwLo: hex(0x050805),
        brand: hex(0xBFF593),
        bezel: hex(0x05140A), bezelInner: hex(0x06160A),
        btnHi: hex(0x1C3A22), btnLo: hex(0x08160D), btnGlyph: hex(0xB6F58A),
        lcdBG: hex(0xA9B79A), lcdOn: hex(0x1B2415),
        lcdGlow: hex(0xA6E07C), lcdAccent: hex(0x1B2415), emblem: .powerRing, translucent: true, reflective: true
    )

    // Aqua-blue transparent case (clear-blue console) — green board seen through cyan glass.
    static let aqua = Theme(
        id: "aqua", name: "Aqua",
        metalHi: hex(0x1E4E5B), metal: hex(0x123742), metalLo: hex(0x061318), edge: hex(0x4ADAFF),
        screwHi: hex(0x2C3A3E), screwLo: hex(0x050809),
        brand: hex(0x9BE8FF),
        bezel: hex(0x04121A), bezelInner: hex(0x061620),
        btnHi: hex(0x123842), btnLo: hex(0x081418), btnGlyph: hex(0x9BE8FF),
        lcdBG: hex(0x9FB4B8), lcdOn: hex(0x14242A),
        lcdGlow: hex(0x86D8EE), lcdAccent: hex(0x14242A), emblem: .powerRing, translucent: true, reflective: true
    )

    // Smoke / frosted-clear case — greyed board behind a heavier frost.
    static let smoke = Theme(
        id: "smoke", name: "Smoke",
        metalHi: hex(0x3A4145), metal: hex(0x23282B), metalLo: hex(0x0C0F10), edge: hex(0xC4CCD0),
        screwHi: hex(0x394044), screwLo: hex(0x070809),
        brand: hex(0xC7CED2),
        bezel: hex(0x0A0E10), bezelInner: hex(0x0C1012),
        btnHi: hex(0x2A3033), btnLo: hex(0x0E1113), btnGlyph: hex(0xCBD2D6),
        lcdBG: hex(0xADB2B4), lcdOn: hex(0x1E2224),
        lcdGlow: hex(0xC0C8CC), lcdAccent: hex(0x1E2224), emblem: .powerRing, translucent: true, frost: 0.16, reflective: true
    )

    // Accessibility-first: soft off-white on dark grey (avoids white-on-black halation),
    // amber weekly, no grid/gloss/flashing. All text ≥ WCAG AAA (7:1) contrast.
    static let clarity = Theme(
        id: "clarity", name: "Clarity",
        metalHi: hex(0x3A3A3C), metal: hex(0x2A2A2C), metalLo: hex(0x151517), edge: hex(0x4E4E52),
        screwHi: hex(0x5C5C60), screwLo: hex(0x0E0E10),
        brand: hex(0xB4B4B8),
        bezel: hex(0x000000), bezelInner: hex(0x000000),
        btnHi: hex(0x3C3C3E), btnLo: hex(0x1A1A1C), btnGlyph: hex(0xF2F2F2),
        lcdBG: hex(0x1C1C1E), lcdOn: hex(0xF2F2F2),
        lcdGlow: hex(0xC9C9CE), lcdAccent: hex(0xFFB300), a11y: true
    )

    // Authentic 1990s alphanumeric beeper: matte graphite plastic shell and a reflective
    // pea-green LCD with dark, single-colour ink — modelled on the Motorola Advisor. Its badge
    // is a moulded speaker grille with a red alert LED.
    static let pager = Theme(
        id: "pager", name: "Pager",
        metalHi: hex(0x4C4F54), metal: hex(0x3B3E43), metalLo: hex(0x2A2D31), edge: hex(0x54575C),
        screwHi: hex(0x5A5D62), screwLo: hex(0x171819),
        brand: hex(0x9A9EA3),
        bezel: hex(0x191A1C), bezelInner: hex(0x050506),
        btnHi: hex(0x44474C), btnLo: hex(0x25272B), btnGlyph: hex(0xC7CBD0),
        lcdBG: hex(0xA9B49B), lcdOn: hex(0x22271C),
        lcdGlow: hex(0xB8C79E), lcdAccent: hex(0x22271C), emblem: .pager, reflective: true
    )

    static let all: [Theme] = [clarity, pager, noir, op1, ps2, xbox, xray, aqua, smoke]
    static func by(id: String) -> Theme { all.first { $0.id == id } ?? noir }

    private static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF)/255,
                green:    CGFloat((v >> 8) & 0xFF)/255,
                blue:     CGFloat(v & 0xFF)/255, alpha: 1)
    }
}

// MARK: - Persisted settings store

final class Store: ObservableObject {
    static let shared = Store()
    private let d = UserDefaults.standard

    static let changed = Notification.Name("ClaudeFuelSettingsChanged")

    @Published var planID: String { didSet { d.set(planID, forKey: "planID"); commit() } }
    @Published var budget: Int { didSet { d.set(budget, forKey: "budget"); commit() } }
    @Published var windowHours: Double { didSet { d.set(windowHours, forKey: "windowHours"); commit() } }
    @Published var includeCacheReads: Bool { didSet { d.set(includeCacheReads, forKey: "cacheReads"); commit() } }
    @Published var themeID: String { didSet { d.set(themeID, forKey: "themeID"); commit() } }
    @Published var projectsPath: String { didSet { d.set(projectsPath, forKey: "projectsPath"); commit() } }
    @Published var refreshSeconds: Double { didSet { d.set(refreshSeconds, forKey: "refreshSeconds"); commit() } }
    @Published var menuWeekly: Bool { didSet { d.set(menuWeekly, forKey: "menuWeekly"); commit() } }
    @Published var largePrint: Bool { didSet { d.set(largePrint, forKey: "largePrint") } }  // big-text gauge (tap LCD)
    @Published var refillClockTime: Bool { didSet { d.set(refillClockTime, forKey: "refillClockTime"); commit() } }  // big-text gauge shows "REFILL AT <time>" instead of a countdown
    @Published var notifyOnReset: Bool { didSet { d.set(notifyOnReset, forKey: "notifyOnReset"); commit() } }  // notify when tokens refill
    @Published var autoTank: Bool { didSet { d.set(autoTank, forKey: "autoTank"); commit() } }  // keep the tank auto-calibrated from live usage

    var isAutoPlan: Bool { planID == "auto" }
    // "auto" follows the tier detected from your Claude account.
    var plan: Plan {
        if planID == "auto" { return Plan.by(id: Account.detectedPlanID() ?? "pro") }
        return Plan.by(id: planID)
    }
    var theme: Theme { Theme.by(id: themeID) }

    private init() {
        let defaultProjects = ("~/.claude/projects" as NSString).expandingTildeInPath
        let pid = d.string(forKey: "planID") ?? "auto"
        planID = pid
        let resolved = (pid == "auto") ? Plan.by(id: Account.detectedPlanID() ?? "pro") : Plan.by(id: pid)
        budget = d.object(forKey: "budget") as? Int ?? resolved.defaultBudget
        windowHours = d.object(forKey: "windowHours") as? Double ?? 5
        includeCacheReads = d.object(forKey: "cacheReads") as? Bool ?? false
        themeID = d.string(forKey: "themeID") ?? "clarity"
        projectsPath = d.string(forKey: "projectsPath") ?? defaultProjects
        refreshSeconds = d.object(forKey: "refreshSeconds") as? Double ?? 15
        menuWeekly = d.object(forKey: "menuWeekly") as? Bool ?? false   // menu bar shows weekly only if enabled
        largePrint = d.object(forKey: "largePrint") as? Bool ?? false
        refillClockTime = d.object(forKey: "refillClockTime") as? Bool ?? false
        notifyOnReset = d.object(forKey: "notifyOnReset") as? Bool ?? false
        autoTank = d.object(forKey: "autoTank") as? Bool ?? false
    }

    func applyPlanDefaults() { budget = plan.defaultBudget }

    private func commit() {
        NotificationCenter.default.post(name: Store.changed, object: nil)
    }
}
