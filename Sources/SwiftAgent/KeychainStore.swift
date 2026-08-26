import Foundation
import Security
import LocalAuthentication
import KeychainACL

enum KeychainError: Error, Equatable, CustomStringConvertible, Sendable {
    case duplicateItem          // errSecDuplicateItem (-25299)
    case itemNotFound           // errSecItemNotFound (-25300)
    case interactionNotAllowed  // errSecInteractionNotAllowed (-25308)
    case unimplemented          // errSecUnimplemented (-25291)
    case io                     // errSecIO (-36)
    case authFailed             // errSecAuthFailed (-25293)
    case unhandledStatus(OSStatus)
    case successButNilData
    case invalidUTF8

    /// Pure OSStatus → error conversion, unit-testable without touching the keychain.
    static func from(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecDuplicateItem: return .duplicateItem
        case errSecItemNotFound: return .itemNotFound
        case errSecInteractionNotAllowed: return .interactionNotAllowed
        case errSecUnimplemented: return .unimplemented
        case errSecIO: return .io
        case errSecAuthFailed: return .authFailed
        default: return .unhandledStatus(status)
        }
    }

    var description: String {
        switch self {
        case .duplicateItem: return "errSecDuplicateItem"
        case .itemNotFound: return "errSecItemNotFound"
        case .interactionNotAllowed: return "errSecInteractionNotAllowed"
        case .unimplemented: return "errSecUnimplemented"
        case .io: return "errSecIO"
        case .authFailed: return "errSecAuthFailed"
        case .unhandledStatus(let status): return "Keychain OSStatus \(status)"
        case .successButNilData: return "Keychain returned success but no data"
        case .invalidUTF8: return "stored secret is not valid UTF-8"
        }
    }
}

/// macOS Keychain access for daemon secrets.
///
/// Generic password item: service = com.local.slam, account names the integration
/// (e.g. "telegram-bot-token"). Data-protection keychain is preferred (FR-11), but on
/// macOS it requires keychain entitlements from a real code signature; ad-hoc-signed
/// dev builds (`swift run`) get errSecMissingEntitlement (-34018) on every call. In that
/// case the store transparently falls back to the legacy login keychain and caches the
/// decision; reads also probe the legacy variant so tokens stored by either mode load.
///
/// Login-keychain items get an explicit `SecAccess` ACL that trusts
/// `~/.local/bin/slam` (LaunchAgent), the pre-rebrand `swift-agent` path if present,
/// and the current executable. Without that, macOS prompts for the login password /
/// “Always Allow” on every LaunchAgent read — especially after `set-token` via a
/// different path (`swift run`) or after an ad-hoc binary replace. `SecItemUpdate`
/// cannot refresh ACL; duplicate saves delete+re-add. Add-or-update still handles
/// errSecDuplicateItem; every OSStatus is checked. The token must never be stored
/// in files, plist or env — both variants are still Keychain.
///
/// `load` / `delete` on the default service also probe `com.local.swift-agent` so
/// a token saved before the S.L.A.M rename still works until the next save/repair.
struct KeychainStore: Sendable {
    let service: String

    init(service: String = AppIdentity.keychainService) {
        self.service = service
    }

