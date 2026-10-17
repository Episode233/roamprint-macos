#if os(macOS)
import Foundation
import Security

/// Uses the current user's login keychain. No password is written to preferences or job files.
public struct KeychainLoginStore: LoginCredentialStoring {
    private let service: String
    public init(service: String = "org.local.roamprint.login") { self.service = service }

    private struct Record: Codable {
        let username: String
        let password: String
    }

    private func query(_ platform: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: platform]
    }

    public func read(for platform: String) throws -> Credentials? {
        var request = query(platform)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure("读取", status) }
        guard let data = item as? Data, let record = try? JSONDecoder().decode(Record.self, from: data) else {
            throw PrintError.invalidConfiguration("已保存的登录信息无法读取，请清除后重新输入。")
        }
        return Credentials(username: record.username, password: record.password)
    }

    public func save(_ credentials: Credentials, for platform: String) throws {
        let data = try JSONEncoder().encode(Record(username: credentials.username,
            password: credentials.password))
        let attributes: [String: Any] = [kSecValueData as String: data,
                                       kSecAttrLabel as String: "ZGCAxZGCI printer 登录信息"]
        let request = query(platform)
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(request.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure("保存", status) }
    }

    public func delete(for platform: String) throws {
        let status = SecItemDelete(query(platform) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure("删除", status) }
    }

    private func failure(_ action: String, _ status: OSStatus) -> PrintError {
        .invalidConfiguration("无法\(action)登录信息（钥匙串错误 \(status)）。")
    }
}
#endif
