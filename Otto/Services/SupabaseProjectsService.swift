import Foundation
import Security

/// One Supabase project the user has registered with Otto. Non-secret fields
/// are persisted in UserDefaults; the PAT lives in macOS Keychain, keyed by
/// the project's local UUID.
struct SupabaseProject: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String         // user-facing label, e.g. "CRM"
    var projectRef: String   // Supabase project_ref slug (the X in https://X.supabase.co)
    var schemaNotes: String  // optional free-text — injected into system prompt
    var slug: String         // sanitized, used as the MCP server key
    var createdAt: Date

    /// Slug derivation: lowercase, keep [a-z0-9_], collapse whitespace, fallback
    /// to `proj_<id-prefix>` if the result is empty. Used as the MCP server key
    /// (`supabase_<slug>`) — must satisfy both Claude Code and Codex's allowed
    /// charset (alphanumeric + underscore).
    static func slugify(_ name: String, fallbackId: UUID) -> String {
        let lower = name.lowercased()
        var out = ""
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if ch == "_" || ch == " " || ch == "-" {
                if !out.isEmpty && out.last != "_" { out.append("_") }
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        if out.isEmpty {
            return "proj_" + fallbackId.uuidString.lowercased().prefix(8)
        }
        return out
    }

    /// Valid Supabase project_ref shape: lowercase alphanumeric + `-`/`_`, at
    /// least 1 char, no other characters allowed. Used to harden the URL
    /// construction in ClaudeCLIService / CodexCLIService — a malicious paste
    /// like `validref&x=y` would otherwise smuggle query params into the MCP
    /// endpoint URL.
    static func isValidProjectRef(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return false }
        for ch in trimmed {
            if ch.isLetter || ch.isNumber { continue }
            if ch == "-" || ch == "_" { continue }
            return false
        }
        return true
    }
}

/// Errors surfaced by `SupabaseProjectsService.addProject`.
enum SupabaseProjectsError: LocalizedError {
    case emptyName
    case invalidProjectRef
    case emptyPAT

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Name is required."
        case .invalidProjectRef:
            return "project_ref must be lowercase letters, digits, hyphens, or underscores only (1–64 chars)."
        case .emptyPAT:
            return "Personal Access Token is required."
        }
    }
}

/// Storage for the user's list of registered Supabase projects. Mirrors the
/// shape of `XAuthService` (UserDefaults for non-secret fields, Keychain for
/// the credential) so both follow the same pattern.
///
/// PATs are stored in Keychain under service `com.otto.supabase`, account =
/// the project's UUID string, accessibility =
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (no iCloud sync, no other
/// users on the Mac).
///
/// Threading: a single `NSLock` guards every read/write path — both the
/// UserDefaults blob and the per-project Keychain item. All public API funnels
/// through the lock so concurrent add/delete/rotate cannot interleave.
final class SupabaseProjectsService: @unchecked Sendable {
    static let shared = SupabaseProjectsService()

    private static let keychainService = "com.otto.supabase"
    private static let defaultsKey = "supabase.projects"

    private let lock = NSLock()

    private init() {}

    // MARK: - Read

    /// All projects sorted by createdAt ascending (oldest first — stable order
    /// for both the Integrations list and the system-prompt section).
    func allProjects() -> [SupabaseProject] {
        withLock { unlockedAllProjects() }
    }

    func project(id: UUID) -> SupabaseProject? {
        withLock { unlockedAllProjects().first { $0.id == id } }
    }

    /// PAT lookup — returns nil if the project was deleted or the Keychain
    /// item is missing (can happen after a macOS profile migration).
    func pat(for id: UUID) -> String? {
        withLock { getKeychainItem(account: id.uuidString) }
    }

    // MARK: - Write

    /// Returns the newly-created project on success. Trims input fields and
    /// derives a unique slug — appends `_2`, `_3`, … if the user already has
    /// a project with the same name.
    ///
    /// Throws when input is missing or `projectRef` fails charset validation.
    @discardableResult
    func addProject(name: String, projectRef: String, schemaNotes: String, pat: String) throws -> SupabaseProject {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRef = projectRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = schemaNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPat = pat.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else { throw SupabaseProjectsError.emptyName }
        guard SupabaseProject.isValidProjectRef(trimmedRef) else { throw SupabaseProjectsError.invalidProjectRef }
        guard !trimmedPat.isEmpty else { throw SupabaseProjectsError.emptyPAT }

        let id = UUID()

        return withLock {
            var slug = SupabaseProject.slugify(trimmedName, fallbackId: id)
            slug = uniqueSlug(base: slug, existing: unlockedAllProjects().map(\.slug))

            let project = SupabaseProject(
                id: id,
                name: trimmedName,
                projectRef: trimmedRef,
                schemaNotes: trimmedNotes,
                slug: slug,
                createdAt: Date()
            )

            // Keychain first — if it fails, leave the projects list untouched
            // so we don't end up with a half-broken project entry.
            setKeychainItem(account: id.uuidString, value: trimmedPat)
            var list = unlockedAllProjects()
            list.append(project)
            unlockedWriteAll(list)
            return project
        }
    }

    /// In-place update — schema notes is the only field expected to change
    /// post-creation. PAT rotation goes through `rotatePAT(for:newPAT:)`.
    func updateProject(_ project: SupabaseProject) {
        withLock {
            var list = unlockedAllProjects()
            guard let idx = list.firstIndex(where: { $0.id == project.id }) else { return }
            list[idx] = project
            unlockedWriteAll(list)
        }
    }

    func rotatePAT(for id: UUID, newPAT: String) {
        let trimmed = newPAT.trimmingCharacters(in: .whitespacesAndNewlines)
        withLock { setKeychainItem(account: id.uuidString, value: trimmed) }
    }

    func deleteProject(_ id: UUID) {
        withLock {
            deleteKeychainItem(account: id.uuidString)
            let remaining = unlockedAllProjects().filter { $0.id != id }
            unlockedWriteAll(remaining)
        }
    }

    // MARK: - Lock helpers

    /// All public APIs go through this so the (UserDefaults, Keychain) pair
    /// always stays consistent.
    private func withLock<T>(_ block: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block()
    }

    private func unlockedAllProjects() -> [SupabaseProject] {
        guard let raw = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([SupabaseProject].self, from: raw)
        else { return [] }
        return decoded.sorted { $0.createdAt < $1.createdAt }
    }

    private func unlockedWriteAll(_ list: [SupabaseProject]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func uniqueSlug(base: String, existing: [String]) -> String {
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }

    // MARK: - Keychain (mirrors XAuthService:303–344) — assume caller holds the lock

    private func setKeychainItem(account: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        deleteKeychainItem(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // No iCloud sync, no other macOS users on this device.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[Supabase] SecItemAdd failed status=%d", Int(status))
        }
    }

    private func getKeychainItem(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    private func deleteKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
