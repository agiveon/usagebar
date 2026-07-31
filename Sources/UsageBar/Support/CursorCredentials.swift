import Foundation
import SQLite3

// Read Cursor.app's session from its VS Code state DB.
//
// Recent Cursor stores auth as a JWT in state.vscdb's ItemTable under
//   key = 'cursorAuth/accessToken'
// The `sub` claim of that JWT looks like "auth0|user_ABC..." — we take the
// last "|"-separated segment as the user id, then construct the same
// WorkosCursorSessionToken cookie value Cursor's web dashboard sends:
//   WorkosCursorSessionToken=<userId>%3A%3A<jwt>   (%3A%3A == "::")
//
// Reference: raycast/extensions extensions/agent-usage/src/cursor/auth.ts
enum CursorCredentials {

    private static let stateDBPath =
        ("~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
         as NSString).expandingTildeInPath

    /// Full cookie *value* (the part after `WorkosCursorSessionToken=`) ready
    /// to plug into a Cookie header.  Returns nil if Cursor isn't signed in
    /// or the token has expired.
    static func loadCookieValue() -> String? {
        guard let jwt = readAccessToken(from: stateDBPath),
              let (userId, exp) = decodeSubAndExp(jwt: jwt) else {
            return nil
        }
        // 60 s freshness margin — refuse just-expiring tokens.
        if let exp, exp <= Date().addingTimeInterval(60) { return nil }
        return "\(userId)%3A%3A\(jwt)"
    }

    // MARK: - SQLite

    private static func readAccessToken(from path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // Copy to avoid write-lock contention with Cursor.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-cursor-\(UUID().uuidString).db").path
        do {
            try? FileManager.default.removeItem(atPath: tmp)
            try FileManager.default.copyItem(atPath: path, toPath: tmp)
        } catch { return nil }
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // `?immutable=1` tells SQLite the file won't change under it, which
        // lets us skip the -wal/-shm sidecars (WAL-mode DBs otherwise fail to
        // prepare statements when opened from a bare copy).
        var db: OpaquePointer?
        let uri = "file:\(tmp)?immutable=1"
        guard sqlite3_open_v2(uri, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cstr = sqlite3_column_text(stmt, 0) else { return nil }
        let raw = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    // MARK: - JWT decoding

    /// Returns (userId, exp?) from a JWT's payload.
    private static func decodeSubAndExp(jwt: String) -> (String, Date?)? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }

        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub  = obj["sub"] as? String else { return nil }

        // "auth0|user_ABC" → "user_ABC" ; also handle unprefixed subs.
        let userId = sub.split(separator: "|").last.map(String.init) ?? sub
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard !userId.isEmpty,
              userId.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }

        let exp = (obj["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return (userId, exp)
    }
}
