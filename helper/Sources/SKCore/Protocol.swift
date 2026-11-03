import Foundation

/// Line-oriented message exchanged between the provider dylib and the helper.
///
/// Each line is `key=value`. Byte strings are lowercase hex; text values must
/// not contain newlines. See docs/protocol.md.
struct Message: Equatable {
    private(set) var fields: [(key: String, value: String)] = []

    init() {}

    init(parsing text: String) throws {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "=") else {
                throw ProtocolError.malformedLine(String(line))
            }
            fields.append((String(line[..<eq]), String(line[line.index(after: eq)...])))
        }
    }

    static func == (a: Message, b: Message) -> Bool {
        a.fields.elementsEqual(b.fields) { $0.key == $1.key && $0.value == $1.value }
    }

    subscript(key: String) -> String? {
        fields.first { $0.key == key }?.value
    }

    mutating func set(_ key: String, _ value: String) throws {
        guard !key.contains("="), !key.contains("\n"), !value.contains("\n") else {
            throw ProtocolError.invalidValue(key)
        }
        fields.append((key, value))
    }

    mutating func set(_ key: String, bytes: Data) throws {
        try set(key, Hex.encode(bytes))
    }

    func string(_ key: String) throws -> String {
        guard let v = self[key] else { throw ProtocolError.missingField(key) }
        return v
    }

    func bytes(_ key: String) throws -> Data {
        guard let d = Hex.decode(try string(key)) else { throw ProtocolError.invalidValue(key) }
        return d
    }

    func byte(_ key: String) throws -> UInt8 {
        let d = try bytes(key)
        guard d.count == 1 else { throw ProtocolError.invalidValue(key) }
        return d[d.startIndex]
    }

    var serialized: String {
        fields.map { "\($0.key)=\($0.value)\n" }.joined()
    }
}

enum ProtocolError: Error, Equatable {
    case malformedLine(String)
    case missingField(String)
    case invalidValue(String)
}

enum Hex {
    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ s: String) -> Data? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
