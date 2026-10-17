import XCTest
@testable import RoamPrintCore
#if os(macOS)
import Security
#endif

private final class MemoryCredentialStore: LoginCredentialStoring {
    var values: [String: Credentials] = [:]
    var rejectDeletion = false
    func read(for platform: String) throws -> Credentials? { values[platform] }
    func save(_ credentials: Credentials, for platform: String) throws { values[platform] = credentials }
    func delete(for platform: String) throws {
        if rejectDeletion { throw PrintError.invalidConfiguration("Fixture deletion refused") }
        values.removeValue(forKey: platform)
    }
}

final class RememberedLoginTests: XCTestCase {
    private let server = URL(string: "http://10.1.8.5/xzentprint/services")!
    private let credentials = Credentials(username: "saved-user", password: "fixture-secret")

    private func fixture() -> (String, UserDefaults, MemoryCredentialStore, RememberedLogin) {
        let suite = "RoamPrint.LoginTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let store = MemoryCredentialStore()
        return (suite, defaults, store, RememberedLogin(store: store, defaults: defaults))
    }

    func testRestoresAcrossSessionsAndKeepsSecretsOutOfPreferences() throws {
        let (suite, defaults, store, login) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(login.isEnabled(for: server))
        XCTAssertNil(try login.restore(for: server))
        try login.setEnabled(true, for: server)
        try login.save(credentials, for: server)
        let restarted = RememberedLogin(store: store, defaults: defaults)
        let restored = try XCTUnwrap(restarted.restore(for: server))
        XCTAssertEqual(restored.username, credentials.username)
        XCTAssertEqual(restored.password, credentials.password)
        let changed = Credentials(username: "changed-user", password: "changed-password")
        try restarted.save(changed, for: server)
        XCTAssertEqual(try login.restore(for: server)?.password, changed.password)
        let preferences = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertEqual(preferences.count, 1)
        XCTAssertTrue(preferences.values.allSatisfy { $0 is Bool })
        let serialized = try PropertyListSerialization.data(fromPropertyList: preferences, format: .xml, options: 0)
        let text = String(decoding: serialized, as: UTF8.self)
        for secret in [credentials.username, credentials.password, changed.username, changed.password] {
            XCTAssertFalse(text.contains(secret))
        }
    }

    func testCredentialsAreScopedToPlatformAndNormalizeDefaultPort() throws {
        let (suite, defaults, _, login) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        try login.save(credentials, for: server)
        let equivalent = URL(string: "http://10.1.8.5:80/xzentprint/services/")!
        XCTAssertEqual(try login.restore(for: equivalent)?.username, credentials.username)
        for different in ["http://10.1.8.6/xzentprint/services", "https://10.1.8.5/xzentprint/services",
                          "http://10.1.8.5:8080/xzentprint/services", "http://10.1.8.5/other/services"] {
            XCTAssertNil(try login.restore(for: URL(string: different)!))
        }
        let other = URL(string: "http://10.1.8.6/xzentprint/services")!
        try login.save(Credentials(username: "other", password: "other-secret"), for: other)
        try login.setEnabled(false, for: server)
        XCTAssertEqual(try login.restore(for: other)?.username, "other")
    }

    func testDisablingDeletesCredentialsAndReportsDeletionFailure() throws {
        let (suite, defaults, store, login) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        try login.save(credentials, for: server)
        store.rejectDeletion = true
        XCTAssertThrowsError(try login.setEnabled(false, for: server))
        XCTAssertTrue(login.isEnabled(for: server))
        store.rejectDeletion = false
        try login.setEnabled(false, for: server)
        XCTAssertTrue(store.values.isEmpty)
        let restarted = RememberedLogin(store: store, defaults: defaults)
        XCTAssertFalse(restarted.isEnabled(for: server))
        XCTAssertNil(try restarted.restore(for: server))
        try restarted.save(credentials, for: server)
        XCTAssertTrue(store.values.isEmpty)
        try restarted.setEnabled(true, for: server)
        try restarted.save(credentials, for: server)
        XCTAssertEqual(try restarted.restore(for: server)?.password, credentials.password)
    }

    #if os(macOS)
    func testActualKeychainCreateReadUpdateAndDelete() throws {
        // Unique service prevents reading or changing a real RoamPrint login.
        let service = "org.local.roamprint.tests." + UUID().uuidString
        let store = KeychainLoginStore(service: service)
        let key = RememberedLogin.platformKey(server)
        defer { try? store.delete(for: key) }
        XCTAssertNil(try store.read(for: key))
        // Removing the unused login-kind field must preserve already saved logins.
        let saved = try JSONSerialization.data(withJSONObject: [
            "username": credentials.username, "password": credentials.password, "kind": 0
        ])
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecAttrAccount as String: key,
                                  kSecValueData as String: saved]
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        XCTAssertEqual(try store.read(for: key)?.username, credentials.username)
        XCTAssertEqual(try store.read(for: key)?.password, credentials.password)
        try store.save(credentials, for: key)
        XCTAssertEqual(try store.read(for: key)?.password, credentials.password)
        let replacement = Credentials(username: "新账号", password: "quote\"slash\\新密码")
        try store.save(replacement, for: key)
        let restored = try XCTUnwrap(store.read(for: key))
        XCTAssertEqual(restored.username, replacement.username)
        XCTAssertEqual(restored.password, replacement.password)
        try store.delete(for: key)
        XCTAssertNil(try store.read(for: key))
        try store.delete(for: key)
    }
    #endif
}