    /// Cached across calls: -34018 seen once means this binary lacks entitlements.
    private nonisolated(unsafe) static var dataProtectionUnavailable = false

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if !Self.dataProtectionUnavailable {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// Runs `operation` with data protection first; a missing-entitlement status
    /// flips the cached flag and retries once against the login keychain.
    private func withFallback(_ operation: (CFDictionary) -> OSStatus, _ query: CFDictionary) -> OSStatus {
        if !Self.dataProtectionUnavailable {
            let status = operation(query)
            if status != errSecMissingEntitlement {
                return status
            }
            Self.dataProtectionUnavailable = true
        }
        // Rebuild without the DP flag now that it is known to fail.
        return operation(Self.legacyQuery(from: query))
    }

    /// Strips the DP flag from an already-built query dictionary.
    static func legacyQuery(from query: CFDictionary) -> CFDictionary {
        var mutable = query as! [String: Any]
        mutable.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        return mutable as CFDictionary
    }

    private func legacyBaseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Ordered paths trusted for login-keychain ACL (installed LaunchAgent binary first).
    /// Pure / injectable for unit tests — does not touch Security.framework.
    static func trustedApplicationPaths(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        currentExecutable: String? = CommandLine.arguments.first
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func append(_ raw: String) {
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            guard !path.isEmpty, !seen.contains(path) else { return }
            seen.insert(path)
            ordered.append(path)
        }
        append((home as NSString).appendingPathComponent(".local/bin/\(AppIdentity.cliName)"))
        append((home as NSString).appendingPathComponent(".local/bin/swift-agent"))
        if let currentExecutable, !currentExecutable.isEmpty {
            append(currentExecutable)
        }
        return ordered
    }

    /// Builds a login-keychain `SecAccess` that lets trusted binaries read without a prompt.
    /// Missing paths are skipped (`SecTrustedApplicationCreateFromPath` requires a real file).
    /// If no trusted app can be created, falls back to an allow-any ACL (still behind login
    /// keychain unlock) rather than the default creator-only ACL that prompts LaunchAgent.
    static func makeLegacyAccess(
        paths: [String] = KeychainStore.trustedApplicationPaths(),
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0)
            || FileManager.default.fileExists(atPath: $0) }
    ) -> SecAccess? {
        var trustedApps: [SecTrustedApplication] = []
        for path in paths where fileExists(path) {
            if let app = path.withCString({ SATrustedApplicationCreate($0) }) {
                trustedApps.append(app.takeRetainedValue())
            }
        }
        let trustedList: CFArray? = trustedApps.isEmpty ? nil : (trustedApps as CFArray)
        guard let access = SAAccessCreate(
            AppIdentity.keychainAccessLabel as CFString,
            trustedList
        ) else {
            return nil
        }
        return access.takeRetainedValue()
    }

    func save(secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainError.invalidUTF8
        }

        if !Self.dataProtectionUnavailable {
            let addQuery = baseQuery(account: account).merging([
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess { return }
            if addStatus == errSecMissingEntitlement {
                Self.dataProtectionUnavailable = true
            } else if addStatus == errSecDuplicateItem {
                let updateStatus = SecItemUpdate(
                    baseQuery(account: account) as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
                guard updateStatus == errSecSuccess else {
                    throw KeychainError.from(updateStatus)
                }
                return
            } else {
                throw KeychainError.from(addStatus)
            }
        }

        try saveLegacy(data: data, account: account)
    }

    /// Login keychain write with explicit ACL. Duplicate → delete+re-add so ACL refreshes
    /// (SecItemUpdate cannot change `kSecAttrAccess`).
    private func saveLegacy(data: Data, account: String) throws {
        var addQuery = legacyBaseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let access = Self.makeLegacyAccess() {
            addQuery[kSecAttrAccess as String] = access
        }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let deleteStatus = SecItemDelete(legacyBaseQuery(account: account) as CFDictionary)
            if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
                throw KeychainError.from(deleteStatus)
            }
            // Refresh ACL for the newly installed / current binary.
            if let access = Self.makeLegacyAccess() {
                addQuery[kSecAttrAccess as String] = access
            }
            let retryStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard retryStatus == errSecSuccess else {
                throw KeychainError.from(retryStatus)
            }
            return
        }
        throw KeychainError.from(addStatus)
    }

    /// Re-reads the secret and rewrites the item so login-keychain ACL trusts the
    /// installed LaunchAgent binary (and this executable). Use after `install.sh`
    /// replaces an ad-hoc-signed binary. Does not print the secret.
    func repairTrustedAccess(account: String) throws {
        guard let secret = try load(account: account), !secret.isEmpty else {
            throw KeychainError.itemNotFound
        }
        // Delete both variants so a subsequent save can recreate with a fresh ACL.
        let dpDelete: OSStatus
        if !Self.dataProtectionUnavailable {
            var q = legacyBaseQuery(account: account)
            q[kSecUseDataProtectionKeychain as String] = true
            dpDelete = SecItemDelete(q as CFDictionary)
            if dpDelete == errSecMissingEntitlement {
                Self.dataProtectionUnavailable = true
            }
        } else {
            dpDelete = errSecItemNotFound
        }
        let legacyDelete = SecItemDelete(legacyBaseQuery(account: account) as CFDictionary)
        let deleteOK: (OSStatus) -> Bool = { $0 == errSecSuccess || $0 == errSecItemNotFound || $0 == errSecMissingEntitlement }
        guard deleteOK(dpDelete) || deleteOK(legacyDelete) else {
            throw KeychainError.from(legacyDelete != errSecItemNotFound ? legacyDelete : dpDelete)
        }
        try save(secret: secret, account: account)
    }

    func load(account: String, allowInteraction: Bool = true) throws -> String? {
        var readQuery = baseQuery(account: account).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        // LaunchAgent must never pop a password / "Always Allow" sheet: fail closed instead.
        var authContext: LAContext?
        if !allowInteraction {
            let ctx = LAContext()
            ctx.interactionNotAllowed = true
            authContext = ctx
            readQuery[kSecUseAuthenticationContext as String] = ctx
        }

        var result: AnyObject?
        var status = withFallback({ SecItemCopyMatching($0, &result) }, readQuery as CFDictionary)

        // A miss in one variant may live in the other: token written by a signed
        // build while we run unsigned, or vice versa. One extra cheap lookup.
        if status == errSecItemNotFound,
           baseQuery(account: account)[kSecUseDataProtectionKeychain as String] != nil {
            var legacyRead = legacyBaseQuery(account: account).merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new }
            if let authContext {
                legacyRead[kSecUseAuthenticationContext as String] = authContext
            }
            result = nil
            status = SecItemCopyMatching(legacyRead as CFDictionary, &result)
        }

        // Retain authContext until both SecItemCopyMatching calls finish.
        _ = authContext

        if status == errSecItemNotFound {
            if service == AppIdentity.keychainService {
                return try KeychainStore(service: AppIdentity.legacyKeychainService)
                    .load(account: account, allowInteraction: allowInteraction)
            }
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.from(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.successButNilData
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidUTF8
        }
        return string
    }

    /// Removes the item from both data-protection and login keychains so a purge
    /// cannot leave a leftover that still prompts. Missing item is success.
    func delete(account: String) throws {
        let ok: (OSStatus) -> Bool = {
            $0 == errSecSuccess || $0 == errSecItemNotFound || $0 == errSecMissingEntitlement
        }
        var failures: [OSStatus] = []

        if !Self.dataProtectionUnavailable {
            var dpQuery = legacyBaseQuery(account: account)
            dpQuery[kSecUseDataProtectionKeychain as String] = true
            let dpStatus = SecItemDelete(dpQuery as CFDictionary)
            if dpStatus == errSecMissingEntitlement {
                Self.dataProtectionUnavailable = true
            } else if !ok(dpStatus) {
                failures.append(dpStatus)
            }
        }

        let legacyStatus = SecItemDelete(legacyBaseQuery(account: account) as CFDictionary)
        if !ok(legacyStatus) {
            failures.append(legacyStatus)
        }

        if let first = failures.first {
            throw KeychainError.from(first)
        }
        if service == AppIdentity.keychainService {
            try KeychainStore(service: AppIdentity.legacyKeychainService).delete(account: account)
        }
    }
}
