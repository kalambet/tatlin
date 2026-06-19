import Foundation

/// Persists the user's choice of vault folder as a **security-scoped bookmark**
/// so writes survive relaunch under the App Sandbox (ADR-9a).
///
/// `UserDefaults` keys:
/// - `vaultBookmark` (Data) — the canonical permission grant.
/// - `vaultPath` (String) — display only; mirrors the path the user picked.
///
/// Resolving a bookmark only restores the right to *ask* for access; the caller
/// still has to bracket I/O with `startAccessingSecurityScopedResource()` /
/// `stopAccessingSecurityScopedResource()`. See `AppModel.runPipeline`.
enum VaultBookmark {
    private static let bookmarkKey = "vaultBookmark"
    private static let displayKey = "vaultPath"

    static var displayPath: String {
        UserDefaults.standard.string(forKey: displayKey) ?? ""
    }

    static func save(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.set(url.path, forKey: displayKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: displayKey)
    }

    /// Resolve to a URL or return `nil` if no bookmark is stored / bookmark is
    /// irrecoverably stale. On a recoverable-stale result we briefly acquire
    /// access to rebuild the bookmark before returning.
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale, url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                try? save(url)
            }
            return url
        } catch {
            return nil
        }
    }
}
