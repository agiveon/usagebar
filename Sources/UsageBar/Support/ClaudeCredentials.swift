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

    /// Every `Claude Code-credentials*` Keychain service on this Mac.
    /// Attribute-only lookup — doesn't trigger a Keychain access prompt.
    static func discoverKeychainServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String:       kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }

        var services: [String] = []
        for item in items {
            guard let svc = item[kSecAttrService as String] as? String else { continue }
            if svc == "Claude Code-credentials"
                || svc.hasPrefix("Claude Code-credentials-") {
                services.append(svc)
            }
        }
        // Default first; then remaining sorted so ordering is stable
        // across scans and matches whatever hash algorithm Claude uses.
        return services.sorted { a, b in
            if a == "Claude Code-credentials" { return true }
            if b == "Claude Code-credentials" { return false }
            return a < b
        }
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
    /// by the Settings "Delete" button to clean up orphans from failed
    /// prior sign-in attempts.
    static func deleteKeychainItem(service: String) -> Bool {
        let ok = ShellRunner.run(
            "/usr/bin/security",
            args: ["delete-generic-password", "-s", service],
            timeout: 5.0
        )
        return ok != nil
    }
}
