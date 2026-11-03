import CryptoKit
import XCTest
@testable import SKCore

final class SKSignatureTests: XCTestCase {
    // Expected bytes computed independently with Python hashlib:
    // sha256(b"ssh:") + bytes([0x05]) + (0x12345678).to_bytes(4, "big")
    //   + sha256(b"hello sk-icloud-keychain")
    let expected = "e30610e8a162115960fe1ec223e6529c9f4b6e80200dcb5e5c321c8af1e2b1bf"
        + "05" + "12345678"
        + "2417e134f2aede6576997d695e31115f3938de8cb23e9e1377059a8c41ddd1d6"
    let data = Data("hello sk-icloud-keychain".utf8)

    func testSignedBufferLayout() {
        let buf = SKSignature.signedBuffer(application: "ssh:", flags: 0x05, counter: 0x1234_5678, data: data)
        XCTAssertEqual(Hex.encode(buf), expected)
    }

    // CryptoKit Ed25519 signatures are randomized, so verify rather than compare bytes.
    func testSignatureVerifiesOverSignedBuffer() throws {
        let key = Curve25519.Signing.PrivateKey()
        let sig = try SKSignature.sign(privateKey: key, application: "ssh:", flags: 0x05,
                                       counter: 0x1234_5678, data: data)
        XCTAssertEqual(sig.count, 64)
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: Hex.decode(expected)!))
        let other = SKSignature.signedBuffer(application: "ssh:other", flags: 0x05, counter: 0x1234_5678, data: data)
        XCTAssertFalse(key.publicKey.isValidSignature(sig, for: other))
    }
}

final class PromptTextTests: XCTestCase {
    func testJapanese() {
        XCTAssertEqual(PromptText.reason(.sign, application: "ssh:icloud", languages: ["ja-JP", "en-JP"]),
                       "SSH 鍵「ssh:icloud」で署名")
        XCTAssertEqual(PromptText.reason(.create, application: "ssh:icloud", languages: ["ja"]),
                       "SSH 鍵「ssh:icloud」を作成")
    }

    func testOtherLanguagesUseEnglish() {
        XCTAssertEqual(PromptText.reason(.delete, application: "ssh:icloud", languages: ["en-US", "ja-JP"]),
                       "delete the SSH key for ssh:icloud")
        XCTAssertEqual(PromptText.reason(.sign, application: "ssh:icloud", languages: []),
                       "sign in with the SSH key for ssh:icloud")
    }
}

final class KeyHandleTests: XCTestCase {
    func testRoundTrip() {
        let h = KeyHandle()
        XCTAssertEqual(KeyHandle(bytes: h.bytes), h)
        XCTAssertTrue(String(data: h.bytes, encoding: .utf8)!.hasPrefix("skick1:"))
    }

    func testRejectsForeignHandles() {
        XCTAssertNil(KeyHandle(bytes: Data(repeating: 0xaa, count: 64)))
        XCTAssertNil(KeyHandle(bytes: Data("skick2:\(UUID().uuidString)".utf8)))
        XCTAssertNil(KeyHandle(bytes: Data("skick1:not-a-uuid".utf8)))
    }
}

final class MessageTests: XCTestCase {
    func testRoundTrip() throws {
        var m = Message()
        try m.set("application", "ssh:")
        try m.set("flags", bytes: Data([0x25]))
        try m.set("data", bytes: Data([0x00, 0xff, 0x10]))
        let parsed = try Message(parsing: m.serialized)
        XCTAssertEqual(parsed, m)
        XCTAssertEqual(try parsed.byte("flags"), 0x25)
        XCTAssertEqual(try parsed.bytes("data"), Data([0x00, 0xff, 0x10]))
        XCTAssertEqual(m.serialized, "application=ssh:\nflags=25\ndata=00ff10\n")
    }

    func testValueMayContainEquals() throws {
        XCTAssertEqual(try Message(parsing: "application=ssh:a=b\n")["application"], "ssh:a=b")
    }

    func testErrors() {
        XCTAssertThrowsError(try Message(parsing: "nonsense\n"))
        XCTAssertThrowsError(try Message(parsing: "flags=zz\n").byte("flags"))
        XCTAssertThrowsError(try Message(parsing: "flags=0102\n").byte("flags"))
        XCTAssertThrowsError(try Message().string("application"))
        var m = Message()
        XCTAssertThrowsError(try m.set("application", "a\nb"))
    }

    func testHex() {
        XCTAssertNil(Hex.decode("abc"))
        XCTAssertNil(Hex.decode("gg"))
        XCTAssertEqual(Hex.decode("ABcd"), Data([0xab, 0xcd]))
    }
}
