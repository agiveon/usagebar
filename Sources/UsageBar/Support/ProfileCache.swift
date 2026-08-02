import Foundation

// A small in-memory cache of account emails, keyed by provider id.  Cuts
// our API load in half: instead of fetching /profile alongside /usage on
// every 60–120 s poll, we fetch profile once and reuse the email for the
// next half-hour.  Anthropic's undocumented endpoints rate-limit hard
// when we're too chatty, and there's no reason to be.
actor ProfileCache {
    static let shared = ProfileCache()

    private struct Entry {
        let email: String
        let at: Date
    }
    private var entries: [String: Entry] = [:]

    private static let defaultTTL: TimeInterval = 30 * 60

    func get(_ key: String, maxAge: TimeInterval = defaultTTL) -> String? {
        guard let e = entries[key],
              Date().timeIntervalSince(e.at) < maxAge else { return nil }
        return e.email
    }

    func set(_ key: String, email: String) {
        entries[key] = Entry(email: email, at: Date())
    }

    func clear(_ key: String) {
        entries.removeValue(forKey: key)
    }
}
