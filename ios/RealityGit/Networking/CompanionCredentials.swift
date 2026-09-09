import Foundation
import RealityGitCore
import Security

enum CompanionCredentials {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.akhileshrangani.realitygit.companion", kSecAttrAccount as String: "pairing"] }
    enum Failure: Error { case storage }

    static func load() throws -> CompanionConnection? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8),
              let connection = CompanionConnection(link: text) else { throw Failure.storage }
        return connection
    }
    static func save(_ connection: CompanionConnection) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(connection.link.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil) == errSecSuccess else { throw Failure.storage }
        } else if updated != errSecSuccess { throw Failure.storage }
    }
    static func remove() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw Failure.storage }
    }

    #if DEBUG
    /// Consumes only a companion pairing link, then immediately deletes the import file.
    static func importIfRequested() throws {
        guard ProcessInfo.processInfo.arguments.contains("--import-companion") else { return }
        let file = URL.documentsDirectory.appendingPathComponent("companion-import.txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        guard let connection = CompanionConnection(link: try String(contentsOf: file, encoding: .utf8)) else { throw Failure.storage }
        try save(connection)
        print("Companion pairing saved in Keychain")
    }
    #endif
}
