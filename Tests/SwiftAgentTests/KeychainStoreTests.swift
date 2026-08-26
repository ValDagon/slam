import Foundation
import Security
import Testing
@testable import SwiftAgent

/// The real keychain is touched only by the roundtrip test, with a dedicated
/// service/account that cleans up after itself. Error mapping is a pure check.
struct KeychainStoreTests {
    @Test func errorMappingDescription() {
        #expect(KeychainError.unhandledStatus(errSecAuthFailed).description == "Keychain OSStatus \(errSecAuthFailed)")
        #expect(String(describing: KeychainError.successButNilData).contains("no data"))
    }

    @Test func duplicateItemMapsCorrectly() {
        #expect(KeychainError.from(errSecDuplicateItem) == .duplicateItem)
    }

    @Test func itemNotFoundMapsCorrectly() {
        #expect(KeychainError.from(errSecItemNotFound) == .itemNotFound)
    }

    @Test func interactionNotAllowedMapsCorrectly() {
        #expect(KeychainError.from(errSecInteractionNotAllowed) == .interactionNotAllowed)
    }

    @Test func authFailedAndIOAndUnimplementedMap() {
        #expect(KeychainError.from(errSecAuthFailed) == .authFailed)
        #expect(KeychainError.from(errSecIO) == .io)
        #expect(KeychainError.from(errSecUnimplemented) == .unimplemented)
    }

    @Test func unknownStatusFallsIntoUnhandledStatus() {
        let weird: OSStatus = -60003
        #expect(KeychainError.from(weird) == .unhandledStatus(-60003))
    }

    @Test(arguments: [
        (errSecDuplicateItem, KeychainError.duplicateItem),
        (errSecItemNotFound, KeychainError.itemNotFound),
        (errSecInteractionNotAllowed, KeychainError.interactionNotAllowed),
        (errSecAuthFailed, KeychainError.authFailed),
        (errSecIO, KeychainError.io),
        (errSecUnimplemented, KeychainError.unimplemented),
    ])
    func fromMapsKnownStatuses(_ status: OSStatus, expected: KeychainError) {
        #expect(KeychainError.from(status) == expected)
    }

    @Test func trustedPathsPreferInstalledBinaryFirst() {
        let paths = KeychainStore.trustedApplicationPaths(
            home: "/Users/demo",
            currentExecutable: "/Users/demo/.local/bin/slam"
        )
        #expect(paths.first == "/Users/demo/.local/bin/slam")
        #expect(paths.contains("/Users/demo/.local/bin/swift-agent"))
        #expect(Set(paths).count == paths.count)
    }

    @Test func trustedPathsIncludeInstalledAndCurrentWhenDifferent() {
        let paths = KeychainStore.trustedApplicationPaths(
            home: "/Users/demo",
            currentExecutable: "/tmp/build/slam"
        )
        #expect(paths.first == "/Users/demo/.local/bin/slam")
        #expect(paths.contains("/tmp/build/slam"))
        #expect(paths.contains("/Users/demo/.local/bin/swift-agent"))
    }

    @Test func trustedPathsSkipEmptyCurrentExecutable() {
        let paths = KeychainStore.trustedApplicationPaths(home: "/Users/demo", currentExecutable: "")
        #expect(paths.first == "/Users/demo/.local/bin/slam")
        #expect(paths.contains("/Users/demo/.local/bin/swift-agent"))
        #expect(!paths.contains(""))
    }

    @Test func makeLegacyAccessReturnsAllowAnyWhenNoExistingPaths() {
        let access = KeychainStore.makeLegacyAccess(
            paths: ["/tmp/slam-does-not-exist-\(UUID().uuidString)"],
            fileExists: { _ in false }
        )
        // No trusted apps → SecAccessCreate(nil list) still yields allow-any access.
        #expect(access != nil)
    }

    @Test func legacyQueryStripsDataProtectionFlag() {
        let withDP: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: "svc",
        ]
        let legacy = KeychainStore.legacyQuery(from: withDP as CFDictionary) as! [String: Any]
        #expect(legacy[kSecUseDataProtectionKeychain as String] == nil)
        #expect(legacy[kSecAttrService as String] as? String == "svc")
    }

    /// errSecMissingEntitlement: the test binary has no keychain entitlements
    /// (bare CLT toolchain, no codesigning), so real SecItem access is impossible.
    private static let missingEntitlement = errSecMissingEntitlement

    @Test func saveAndLoadRoundtripUsesRealKeychainItem() throws {
        // Integration test against the user keychain with our own service/account.
        // Uses a dedicated test account and cleans up after itself.
        let store = KeychainStore(service: "com.local.slam.tests")
        let account = "roundtrip-\(Int.random(in: 1...1_000_000))"
        defer { try? store.delete(account: account) }

        do {
            try store.save(secret: "secret-value-1", account: account)
        } catch let error as KeychainError {
            // Test binaries lack keychain entitlements unless codesigned, so
            // SecItem calls fail with errSecMissingEntitlement outside Xcode.
            // Mapping behavior stays covered by the pure tests above.
            if case .unhandledStatus(Self.missingEntitlement) = error { return }
            throw error
        }
        // Add-or-update path: second save must update, not duplicate.
        try store.save(secret: "secret-value-2", account: account)
        let loaded = try store.load(account: account)
        #expect(loaded == "secret-value-2")

        try store.delete(account: account)
        let afterDelete = try store.load(account: account)
        #expect(afterDelete == nil)
    }
}
