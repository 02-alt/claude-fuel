import AppKit

// Owns the live gauge state: loads usage in the background, computes the current
// window's fuel level, and ticks a 1-second clock for the countdown + blink.
final class AppModel {
    static let shared = AppModel()

    private(set) var state = GaugeState()
    private(set) var todayTokens = 0
    private(set) var lifetimeTokens = 0

    var onUpdate: (() -> Void)?
    // Fired once per drain→refuel cycle when the tank actually comes back, so the UI can play a
    // menu-bar "topping up" flourish. Independent of the notification setting.
    var onRefuel: (() -> Void)?

    private var block: UsageBlock?
    private var lastLive: LiveUsage?
    private var lastLiveAt = Date.distantPast

    // Connection diagnostics — why the live (OAuth usage) fetch last succeeded or failed, so the
    // app can tell you "can't connect to Claude" instead of silently showing a local estimate.
    private(set) var lastFetch: LiveFetchResult?
    private(set) var lastFetchAt: Date?
    private(set) var lastSuccessAt: Date?
    private let liveInterval: TimeInterval = 30    // don't hammer the endpoint
    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private let store = Store.shared

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Store.changed, object: nil)
    }

    func start() {
        reload()
        scheduleRefresh()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.recompute()
        }
        // Refresh immediately when the Mac wakes, so the gauge/notifications aren't stale after sleep.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.reload(forceLive: true)
        }
    }

    @objc private func settingsChanged() {
        scheduleRefresh()
        reload()
    }

    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        let interval = max(3, store.refreshSeconds)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    func reload(forceLive: Bool = false) {
        let path = store.projectsPath
        let cache = store.includeCacheReads
        let hours = store.windowHours
        // Timed refreshes throttle the endpoint; a manual "Refresh Now" always re-fetches.
        let shouldFetchLive = forceLive || Date().timeIntervalSince(lastLiveAt) > liveInterval
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let entries = UsageReader.load(projectsPath: path, includeCacheReads: cache)
            let blk = UsageReader.currentBlock(entries: entries, windowHours: hours)
            let cal = Calendar.current
            let today = entries.filter { cal.isDateInToday($0.date) }.reduce(0) { $0 + $1.tokens }
            let life = entries.reduce(0) { $0 + $1.tokens }
            let fetch: LiveFetchResult? = shouldFetchLive ? LiveUsageClient.fetchDetailed() : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.block = blk
                self.todayTokens = today
                self.lifetimeTokens = life
                if let fetch {
                    self.lastFetch = fetch
                    self.lastFetchAt = Date()
                }
                if let live = fetch?.usage, live.session != nil {
                    self.lastLive = live
                    self.lastLiveAt = Date()
                    self.lastSuccessAt = Date()
                    self.autoCalibrateTank()     // keep the tank in sync with real usage, if enabled
                } else if shouldFetchLive, Date().timeIntervalSince(self.lastLiveAt) > 180 {
                    self.lastLive = nil          // gone stale (token expired / offline)
                }
                self.recompute()
            }
        }
    }

    // With AUTO TANK on, size the tank from real data: tokens used this window ÷ the fraction of the
    // window the server says is used. Only when there's meaningful usage (>5%), and only applied when
    // it moves the tank by >5% (avoids churn / thrash). Same math as the manual calibrate button.
    private func autoCalibrateTank() {
        guard store.autoTank, let sess = lastLive?.session, let b = block, b.isActive, b.used > 0 else { return }
        let usedFrac = min(1, sess.utilization / 100)
        guard usedFrac > 0.05 else { return }
        let raw = (Double(b.used) / usedFrac / 1_000_000).rounded() * 1_000_000
        let tank = min(500_000_000, max(1_000_000, Int(raw)))
        if abs(tank - store.budget) > max(1_000_000, store.budget / 20) { store.budget = tank }
    }

    private func recompute() {
        let budget = max(1, store.budget)
        var s = GaugeState()
        s.budget = budget
        s.plan = store.plan.name

        // local token breakdown (informational / fallback)
        if let b = block, b.isActive {
            s.used = b.used
            s.perModel = b.perModel.sorted { $0.value > $1.value }.map { (shortModel($0.key), $0.value) }
        }

        if let live = lastLive, let sess = live.session {
            // REAL server-side fuel + reset (recomputed each tick so it counts down)
            s.live = true
            s.fraction = sess.remaining
            s.resetSeconds = max(0, Int(sess.resetsAt.timeIntervalSinceNow))
            if let w = live.week {
                s.weekFraction = w.remaining
                s.weekResetSeconds = max(0, Int(w.resetsAt.timeIntervalSinceNow))
            }
        } else if let b = block, b.isActive {
            // fallback: estimate from local usage vs configured tank
            s.fraction = max(0, 1 - Double(b.used) / Double(budget))
            s.resetSeconds = max(0, Int(b.end.timeIntervalSinceNow))
        } else {
            s.fraction = 1
            s.resetSeconds = nil
        }
        checkRefillNotification(s)
        checkRefuelAnimation(s)
        state = s
        onUpdate?()
    }

    // Fire a notification when the session refills — but only if you'd actually run low first,
    // so it means "you can use Claude again." State lives in UserDefaults to survive relaunches.
    // Fires the "tokens are back" notification exactly ONCE per drain→refuel cycle, using an armed
    // latch so it can never spam. When we first run low we schedule a single system notification for
    // the reset moment (a fixed "refill" id, so re-adds always replace rather than stack) and latch;
    // we only unlatch — allowing a future notification — once the fuel has actually come back.
    // Scheduling (vs. polling + sending) means it's still delivered on time if the Mac was asleep.
    private func checkRefillNotification(_ s: GaugeState) {
        let d = UserDefaults.standard
        let armedKey = "notify.armed"
        guard store.notifyOnReset else {
            Notify.cancelRefill(); d.set(false, forKey: armedKey); return
        }
        let armed = d.bool(forKey: armedKey)
        let targetKey = "notify.targetAt"   // absolute reset time we last scheduled for (drift check)
        // Only ever arm from REAL server data (s.live). The local fallback estimate uses a rolling
        // block boundary that isn't the actual Claude reset, and a mis-sized tank can read "low" when
        // the real session is fine — arming off that would fire a false "tokens are back" banner at the
        // wrong time. An already-scheduled notification (armed while live) is left in place on a
        // connection blip, since its fire time is the real reset moment.
        if !armed, s.live, s.fraction <= 0.15, let rs = s.resetSeconds, rs > 60 {
            Notify.scheduleRefill(after: Double(rs))   // one notification for this window
            d.set(true, forKey: armedKey)
            d.set(Date().addingTimeInterval(Double(rs)).timeIntervalSinceReferenceDate, forKey: targetKey)
        } else if armed, s.fraction > 0.5 {
            d.set(false, forKey: armedKey)             // refueled → ready to arm again next time
        } else if armed, s.live, s.fraction <= 0.5, let rs = s.resetSeconds, rs > 60 {
            // Reset time drifted while we were waiting (server recalculated resets_at). Reschedule so
            // the banner still lands at the real moment instead of the frozen original. `want` is
            // stable between live fetches (now + rs == resets_at), so this only fires on a real change;
            // the 2-minute threshold ignores sub-second clock jitter and avoids per-tick churn.
            let want = Date().addingTimeInterval(Double(rs))
            let have = Date(timeIntervalSinceReferenceDate: d.double(forKey: targetKey))
            if abs(want.timeIntervalSince(have)) > 120 {
                Notify.scheduleRefill(after: Double(rs))
                d.set(want.timeIntervalSinceReferenceDate, forKey: targetKey)
            }
        }
    }

    // Drain→refuel latch driving the menu-bar flourish. Separate from the notification latch so the
    // animation plays whether or not "notify on reset" is on. Armed once the tank runs low; released
    // (and onRefuel fired) the moment the fuel is actually back. Persisted so it can still fire on the
    // first tick after a relaunch that happened across the reset.
    private func checkRefuelAnimation(_ s: GaugeState) {
        let d = UserDefaults.standard
        let key = "anim.refuelArmed"
        if d.bool(forKey: key) {
            if s.fraction > 0.5 {
                d.set(false, forKey: key)
                onRefuel?()
            }
        } else if s.live, s.fraction <= 0.15, let rs = s.resetSeconds, rs > 60 {
            d.set(true, forKey: key)   // arm from real data only — see checkRefillNotification
        }
    }

    // MARK: - Connection status (why we're LIVE or falling back to a local estimate)

    enum ConnStatus {
        case live           // connected — showing real server usage
        case noToken        // not signed in to Claude Code on this Mac
        case expired        // token expired / revoked → sign in again
        case rateLimited    // 429 from the usage endpoint
        case offline        // network error / timeout
        case serverError    // other HTTP error / bad response
        case unknown        // haven't fetched yet
    }

    func connectionStatus() -> ConnStatus {
        // If we have a fresh live reading, we're connected regardless of the last blip.
        if state.live { return .live }
        switch lastFetch {
        case .some(.ok):        return .live
        case .some(.noToken):   return .noToken
        case .some(.unauthorized): return .expired
        case .some(.rateLimited):  return .rateLimited
        case .some(.offline):   return .offline
        case .some(.http), .some(.badData): return .serverError
        case .none:             return .unknown
        }
    }

    // Terse label for the small LCD (≤ ~16 chars).
    func connectionShort() -> String {
        switch connectionStatus() {
        case .live:        return "LIVE"
        case .noToken:     return "NOT SIGNED IN"
        case .expired:     return "SIGN IN AGAIN"
        case .rateLimited: return "RATE LIMITED"
        case .offline:     return "OFFLINE"
        case .serverError: return "SERVER ERROR"
        case .unknown:     return "NO LIVE DATA"
        }
    }

    // "3s ago" / "5m ago" / "2h 10m ago" (or "never"), for both the LCD report tab and the report text.
    private func ago(_ d: Date?) -> String {
        guard let d else { return "never" }
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s/60)m ago" }
        return "\(s/3600)h \((s%3600)/60)m ago"
    }

    // Compact connection facts for the on-device REPORT tab.
    struct ConnInfo {
        let status: ConnStatus
        let short: String       // terse status label (LIVE / OFFLINE / …)
        let live: Bool          // currently showing real server data
        let tokenFound: Bool?   // nil = don't know yet
        let lastOK: String      // "5m ago" / "never"
        let checked: String     // "3s ago" / "never"
    }
    func connectionInfo() -> ConnInfo {
        let st = connectionStatus()
        let token: Bool?
        switch st {
        case .noToken:  token = false
        case .unknown:  token = nil
        default:        token = true
        }
        return ConnInfo(status: st, short: connectionShort(), live: state.live,
                        tokenFound: token, lastOK: ago(lastSuccessAt), checked: ago(lastFetchAt))
    }

    // A full, copyable diagnostic for the Connection Report (menu + on-device COPY button).
    func connectionReport() -> String {
        let status = connectionStatus()
        let headline: String
        switch status {
        case .live:        headline = "Connected — showing real usage from Claude."
        case .noToken:     headline = "Not connected — you're not signed in to Claude Code on this Mac."
        case .expired:     headline = "Not connected — your Claude login has expired or was revoked."
        case .rateLimited: headline = "Not connected — Claude is rate-limiting requests (429). Try again shortly."
        case .offline:     headline = "Not connected — couldn't reach Claude (network offline or blocked)."
        case .serverError: headline = "Not connected — the usage endpoint returned an unexpected response."
        case .unknown:     headline = "No live reading yet."
        }
        var detail = ""
        if case .some(.offline(let msg)) = lastFetch { detail = "Network: \(msg)\n" }
        if case .some(.http(let code)) = lastFetch { detail = "HTTP status: \(code)\n" }

        let creds = (status == .noToken)
            ? "not found (Keychain “Claude Code-credentials” / ~/.claude/.credentials.json)"
            : "found"
        let src = state.live ? "live (OAuth usage endpoint)" : "local estimate (this Mac's CLI logs)"

        var fix = ""
        switch status {
        case .noToken, .expired:
            fix = "Fix: choose “Sign in to Claude…” from the menu (or run `/login` in the Claude Code CLI), then “Refresh Now.”"
        case .offline:
            fix = "Fix: check your internet connection / VPN / firewall, then choose “Refresh Now.”"
        case .rateLimited:
            fix = "Fix: wait a minute, then choose “Refresh Now.”"
        case .serverError:
            fix = "Fix: try again later; the endpoint is unofficial and may be temporarily unavailable."
        case .live, .unknown:
            break
        }

        return """
        Token Fuel — Connection Report

        \(headline)

        Credentials: \(creds)
        Endpoint: \(LiveUsageClient.endpoint)
        \(detail)Currently showing: \(src)
        Last successful reading: \(ago(lastSuccessAt))
        Last checked: \(ago(lastFetchAt))
        \(fix.isEmpty ? "" : "\n\(fix)")
        """
    }

    private func shortModel(_ m: String) -> String {
        let x = m.replacingOccurrences(of: "claude-", with: "").uppercased()
        if x.contains("OPUS") { return "OPUS" }
        if x.contains("SONNET") { return "SONNET" }
        if x.contains("HAIKU") { return "HAIKU" }
        if x.contains("FABLE") { return "FABLE" }
        return String(x.prefix(6))
    }
}
