import Foundation
import SwiftUI
import Combine

// The registry is built dynamically at startup by scanning what's actually on
// disk.  There's deliberately no "Add account" UI: Claude Code / Codex sign
// you in via their CLI, and the app never handles OAuth tokens itself.
// Any `~/.claude-*` or `~/.codex-*` dir with valid credentials is picked up
// automatically, so a user who wants a second account only has to run:
//
//     CLAUDE_CONFIG_DIR=~/.claude-work claude
//
// once in Terminal — after that it appears here forever.  GitHub Copilot
// supports multi-account natively (multiple entries in apps.json), so those
// come along for free with no configuration.
@MainActor
final class ProviderRegistry: ObservableObject {

    @Published private(set) var providers: [UsageProvider] = []

    /// Tag used by the Settings UI to know which "how to add another
    /// account" hint to show.  Not used for any CRUD — instances only
    /// come from disk.
    enum Kind { case claude, codex }

    static let `default` = ProviderRegistry()

    init() {
        rebuild()
    }

    /// Rescan disk and rebuild the provider list.  Cheap.
    func rebuild() {
        var list: [UsageProvider] = []

        // Claude — default install, then anything under ~/.claude-*
        list.append(ClaudeCodeProvider())
        for extra in Self.discoverClaudeExtras() {
            list.append(ClaudeCodeProvider(configDir: extra.path, label: extra.label))
        }

        // Codex — same pattern with ~/.codex-*
        list.append(CodexProvider())
        for extra in Self.discoverCodexExtras() {
            list.append(CodexProvider(configDir: extra.path, label: extra.label))
        }

        // Cursor — single instance.
        list.append(CursorProvider())

        // Copilot — one per apps.json entry.
        list.append(contentsOf: CopilotProvider.discover())

        providers = list
        objectWillChange.send()
    }

    func provider(id: String) -> UsageProvider? {
        providers.first { $0.id == id }
    }

    // MARK: - Disk scan

    private struct ExtraInstance {
        let label: String
        let path: String
    }

    /// Find ~/.claude-* dirs that have valid credentials on disk.
    /// A dir is considered "valid" if either the `.credentials.json` file
    /// exists inside it and parses into a non-empty access token.
    private static func discoverClaudeExtras() -> [ExtraInstance] {
        discoverExtras(prefix: ".claude-") { path in
            ClaudeCredentials.loadAccessToken(configDir: path) != nil
        }
    }

    /// Find ~/.codex-* dirs that have valid credentials on disk.
    private static func discoverCodexExtras() -> [ExtraInstance] {
        discoverExtras(prefix: ".codex-") { path in
            CodexCredentials.load(configDir: path) != nil
        }
    }

    private static func discoverExtras(prefix: String,
                                       hasCredentials: (String) -> Bool)
        -> [ExtraInstance]
    {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let entries = try? FileManager.default
                .contentsOfDirectory(atPath: home) else { return [] }

        var out: [ExtraInstance] = []
        var seenLabels = Set<String>()
        for entry in entries.sorted() where entry.hasPrefix(prefix) {
            let full = "\(home)/\(entry)"
            // Must be a dir, not a symlink to a file, and must have creds.
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir),
                  isDir.boolValue,
                  hasCredentials(full) else { continue }

            // Suffix after the prefix — ".claude-work" → "work".
            let suffix = String(entry.dropFirst(prefix.count))
            guard !suffix.isEmpty else { continue }
            let label = prettifyLabel(suffix)
            // Guard against ambiguous duplicates (shouldn't happen — dir
            // names are unique — but defend against the slug collapse).
            guard !seenLabels.contains(label) else { continue }
            seenLabels.insert(label)
            out.append(ExtraInstance(label: label, path: full))
        }
        return out
    }

    /// "work"  →  "Work"    ; "team-a" → "Team A" ; "2" → "Account 2"
    private static func prettifyLabel(_ raw: String) -> String {
        // Pure-digit suffixes read as generic account numbers.
        if raw.allSatisfy({ $0.isNumber }) { return "Account \(raw)" }
        return raw.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
