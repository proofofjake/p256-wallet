import Foundation

public enum HexError: Error, Equatable {
    case invalidHex(String)
}

extension Data {
    /// Parses a hex string, with or without a `0x` prefix. Odd-length input is left-padded with a zero nibble.
    public init(hex: String) throws {
        var digits = Substring(hex)
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") { digits = digits.dropFirst(2) }
        var bytes = [UInt8]()
        bytes.reserveCapacity((digits.utf8.count + 1) / 2)
        var pending: UInt8? = digits.utf8.count % 2 == 1 ? 0 : nil
        for char in digits.utf8 {
            guard let nibble = Self.nibble(char) else { throw HexError.invalidHex(hex) }
            if let high = pending {
                bytes.append(high << 4 | nibble)
                pending = nil
            } else {
                pending = nibble
            }
        }
        self.init(bytes)
    }

    /// Lowercase hex without a prefix.
    public var hex: String {
        let table = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(table[Int(byte >> 4)])
            out.append(table[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Lowercase hex with a `0x` prefix.
    public var hexPrefixed: String { "0x" + hex }

    private static func nibble(_ char: UInt8) -> UInt8? {
        switch char {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return char - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return char - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return char - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// Left-pads with zeros to `length` bytes. Returns self unchanged if already at least that long.
    func leftPadded(to length: Int) -> Data {
        count >= length ? self : Data(repeating: 0, count: length - count) + self
    }
}
