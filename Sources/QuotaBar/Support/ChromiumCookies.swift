import Foundation
import SQLite3
import CommonCrypto

// Read + decrypt a cookie from a Chromium-based app's Cookies SQLite DB
// (Cursor is a VS Code fork, so it uses Chromium's cookie encryption scheme
// with a per-app password stored in the login Keychain under
// "<AppName> Safe Storage").
//
// Decryption spec (macOS):
//   key   = PBKDF2-HMAC-SHA1("<keychain-password>", "saltysalt", 1003, 16)
//   IV    = 16 spaces
//   ct    = encrypted_value[3..]      (drops "v10"/"v11" prefix)
//   pt    = AES-128-CBC-decrypt(ct, key, IV)
//   value = PKCS7-unpad(pt)  →  UTF-8
//
// Reference: Chromium os_crypt for macOS.  Same scheme used by Chrome/Edge/etc.
enum ChromiumCookies {

    /// Read the cookie named `cookieName` from the SQLite DB at `dbPath` and
    /// return its plaintext value, decrypting via the "<safeStorageService>"
    /// Keychain password if needed.  Returns nil for any missing/invalid step.
    static func readCookie(dbPath: String,
                           cookieName: String,
                           safeStorageService: String) -> String? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        // Copy to a temp file — the running app holds a write lock on the live DB.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-cookies-\(UUID().uuidString).db")
        do {
            try? FileManager.default.removeItem(at: tmpURL)
            try FileManager.default.copyItem(atPath: dbPath, toPath: tmpURL.path)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        guard let (plainValue, encrypted) = queryCookie(dbPath: tmpURL.path, name: cookieName) else {
            return nil
        }
        if let s = plainValue, !s.isEmpty { return s }
        guard let ct = encrypted, !ct.isEmpty else { return nil }
        guard let password = keychainPassword(service: safeStorageService) else { return nil }
        return decrypt(encrypted: ct, keychainPassword: password)
    }

    // MARK: - SQLite

    private static func queryCookie(dbPath: String, name: String)
        -> (value: String?, encrypted: Data?)?
    {
        // See CursorCredentials for why `?immutable=1` — same WAL sidecar issue.
        var db: OpaquePointer?
        let uri = "file:\(dbPath)?immutable=1"
        guard sqlite3_open_v2(uri, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT value, encrypted_value FROM cookies WHERE name = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        // SQLITE_TRANSIENT tells sqlite to copy the string.
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        var value: String?
        if let cstr = sqlite3_column_text(stmt, 0) {
            let s = String(cString: cstr)
            if !s.isEmpty { value = s }
        }

        var encrypted: Data?
        let nBytes = sqlite3_column_bytes(stmt, 1)
        if nBytes > 0, let ptr = sqlite3_column_blob(stmt, 1) {
            encrypted = Data(bytes: ptr, count: Int(nBytes))
        }
        return (value, encrypted)
    }

    // MARK: - Keychain password

    private static func keychainPassword(service: String) -> String? {
        return ShellRunner.run("/usr/bin/security",
                               args: ["find-generic-password", "-s", service, "-w"],
                               timeout: 5.0)
    }

    // MARK: - Decrypt

    private static func decrypt(encrypted: Data, keychainPassword: String) -> String? {
        // Drop 3-byte version prefix ("v10" or "v11").
        guard encrypted.count > 3 else { return nil }
        let ct = encrypted.subdata(in: 3..<encrypted.count)

        guard let key = pbkdf2SHA1(password: keychainPassword,
                                    salt: "saltysalt",
                                    iterations: 1003,
                                    keyLength: 16) else { return nil }
        let iv = Data(repeating: 0x20, count: 16) // 16 spaces
        guard let plain = aes128cbcDecrypt(ct: ct, key: key, iv: iv) else { return nil }
        guard let unpadded = pkcs7Unpad(plain) else { return nil }
        return String(data: unpadded, encoding: .utf8)
    }

    private static func pbkdf2SHA1(password: String, salt: String,
                                   iterations: UInt32, keyLength: Int) -> Data? {
        let passBytes = Array(password.utf8)
        let saltBytes = Array(salt.utf8)
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = saltBytes.withUnsafeBufferPointer { saltPtr in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password, passBytes.count,
                saltPtr.baseAddress, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                iterations,
                &derived, keyLength
            )
        }
        return status == kCCSuccess ? Data(derived) : nil
    }

    private static func aes128cbcDecrypt(ct: Data, key: Data, iv: Data) -> Data? {
        let outCapacity = ct.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        var written = 0
        let ctCount = ct.count
        let keyCount = key.count
        let status = out.withUnsafeMutableBytes { outPtr in
            ct.withUnsafeBytes { ctPtr in
                iv.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            0,  // no PKCS padding — we strip it ourselves
                            keyPtr.baseAddress, keyCount,
                            ivPtr.baseAddress,
                            ctPtr.baseAddress, ctCount,
                            outPtr.baseAddress, outCapacity,
                            &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(written)
    }

    private static func pkcs7Unpad(_ data: Data) -> Data? {
        guard let last = data.last, last > 0, Int(last) <= data.count else { return nil }
        return data.prefix(data.count - Int(last))
    }
}
