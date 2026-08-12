import Foundation
import CryptoKit
import Network
import AppKit

// In-app sign-in to Claude, so users never have to open a terminal and run `/login`. This mirrors
// Claude Code's own OAuth (PKCE) flow — same public client, same loopback redirect — and stores the
// resulting tokens in the shared Keychain item, so the usage endpoint works exactly as it does after
// a CLI login. Also handles silent refresh, which is what makes that one sign-in last indefinitely.
//
// All endpoints are undocumented and mirrored from the Claude Code binary; treat as best-effort and
// keep the local-estimate fallback. Verified against claude 2.1.220.
enum OAuthLogin {
    static let clientID   = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorize  = "https://claude.com/cai/oauth/authorize"
    static let tokenURL   = "https://platform.claude.com/v1/oauth/token"
    static let redirectPort: UInt16 = 40342            // fixed port the OAuth client has registered
    static var redirectURI: String { "http://localhost:\(redirectPort)/callback" }
    static let scope = "org:create_api_key user:profile user:inference"

    enum LoginError: Error, CustomStringConvertible {
        case portBusy               // 40342 already held (e.g. a CLI login is mid-flight)
        case cancelled              // user closed the browser / timed out
        case stateMismatch          // returned state didn't match (possible CSRF / stale tab)
        case rateLimited            // token endpoint returned 429 — a known Anthropic-side throttle
        case exchangeFailed(String) // token endpoint rejected the code / network error
        var description: String {
            switch self {
            case .portBusy:            return "Port 40342 is busy — finish or cancel any Claude Code login in progress, then try again."
            case .cancelled:           return "Sign-in was cancelled."
            case .stateMismatch:       return "Sign-in couldn't be verified — please try again."
            case .rateLimited:         return "Claude is rate-limiting sign-in — a known Anthropic-side throttle. Stop retrying, wait a few minutes, or sign in with the Claude Code CLI."
            case .exchangeFailed(let m): return "Couldn't complete sign-in: \(m)"
            }
        }
    }

    // MARK: - Public entry points

