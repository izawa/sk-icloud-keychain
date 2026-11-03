import CryptoKit
import Foundation

// sk-icloud-keychain helper.
//
//   sk-icloud-keychain enroll|sign|list   request on stdin, response on stdout
//   sk-icloud-keychain delete <uuid>      remove a key (interactive use)
//
// stdout carries only protocol messages; diagnostics go to stderr when
// SK_ICLOUD_KEYCHAIN_DEBUG is set. See docs/protocol.md.

func debug(_ s: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["SK_ICLOUD_KEYCHAIN_DEBUG"] != nil {
        FileHandle.standardError.write(Data("sk-icloud-keychain-helper: \(s())\n".utf8))
    }
}

/// Error codes mirror SSH_SK_ERR_* so the provider can pass them through.
enum HelperError: Error, CustomStringConvertible {
    case general(String)
    case unsupported(String)
    case notFound(String)
    case exists(String)
    case usage

    var code: Int {
        switch self {
        case .general, .usage: return -1
        case .unsupported: return -2
        case .notFound: return -4
        case .exists: return -5
        }
    }

    var description: String {
        switch self {
        case .general(let m), .unsupported(let m), .notFound(let m), .exists(let m): return m
        case .usage: return "usage error"
        }
    }
}

let validFlags = SKFlags.userPresence | SKFlags.userVerification | SKFlags.force | SKFlags.residentKey

func enroll(_ req: Message) throws -> Message {
    let application = try req.string("application")
    let flags = try req.byte("flags")
    let user = req["user"] == nil ? nil : try req.bytes("user")
    guard application.hasPrefix("ssh:") else { throw HelperError.unsupported("application must start with ssh:") }
    guard flags & ~validFlags == 0 else { throw HelperError.unsupported("unknown flags 0x\(String(flags, radix: 16))") }
    // Like sk-usbhid: one resident key per application/user unless forced.
    if flags & SKFlags.residentKey != 0, flags & SKFlags.force == 0,
       try KeyStore.list().contains(where: { $0.1.application == application && $0.1.user == user }) {
        throw HelperError.exists("a resident key for \(application) already exists")
    }

    try UserVerification.require(reason: "create an SSH key for \(application)")
    let key = Curve25519.Signing.PrivateKey()
    let meta = StoredKey(application: application, flags: flags, user: user,
                         publicKey: key.publicKey.rawRepresentation, created: Date())
    let handle = try KeyStore.add(key, meta: meta)
    debug("enrolled \(handle.id) for \(application)")

    var res = Message()
    try res.set("public_key", bytes: meta.publicKey)
    try res.set("key_handle", bytes: handle.bytes)
    try res.set("flags", bytes: Data([flags]))
    return res
}

func sign(_ req: Message) throws -> Message {
    let application = try req.string("application")
    let data = try req.bytes("data")
    guard let handle = KeyHandle(bytes: try req.bytes("key_handle")) else {
        throw HelperError.notFound("key handle was not issued by sk-icloud-keychain")
    }
    let meta: StoredKey
    do { meta = try KeyStore.meta(handle) } catch KeyStoreError.notFound {
        throw HelperError.notFound("key \(handle.id) is not in iCloud Keychain")
    }
    guard meta.application == application else {
        throw HelperError.general("key \(handle.id) belongs to \(meta.application), not \(application)")
    }

    try UserVerification.require(reason: "sign in with the SSH key for \(application)")
    let key = try KeyStore.privateKey(handle)
    // Touch ID verified the user, so assert both presence and verification.
    let flags = SKFlags.userPresence | SKFlags.userVerification
    // sshd ignores the counter by default; epoch seconds stays roughly
    // monotonic across Macs sharing the key.
    let counter = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
    let sig = try SKSignature.sign(privateKey: key, application: application,
                                   flags: flags, counter: counter, data: data)
    debug("signed with \(handle.id)")

    var res = Message()
    try res.set("signature", bytes: sig)
    try res.set("flags", bytes: Data([flags]))
    try res.set("counter", String(counter))
    return res
}

func list() throws -> Message {
    var res = Message()
    let keys = try KeyStore.list().sorted { $0.1.created < $1.1.created }
    try res.set("count", String(keys.count))
    for (i, (handle, meta)) in keys.enumerated() {
        try res.set("\(i).application", meta.application)
        try res.set("\(i).flags", bytes: Data([meta.flags]))
        try res.set("\(i).public_key", bytes: meta.publicKey)
        try res.set("\(i).key_handle", bytes: handle.bytes)
        if let user = meta.user { try res.set("\(i).user", bytes: user) }
    }
    return res
}

func delete(_ arg: String) throws {
    guard let id = UUID(uuidString: arg) else { throw HelperError.usage }
    let handle = KeyHandle(id: id)
    let meta = try KeyStore.meta(handle)
    try UserVerification.require(reason: "delete the SSH key for \(meta.application)")
    try KeyStore.delete(handle)
    print("deleted \(id) (\(meta.application))")
}

func readRequest() throws -> Message {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: input, encoding: .utf8) else { throw HelperError.general("request is not UTF-8") }
    return try Message(parsing: text)
}

func run(_ args: [String]) -> Int32 {
    var res = Message()
    do {
        switch args.dropFirst().first {
        case "enroll": res = try enroll(readRequest())
        case "sign": res = try sign(readRequest())
        case "list": res = try list()
        case "delete" where args.count == 3:
            try delete(args[2])
            return 0
        default:
            throw HelperError.usage
        }
        try res.set("status", "ok")
        print(res.serialized, terminator: "")
        return 0
    } catch HelperError.usage {
        FileHandle.standardError.write(Data("usage: sk-icloud-keychain enroll|sign|list|delete <uuid>\n".utf8))
        return 2
    } catch {
        let code = (error as? HelperError)?.code ?? -1
        debug("error: \(error)")
        var err = Message()
        try? err.set("status", "error")
        try? err.set("error", String(code))
        try? err.set("message", "\(error)".replacingOccurrences(of: "\n", with: " "))
        print(err.serialized, terminator: "")
        return 1
    }
}

exit(run(CommandLine.arguments))
