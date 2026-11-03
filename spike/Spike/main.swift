import Foundation
import Security

let service = "org.izawa.sk-icloud-keychain.spike"
let group = (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? "") + "org.izawa.sk-icloud-keychain"

func base(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account,
     kSecUseDataProtectionKeychain as String: true,
     kSecAttrSynchronizable as String: true,
     kSecAttrAccessGroup as String: group]
}
func msg(_ s: OSStatus) -> String { "\(s) \(SecCopyErrorMessageString(s, nil) as String? ?? "")" }

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "roundtrip"
let account = args.count > 2 ? args[2] : "spike-\(ProcessInfo.processInfo.hostName)"
print("group:", group)

switch mode {
case "write":
    SecItemDelete(base(account) as CFDictionary)
    var q = base(account); q[kSecValueData as String] = Data("hello from \(ProcessInfo.processInfo.hostName)".utf8)
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    print("add:", msg(SecItemAdd(q as CFDictionary, nil)))
case "list":
    var q = base(account); q.removeValue(forKey: kSecAttrAccount as String)
    q[kSecMatchLimit as String] = kSecMatchLimitAll; q[kSecReturnAttributes as String] = true; q[kSecReturnData as String] = true
    var out: CFTypeRef?
    let s = SecItemCopyMatching(q as CFDictionary, &out); print("list:", msg(s))
    for item in (out as? [[String: Any]]) ?? [] {
        print(" -", item[kSecAttrAccount as String] ?? "", String(data: item[kSecValueData as String] as? Data ?? Data(), encoding: .utf8) ?? "")
    }
default:
    SecItemDelete(base(account) as CFDictionary)
    var q = base(account); q[kSecValueData as String] = Data("x".utf8)
    print("add:", msg(SecItemAdd(q as CFDictionary, nil)))
    var r = base(account); r[kSecReturnData as String] = true
    var out: CFTypeRef?
    print("read:", msg(SecItemCopyMatching(r as CFDictionary, &out)), String(data: out as? Data ?? Data(), encoding: .utf8) ?? "")
    print("delete:", msg(SecItemDelete(base(account) as CFDictionary)))
}