    // Kicks off interactive sign-in: opens the browser, waits for the loopback redirect, exchanges the
    // code for tokens, and saves them. Completion is delivered on the main queue.
    static func signIn(completion: @escaping (Result<Void, Error>) -> Void) {
        let verifier  = randomURLSafe(64)
        let challenge = codeChallenge(for: verifier)
        let state     = randomURLSafe(32)

        let listener: CallbackListener
        do { listener = try CallbackListener(port: redirectPort) }
        catch { return finish(completion, .failure(LoginError.portBusy)) }

        listener.onResult = { params in
            listener.stop()
            guard let code = params["code"], params["state"] == state else {
                return finish(completion, .failure(params["state"] == state ? LoginError.cancelled : LoginError.stateMismatch))
            }
            exchange(code: code, verifier: verifier, state: state) { result in
                finish(completion, result)
            }
        }
        listener.start()

        var comps = URLComponents(string: authorize)!
        comps.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(comps.url!)

        // Give up (and free the port) if the user never comes back.
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            if listener.stop() { finish(completion, .failure(LoginError.cancelled)) }
        }
    }

    // Silent refresh using the stored refresh token. Returns the new access token on success. Safe to
    // call from a background queue; completion runs on the caller's queue (not forced to main).
    static func refresh(completion: @escaping (String?) -> Void) {
        guard let creds = Credentials.load(), let rt = creds.refreshToken else { return completion(nil) }
        postToken(["grant_type": "refresh_token", "refresh_token": rt, "client_id": clientID]) { json, _, _ in
            guard let json, let access = json["access_token"] as? String else { return completion(nil) }
            save(json, into: creds)
            completion(access)
        }
    }

    // MARK: - Token exchange / refresh plumbing

    private static func exchange(code: String, verifier: String, state: String,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        postToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
            "state": state,
        ]) { json, err, status in
            guard let json else {
                // A 429 here is the known Anthropic OAuth throttle — flag it distinctly so the UI can
                // offer the "wait / use CLI" path instead of a generic failure.
                if status == 429 { return completion(.failure(LoginError.rateLimited)) }
                return completion(.failure(LoginError.exchangeFailed(err ?? "unknown error")))
            }
            guard let access = json["access_token"] as? String, !access.isEmpty else {
                // 200 OK but no token in the body — surface what the server *did* send back.
                let keys = json.keys.sorted().joined(separator: ", ")
                return completion(.failure(LoginError.exchangeFailed(
                    "the server didn't return a token (response fields: \(keys.isEmpty ? "none" : keys))")))
            }
            save(json, into: Credentials.load())
            completion(.success(()))
        }
    }

    // Merge a token response into the credential blob (preserving fields we didn't get back) and save.
    private static func save(_ json: [String: Any], into existing: Credentials?) {
        var creds = existing ?? Credentials(accessToken: "", refreshToken: nil, expiresAt: nil, raw: [:])
        creds.accessToken = (json["access_token"] as? String) ?? creds.accessToken
        if let rt = json["refresh_token"] as? String { creds.refreshToken = rt }
        if let secs = (json["expires_in"] as? Int) ?? (json["expires_in"] as? NSNumber)?.intValue {
            creds.expiresAt = Int(Date().timeIntervalSince1970 * 1000) + secs * 1000
        }
        if let scope = json["scope"] as? String {
            creds.raw["scopes"] = scope.split(separator: " ").map(String.init)
        }
        creds.save()
    }

    // POSTs a token request. On success delivers the parsed JSON; on failure delivers a short,
    // human-readable reason (HTTP status + any server error, or the transport error) so sign-in
    // failures aren't all flattened into one opaque message.
    // POSTs a token request. Delivers `(json, nil, 200)` on success, or `(nil, reason, status)` with a
    // short, human-readable reason (HTTP status + any server error, or the transport error) so sign-in
    // failures aren't all flattened into one opaque message. `status` is the HTTP code (0 on transport
    // error) so callers can special-case throttling (429) without string-matching the reason.
    private static func postToken(_ body: [String: Any], completion: @escaping ([String: Any]?, String?, Int) -> Void) {
        guard let url = URL(string: tokenURL),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            return completion(nil, "couldn't build the request", 0)
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-code/2.1.201", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { return completion(nil, err.localizedDescription, 0) }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
            guard status == 200 else {
                // 429 is the known Anthropic OAuth throttle; the caller maps it to `.rateLimited` and
                // shows dedicated guidance, so we don't build a reason string for it here.
                if status == 429 { return completion(nil, "rate limited", 429) }
                // Otherwise prefer the server's own OAuth error. `error` may be a plain string
                // (OAuth style) or a nested object `{type, message}` (Anthropic API style).
                let errObj = json?["error"] as? [String: Any]
                let detail = (json?["error_description"] as? String)
                    ?? (errObj?["message"] as? String)
                    ?? (json?["error"] as? String)
                    ?? data.flatMap { String(data: $0.prefix(200), encoding: .utf8) }?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = (detail?.isEmpty == false) ? " — \(detail!)" : ""
                return completion(nil, "HTTP \(status)\(suffix)", status)
            }
            guard let json else { return completion(nil, "HTTP 200 but the response wasn't valid JSON", status) }
            completion(json, nil, status)
        }.resume()
    }

    // MARK: - PKCE helpers

    private static func randomURLSafe(_ bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return base64url(Data(buf))
    }
    private static func codeChallenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func finish(_ completion: @escaping (Result<Void, Error>) -> Void, _ r: Result<Void, Error>) {
        DispatchQueue.main.async { completion(r) }
    }
}

// A one-shot HTTP listener on the loopback redirect port. Accepts a single GET /callback request,
// pulls `code`/`state` from the query, shows a "you can close this tab" page, then stops.
private final class CallbackListener {
    private let listener: NWListener
    private var done = false
    var onResult: (([String: String]) -> Void)?

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: .global())
    }

    // Returns true if this call actually stopped it (so timeout vs. success don't double-fire).
    @discardableResult func stop() -> Bool {
        guard !done else { return false }
        done = true
        listener.cancel()
        return true
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8),
                  let line = req.split(separator: "\r\n").first,
                  let pathPart = line.split(separator: " ").dropFirst().first,
                  let comps = URLComponents(string: "http://localhost\(pathPart)") else {
                conn.cancel(); return
            }
            var params: [String: String] = [:]
            for item in comps.queryItems ?? [] { params[item.name] = item.value }

            let html = "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'>"
                + "<h2>Token Fuel is signed in \u{2705}</h2><p>You can close this tab and return to the app.</p></body></html>"
            let body = Data(html.utf8)
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(resp.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
            self.onResult?(params)
        }
    }
}
