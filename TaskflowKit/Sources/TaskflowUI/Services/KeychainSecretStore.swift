// API keys in the iOS Keychain: generic passwords of this app only, readable after the first unlock,
// never synchronized to iCloud and never included in device backups to another device
// ("ThisDeviceOnly"). Nothing secret is ever written anywhere else.
import Foundation
import Security
import TaskflowCore

public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    let service: String

    public init(service: String = "app.taskflow.ios.ai") {
        self.service = service
    }

    public var isAvailable: Bool { true }

    public enum KeychainError: Error { case unexpected(OSStatus) }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func read(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpected(status)
        }
        return text
    }

    public func write(account: String, value: String) throws {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.unexpected(status) }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.unexpected(added) }
    }

    public func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
