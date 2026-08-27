import Foundation
import Security

/// Where a daemon token lives, keyed by daemon id.
public protocol TokenStore: Sendable {
    func token(for daemonId: String) -> String?
    func setToken(_ token: String, for daemonId: String) throws
    func removeToken(for daemonId: String) throws
}

/// The shipping store: a `kSecClassGenericPassword` item per daemon.
///
/// `kSecAttrAccessibleAfterFirstUnlock` because the app reconnects from the
/// background during the Grace Window, when the device may be locked, and
/// deliberately **not** iCloud-synced: the token is per-Mac and rotatable, so
/// syncing it to other devices only invites stale-token confusion.
public struct KeychainTokenStore: TokenStore {
    public static let defaultService = "dev.shidou.ios.daemon-token"

    private let service: String

    public init(service: String = KeychainTokenStore.defaultService) {
        self.service = service
    }

    public func token(for daemonId: String) -> String? {
        var query = baseQuery(daemonId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String, for daemonId: String) throws {
        let data = Data(token.utf8)
        let query = baseQuery(daemonId)
        let update = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    public func removeToken(for daemonId: String) throws {
        let status = SecItemDelete(baseQuery(daemonId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(_ daemonId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: daemonId,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus

    public init(status: OSStatus) { self.status = status }
}

extension KeychainError: LocalizedError {
    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Keychain access failed: \(detail)"
    }
}

/// Test and preview substitute.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private var tokens: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func token(for daemonId: String) -> String? {
        lock.withLock { tokens[daemonId] }
    }

    public func setToken(_ token: String, for daemonId: String) throws {
        lock.withLock { tokens[daemonId] = token }
    }

    public func removeToken(for daemonId: String) throws {
        _ = lock.withLock { tokens.removeValue(forKey: daemonId) }
    }
}
