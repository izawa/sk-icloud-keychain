import CryptoKit
import Foundation

/// sk-api flag bits (provider/sk-api.h).
enum SKFlags {
    static let userPresence: UInt8 = 0x01
    static let userVerification: UInt8 = 0x04
    static let force: UInt8 = 0x10
    static let residentKey: UInt8 = 0x20
}

/// Builds and signs the FIDO-style message OpenSSH verifies for
/// sk-ssh-ed25519@openssh.com:
///   SHA256(application) || flags || counter (big-endian u32) || SHA256(data)
/// Mirrors sig_ed25519() in openssh-portable regress/misc/sk-dummy/sk-dummy.c.
enum SKSignature {
    static func signedBuffer(application: String, flags: UInt8, counter: UInt32, data: Data) -> Data {
        var buf = Data(SHA256.hash(data: Data(application.utf8)))
        buf.append(flags)
        withUnsafeBytes(of: counter.bigEndian) { buf.append(contentsOf: $0) }
        buf.append(contentsOf: SHA256.hash(data: data))
        return buf
    }

    static func sign(privateKey: Curve25519.Signing.PrivateKey, application: String,
                     flags: UInt8, counter: UInt32, data: Data) throws -> Data {
        let buf = signedBuffer(application: application, flags: flags, counter: counter, data: data)
        return try privateKey.signature(for: buf)
    }
}

/// Opaque handle stored in the user's sk key file. Versioned because key files
/// outlive any one release of this tool.
struct KeyHandle: Equatable {
    static let prefix = "skick1:"

    let id: UUID

    init(id: UUID = UUID()) { self.id = id }

    init?(bytes: Data) {
        guard let s = String(data: bytes, encoding: .utf8), s.hasPrefix(Self.prefix),
              let id = UUID(uuidString: String(s.dropFirst(Self.prefix.count))) else { return nil }
        self.id = id
    }

    var bytes: Data { Data((Self.prefix + id.uuidString).utf8) }
}
