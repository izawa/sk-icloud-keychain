import CryptoKit
import Foundation
import Security

/// Public metadata kept in kSecAttrGeneric so listing never reads secret data.
struct StoredKey: Codable {
    var version = 1
    var application: String
    var flags: UInt8
    var user: Data?
    var publicKey: Data
    var created: Date
}

/// ed25519 private keys stored as synchronizable generic passwords in the
/// data-protection keychain, readable only by apps in our access group.
enum KeyStore {
    static let service = "org.izawa.sk-icloud-keychain.key"

    static var accessGroup: String {
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
        return prefix + "org.izawa.sk-icloud-keychain"
    }

    // Every query must name kSecAttrSynchronizable, or synced items are not matched.
    private static func baseQuery(_ handle: KeyHandle? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        if let handle { q[kSecAttrAccount as String] = handle.id.uuidString }
        return q
    }

    static func add(_ key: Curve25519.Signing.PrivateKey, meta: StoredKey) throws -> KeyHandle {
        let handle = KeyHandle()
        var q = baseQuery(handle)
        q[kSecValueData as String] = key.rawRepresentation
        q[kSecAttrGeneric as String] = try PropertyListEncoder().encode(meta)
        q[kSecAttrLabel as String] = "SSH key (\(meta.application))"
        q[kSecAttrDescription as String] = "sk-icloud-keychain ed25519-sk"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        try check(SecItemAdd(q as CFDictionary, nil))
        return handle
    }

    static func meta(_ handle: KeyHandle) throws -> StoredKey {
        var q = baseQuery(handle)
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        try check(SecItemCopyMatching(q as CFDictionary, &out))
        return try decodeMeta(out as? [String: Any])
    }

    static func privateKey(_ handle: KeyHandle) throws -> Curve25519.Signing.PrivateKey {
        var q = baseQuery(handle)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        try check(SecItemCopyMatching(q as CFDictionary, &out))
        guard let data = out as? Data else { throw KeyStoreError.corrupt }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    static func list() throws -> [(KeyHandle, StoredKey)] {
        var q = baseQuery()
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        try check(status)
        return try ((out as? [[String: Any]]) ?? []).compactMap { attrs in
            guard let account = attrs[kSecAttrAccount as String] as? String,
                  let id = UUID(uuidString: account) else { return nil }
            return (KeyHandle(id: id), try decodeMeta(attrs))
        }
    }

    static func delete(_ handle: KeyHandle) throws {
        try check(SecItemDelete(baseQuery(handle) as CFDictionary))
    }

    private static func decodeMeta(_ attrs: [String: Any]?) throws -> StoredKey {
        guard let data = attrs?[kSecAttrGeneric as String] as? Data else { throw KeyStoreError.corrupt }
        return try PropertyListDecoder().decode(StoredKey.self, from: data)
    }

    private static func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw KeyStoreError.notFound
        default: throw KeyStoreError.keychain(status)
        }
    }
}

enum KeyStoreError: Error, CustomStringConvertible {
    case notFound
    case corrupt
    case keychain(OSStatus)

    var description: String {
        switch self {
        case .notFound: return "key not found in keychain"
        case .corrupt: return "keychain item is corrupt"
        case .keychain(let s):
            return "keychain error \(s): \(SecCopyErrorMessageString(s, nil) as String? ?? "")"
        }
    }
}
