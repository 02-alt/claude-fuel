import Foundation

// One usage window (session or weekly) as reported by Anthropic's server.
struct LiveWindow {
    let utilization: Double   // 0…100 percent used
    let resetsAt: Date
    var remaining: Double { max(0, 1 - utilization/100) }
}

struct LiveUsage {
    let session: LiveWindow?
    let week: LiveWindow?
}

// Why a live fetch did (or didn't) work — captured so the app can explain "can't connect to
// Claude" instead of silently dropping to the local estimate. Ordered roughly from "your fault"
// (not signed in) to "our/Anthropic's fault" (server error).
enum LiveFetchResult {
    case ok(LiveUsage)      // 200 + parsed usage
    case noToken            // no OAuth credentials on this Mac (not signed in to Claude Code)
    case unauthorized       // 401/403 — token expired or revoked; sign in again
    case rateLimited        // 429 — too many requests; back off
    case http(Int)          // some other HTTP status from the endpoint
    case offline(String)    // network error / timeout (the String is the OS description)
    case badData            // 200 but the body didn't parse as expected

    var usage: LiveUsage? { if case .ok(let u) = self { return u }; return nil }
}

// Reads the real, authoritative usage from Anthropic's undocumented OAuth usage
// endpoint (the same data behind Claude Code's `/usage`). Uses your local OAuth
// token — no API key. This endpoint is unofficial and may change.
enum LiveUsageClient {

    private static let ua = "claude-code/2.1.201"   // must start with claude-code/ or the endpoint 429s

    static func accessToken() -> String? {
        Credentials.load()?.accessToken
    }

    // Synchronously mint a fresh access token from the stored refresh token. Called when the current
    // token is expired or the endpoint says it's stale (401), so one sign-in lasts indefinitely.
    private static func refreshTokenSync(timeout: TimeInterval = 20) -> String? {
        let sem = DispatchSemaphore(value: 0)
        var newTok: String?
        OAuthLogin.refresh { newTok = $0; sem.signal() }
        _ = sem.wait(timeout: .now() + timeout + 2)
        return newTok
    }

    static let endpoint = "https://api.anthropic.com/api/oauth/usage"

    // Blocking fetch — call on a background queue. Returns just the usage (nil on any failure);
    // callers that want to know *why* it failed use fetchDetailed instead.
    static func fetchSync(timeout: TimeInterval = 12) -> LiveUsage? {
        fetchDetailed(timeout: timeout).usage
    }

    // Blocking fetch that reports why it succeeded or failed — call on a background queue.
    // Self-heals an expired token: refreshes proactively when we know it's stale, and once reactively
    // if the endpoint answers 401 — so a single sign-in keeps working without the CLI running.
    static func fetchDetailed(timeout: TimeInterval = 12) -> LiveFetchResult {
        guard let creds = Credentials.load() else { return .noToken }
        var tok = creds.accessToken
        if creds.isExpired, let fresh = refreshTokenSync() { tok = fresh }
        let result = fetchOnce(token: tok, timeout: timeout)
        if case .unauthorized = result, let fresh = refreshTokenSync() {
            return fetchOnce(token: fresh, timeout: timeout)
        }
        return result
    }

    // A single authenticated request to the usage endpoint with a given token.
    private static func fetchOnce(token tok: String, timeout: TimeInterval) -> LiveFetchResult {
        guard let url = URL(string: endpoint) else { return .offline("bad endpoint URL") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let sem = DispatchSemaphore(value: 0)
        var result: LiveFetchResult = .offline("no response")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { result = .offline(err.localizedDescription); return }
            guard let http = resp as? HTTPURLResponse else { result = .offline("no response"); return }
            switch http.statusCode {
            case 200:
                guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    result = .badData; return
                }
                func window(_ key: String) -> LiveWindow? {
                    guard let w = o[key] as? [String: Any] else { return nil }
                    let u = (w["utilization"] as? Double) ?? (w["utilization"] as? NSNumber)?.doubleValue ?? 0
                    guard let rs = w["resets_at"] as? String, let d = parseISO(rs) else { return nil }
                    return LiveWindow(utilization: u, resetsAt: d)
                }
                result = .ok(LiveUsage(session: window("five_hour"), week: window("seven_day")))
            case 401, 403: result = .unauthorized
            case 429:      result = .rateLimited
            default:       result = .http(http.statusCode)
            }
        }.resume()
        if sem.wait(timeout: .now() + timeout + 2) == .timedOut { return .offline("request timed out") }
        return result
    }

    // Handles microsecond fractional seconds like "2026-07-29T22:59:59.065724+00:00".
    static func parseISO(_ s: String) -> Date? {
        var str = s
        if let dot = str.firstIndex(of: "."),
           let end = str[dot...].firstIndex(where: { $0 == "+" || $0 == "Z" || $0 == "-" }) {
            str.removeSubrange(dot..<end)
        }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: str)
    }
}
