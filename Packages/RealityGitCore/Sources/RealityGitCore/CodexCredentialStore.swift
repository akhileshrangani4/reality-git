import Foundation
import Security

public protocol CodexCredentialStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func remove() throws
}

/// OAuth credentials never leave the device through backup, sync, files or diagnostics.
public struct CodexKeychainStore: CodexCredentialStore {
    public init() {}
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.akhileshrangani.realitygit.codex-native",
         kSecAttrAccount as String: "oauth", kSecAttrSynchronizable as String: false]
    }
    public func load() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw NativeCodexError.storage }
        return data
    }
    public func save(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil) == errSecSuccess else {
                throw NativeCodexError.storage
            }
        } else if result != errSecSuccess { throw NativeCodexError.storage }
    }
    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NativeCodexError.storage }
    }
}
