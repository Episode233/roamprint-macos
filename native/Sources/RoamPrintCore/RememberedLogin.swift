import Foundation

/// The implementation stores credentials in the OS keychain; defaults hold only the remember flag.
public protocol LoginCredentialStoring {
    func read(for platform: String) throws -> Credentials?
    func save(_ credentials: Credentials, for platform: String) throws
    func delete(for platform: String) throws
}

public struct RememberedLogin {
    private let store: any LoginCredentialStoring
    private let defaults: UserDefaults

    public init(store: any LoginCredentialStoring, defaults: UserDefaults = .standard) {
        self.store = store; self.defaults = defaults
    }

    public func isEnabled(for server: URL) -> Bool {
        defaults.object(forKey: preferenceKey(server)) as? Bool ?? true
    }

    public func restore(for server: URL) throws -> Credentials? {
        guard isEnabled(for: server) else { return nil }
        return try store.read(for: Self.platformKey(server))
    }

    public func save(_ credentials: Credentials, for server: URL) throws {
        guard isEnabled(for: server) else { return }
        try store.save(credentials, for: Self.platformKey(server))
    }

    public func setEnabled(_ enabled: Bool, for server: URL) throws {
        // Do not report successful removal when the keychain refuses deletion.
        if !enabled { try store.delete(for: Self.platformKey(server)) }
        defaults.set(enabled, forKey: preferenceKey(server))
    }

    private func preferenceKey(_ server: URL) -> String {
        "rememberLogin." + Self.platformKey(server)
    }

    static func platformKey(_ server: URL) -> String {
        var parts = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if parts.scheme == "http" && parts.port == 80 || parts.scheme == "https" && parts.port == 443 {
            parts.port = nil
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string!
    }
}
