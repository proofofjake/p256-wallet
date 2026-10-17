import Foundation

/// Minimal CBOR value model: enough to read WebAuthn attestation objects and COSE keys.
public indirect enum CBOR: Sendable, Equatable {
    case unsigned(UInt64)
    /// Encodes `-1 - n`.
    case negative(UInt64)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([CBORPair])
    case bool(Bool)
    case null
    case undefined

    public subscript(key: CBOR) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    public subscript(key: String) -> CBOR? { self[.text(key)] }

    /// Integer keys as used by COSE (negative values allowed).
    public subscript(intKey key: Int) -> CBOR? {
        self[key >= 0 ? .unsigned(UInt64(key)) : .negative(UInt64(-1 - key))]
    }

    public var bytesValue: Data? {
        if case .bytes(let data) = self { return data }
        return nil
    }

    public var textValue: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .unsigned(let n) where n <= UInt64(Int.max): return Int(n)
        case .negative(let n) where n < UInt64(Int.max): return -1 - Int(n)
        default: return nil
        }
    }
}

public struct CBORPair: Sendable, Equatable {
    public let key: CBOR
    public let value: CBOR
}

public enum CBORError: Error, Equatable {
    case unexpectedEnd
    case unsupported(String)
    case invalidUTF8
}

public enum CBORDecoder {
    public static func decode(_ data: Data) throws -> CBOR {
        var offset = 0
        return try decodeItem(Array(data), &offset)
    }

    /// Decodes the first item and reports how many bytes it consumed.
    public static func decodePrefix(_ data: Data) throws -> (value: CBOR, length: Int) {
        var offset = 0
        let value = try decodeItem(Array(data), &offset)
        return (value, offset)
    }

    private static func decodeItem(_ bytes: [UInt8], _ offset: inout Int) throws -> CBOR {
        guard offset < bytes.count else { throw CBORError.unexpectedEnd }
        let initial = bytes[offset]
        offset += 1
        let major = initial >> 5
        let info = initial & 0x1f

        if major == 7 {
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            case 23: return .undefined
            default: throw CBORError.unsupported("simple/float value \(info)")
            }
        }

        let argument = try readArgument(info, bytes, &offset)
        switch major {
        case 0:
            return .unsigned(argument)
        case 1:
            return .negative(argument)
        case 2:
            return .bytes(Data(try take(Int(argument), bytes, &offset)))
        case 3:
            guard let text = String(bytes: try take(Int(argument), bytes, &offset), encoding: .utf8) else {
                throw CBORError.invalidUTF8
            }
            return .text(text)
        case 4:
            var items = [CBOR]()
            for _ in 0..<argument { items.append(try decodeItem(bytes, &offset)) }
            return .array(items)
        case 5:
            var pairs = [CBORPair]()
            for _ in 0..<argument {
                let key = try decodeItem(bytes, &offset)
                let value = try decodeItem(bytes, &offset)
                pairs.append(CBORPair(key: key, value: value))
            }
            return .map(pairs)
        case 6:
            // Tags: ignore the tag and return the tagged item.
            return try decodeItem(bytes, &offset)
        default:
            throw CBORError.unsupported("major type \(major)")
        }
    }

    private static func readArgument(_ info: UInt8, _ bytes: [UInt8], _ offset: inout Int) throws -> UInt64 {
        switch info {
        case 0..<24:
            return UInt64(info)
        case 24, 25, 26, 27:
            let length = 1 << Int(info - 24)
            return try take(length, bytes, &offset).reduce(0) { $0 << 8 | UInt64($1) }
        default:
            throw CBORError.unsupported("indefinite length or reserved info \(info)")
        }
    }

    private static func take(_ count: Int, _ bytes: [UInt8], _ offset: inout Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, offset + count <= bytes.count else { throw CBORError.unexpectedEnd }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }
}
