import UserNotifications

// Thin wrapper over macOS user notifications.
enum Notify {
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static let refillID = "refill"

    // Schedule the "tokens are back" notification for the exact reset moment. The system delivers it
    // at that time independently of whether the app is actively polling — so it's no longer late when
    // the Mac was asleep / the app wasn't ticking at the reset. When the app is running the HALO chime
    // is played from willPresent (see AppDelegate); we also set a fallback sound below so the banner
    // is never silent if the app isn't running to play the chime.
    static func scheduleRefill(after seconds: TimeInterval) {
        let c = UNMutableNotificationContent()
        c.title = "Your Claude tokens are back"
        c.body = "The session limit just reset — you're topped up again."
        // Fallback system sound so the banner is never silent. When the app is running at the reset
        // moment, willPresent returns [.banner] (no .sound) and plays the shield-recharge chime in
        // code — the system suppresses this sound, so there's no double. When the app ISN'T running
        // (Mac asleep / quit at reset), willPresent never fires, so this guarantees a sound.
        c.sound = .default
        // Time-Sensitive so the "you can use Claude again" banner breaks through Focus / Do Not
        // Disturb — this is its one meaningful moment. Honored only when the app is signed by our
        // Apple Developer team with the matching entitlement + Developer ID provisioning profile;
        // without that the system silently downgrades it to the default level (no crash).
        c.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let req = UNNotificationRequest(identifier: refillID, content: c, trigger: trigger)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    static func cancelRefill() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [refillID])
    }
}
