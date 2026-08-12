import Foundation

// Reads your Claude account tier from ~/.claude.json so the gauge can auto-connect
// to your real plan (e.g. organizationRateLimitTier = "default_claude_max_5x").
enum Account {
    // The signed-in account's `oauthAccount` blob from ~/.claude.json (tier, uuid, email, …).
    static func oauthAccount() -> [String: Any]? {
        let path = ("~/.claude.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["oauthAccount"] as? [String: Any]
    }

    static func detectedTier() -> String? {
        guard let tier = oauthAccount()?["organizationRateLimitTier"] as? String, !tier.isEmpty
        else { return nil }
        return tier
    }

    // Stable per-account id — used to gate developer-only UI (the Settings → ADMIN tab) so it
    // appears only on the owner's Claude account, not on anyone else who installs the app.
    static func accountUUID() -> String? {
        (oauthAccount()?["accountUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static let ownerUUID = "dc2ca319-3828-491c-af40-22729ad79cf9"
    static var isOwner: Bool { accountUUID() == ownerUUID }

    static func detectedPlanID() -> String? {
        guard let t = detectedTier()?.lowercased() else { return nil }
        if t.contains("max_20") || t.contains("max20") { return "max20" }
        if t.contains("max_5")  || t.contains("max5")  { return "max5" }
        if t.contains("team") || t.contains("enterprise") { return "max20" }
        if t.contains("pro")  { return "pro" }
        if t.contains("free") { return "free" }
        return nil
    }
}
