import Foundation

// The `claudeAiOauth` credential blob that Claude Code stores — read from the same places the CLI
// uses (macOS Keychain generic-password item, or ~/.claude/.credentials.json on Linux/older installs)
// so Token Fuel and the CLI share one login. We read the access token from it to call the usage
// endpoint, and — now that the app can sign in on its own — write refreshed tokens back to it.
struct Credentials {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Int?            // epoch milliseconds, as Claude Code stores it
    var raw: [String: Any]         // every other field (scopes, subscriptionType, …) preserved verbatim

    static let service = "Claude Code-credentials"
    static var account: String { NSUserName() }
    static var filePath: String { ("~/.claude/.credentials.json" as NSString).expandingTildeInPath }

    // True when the access token is expired or within a minute of it — time to refresh.
    var isExpired: Bool {
        guard let ms = expiresAt else { return false }   // no expiry recorded → assume usable
        return Date().timeIntervalSince1970 * 1000 >= Double(ms) - 60_000
    }

    // MARK: Load

    static func load() -> Credentials? {
        if let data = FileManager.default.contents(atPath: filePath), let c = parse(data) { return c }
        if let data = keychainRead(), let c = parse(data) { return c }
        return nil
    }

    private static func parse(_ data: Data) -> Credentials? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = o["claudeAiOauth"] as? [String: Any],
              let tok = oauth["accessToken"] as? String, !tok.isEmpty else { return nil }
        let refresh = oauth["refreshToken"] as? String
        let exp = (oauth["expiresAt"] as? Int) ?? (oauth["expiresAt"] as? NSNumber)?.intValue
        oauth.removeValue(forKey: "accessToken")   // keep `raw` as the "everything else" bucket
        oauth.removeValue(forKey: "refreshToken")
        oauth.removeValue(forKey: "expiresAt")
        return Credentials(accessToken: tok, refreshToken: refresh, expiresAt: exp, raw: oauth)
    }

    // MARK: Save (write back to wherever the CLI keeps them, so both apps stay in sync)

    func save() {
        var oauth = raw
        oauth["accessToken"] = accessToken
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt { oauth["expiresAt"] = expiresAt }
        guard let data = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth],
                                                     options: [.sortedKeys]) else { return }
        // If a credentials file is what's in use (Linux/older installs), update it too.
        if FileManager.default.fileExists(atPath: Self.filePath) {
            try? data.write(to: URL(fileURLWithPath: Self.filePath))
        }
        Self.keychainWrite(data)   // Keychain is the source of truth on macOS
    }

    // MARK: Keychain via /usr/bin/security (no extra entitlements; matches the CLI's own item)

    private static func keychainRead() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
    }

    private static func keychainWrite(_ data: Data) {
        guard let json = String(data: data, encoding: .utf8) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        // -U updates the existing item in place; -w passes the secret as one argv element (no shell).
        p.arguments = ["add-generic-password", "-U", "-a", account, "-s", service,
                       "-D", "application password", "-w", json]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }
}
