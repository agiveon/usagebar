import Foundation
import Security

// Where Claude Code actually keeps its OAuth tokens on macOS:
//
//   `Claude Code-credentials`               ← the default install
//   `Claude Code-credentials-<8-hex-suffix>` ← every extra install with
//                                              its own CLAUDE_CONFIG_DIR
//
// The suffix is a hash Claude Code derives from the config dir path.  We
// don't need to reproduce it — we just enumerate every generic-password
// item whose service starts with "Claude Code-credentials" and treat each
// as its own account.  This lets us support N accounts without knowing
// anything about paths or hashes.
//
// A few installs (CI images, --dangerously-skip setups) put the token in
// `<configDir>/.credentials.json` instead — we still read that as a
// fallback for a specific service if Keychain returns nothing.
enum ClaudeCredentials {

    struct DiscoveredItem {
        let service: String
        let account: String?
        /// The `sub` claim from this item's token — Anthropic's stable
        /// user id.  Two Keychain items with the same `sub` belong to the
        /// same account; the registry uses this to dedupe before polling
        /// so we don't fight ourselves against Anthropic's per-user
        /// rate-limit.  Nil if we can't read/parse the token.
        let subject: String?
    }

    /// Every `Claude Code-credentials*` Keychain service on this Mac that
    /// *plausibly* belongs to Claude Code.  Attribute-only lookup — no
    /// Keychain access prompt.
    ///
    /// The service-name prefix alone isn't enough of a filter: after a
    /// clean restart we've seen unrelated Apple items (Handoff encryption
    /// keys, legacy "No user account" placeholders from 2020) share the
    /// same prefix.  We additionally reject items whose `acct` attribute
    /// clearly isn't a Claude user identifier.
    static func discoverKeychainServices() -> [String] {
        discoverKeychainItems().map(\.service)
    }

    static func discoverKeychainItems() -> [DiscoveredItem] {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String:       kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }

        var out: [DiscoveredItem] = []
        for item in items {
            guard let svc = item[kSecAttrService as String] as? String,
                  svc == "Claude Code-credentials"
                    || svc.hasPrefix("Claude Code-credentials-") else { continue }
            let acct = item[kSecAttrAccount as String] as? String
            guard looksLikeClaudeAccount(acct) else { continue }
            // Try to decode the JWT sub — quick shell to `security`,
            // then base64url decode of the middle segment.  If it fails
            // (Keychain denies, token malformed) we still include the
            // item and let the poll figure it out.
            let sub = fromKeychain(service: svc).flatMap(subjectFromJWT)
            out.append(DiscoveredItem(service: svc, account: acct, subject: sub))
        }
        return out.sorted { a, b in
            if a.service == "Claude Code-credentials" { return true }
            if b.service == "Claude Code-credentials" { return false }
            return a.service < b.service
        }
    }

    /// Decode `sub` from a JWT's payload without hitting the network.
    /// Everything runs on-device.
    static func subjectFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = obj["sub"] as? String, !sub.isEmpty else { return nil }
        return sub
    }

    /// Reject obvious non-Claude acct patterns.  Claude Code writes an
    /// email or username here (e.g. "agiveon", "amir@example.com").  Apple
    /// system items write things like "handoff-own-encryption-key" or
    /// "No user account".
    private static func looksLikeClaudeAccount(_ acct: String?) -> Bool {
        guard let acct, !acct.isEmpty else { return false }
        let lower = acct.lowercased()
        let rejectedExact: Set<String> = ["no user account", "nil", "-", "(null)"]
        if rejectedExact.contains(lower) { return false }
        let rejectedPrefixes = [
            "handoff-", "com.apple.", "apple-", "icloud-", "iwork-",
        ]
        if rejectedPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
        // Reject strings with whitespace — real usernames / emails don't have any.
        if acct.contains(where: { $0.isWhitespace }) { return false }
        return true
    }

    /// Read the access token from a specific Keychain service.  Falls back
    /// to `<configDir>/.credentials.json` if provided and Keychain is empty.
    static func loadAccessToken(keychainService: String,
                                fallbackConfigDir: String? = nil) -> String? {
        if let t = fromKeychain(service: keychainService) { return t }
        if let dir = fallbackConfigDir, let t = fromCredentialsFile(configDir: dir) {
            return t
        }
        return nil
    }

    // MARK: - Sources

    private struct Envelope: Decodable {
        struct OAuth: Decodable { let accessToken: String? }
        let claudeAiOauth: OAuth?
    }

    private static func decodeEnvelope(_ data: Data) -> String? {
        if let env = try? JSONDecoder().decode(Envelope.self, from: data),
           let t = env.claudeAiOauth?.accessToken, !t.isEmpty {
            return t
        }
        return nil
    }

    private static func fromCredentialsFile(configDir: String) -> String? {
        let path = "\(configDir)/.credentials.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return decodeEnvelope(data)
    }

    private static func fromKeychain(service: String) -> String? {
        guard let raw = ShellRunner.run(
            "/usr/bin/security",
            args: ["find-generic-password", "-s", service, "-w"],
            timeout: 5.0
        ) else { return nil }
        guard let jsonData = raw.data(using: .utf8) else { return nil }
        return decodeEnvelope(jsonData)
    }

    /// Permanently delete a `Claude Code-credentials*` Keychain item.  Used
    /// by the Settings "Delete" button.  Returns `.success` when the item
    /// is gone (or was never there), `.failed(reason)` otherwise so the
    /// UI can surface a real message rather than silently no-op.
    enum DeleteResult {
        case success
        case failed(reason: String)
    }
    static func deleteKeychainItem(service: String) -> DeleteResult {
        let result = ShellRunner.runDetailed(
            "/usr/bin/security",
            args: ["delete-generic-password", "-s", service],
            timeout: 5.0
        )
        if result.exit == 0 { return .success }
        // Exit 44 = SecKeychainSearchCopyNext "item not found" — for our
        // purposes that's fine, the item is already gone.
        if result.exit == 44 { return .success }
        let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(reason: msg.isEmpty
                       ? "security exit \(result.exit)"
                       : msg)
    }
}
