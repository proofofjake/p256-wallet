import Foundation

/// A value to be ABI-encoded. Covers the types this wallet needs; not a full Solidity type system.
public indirect enum ABIValue: Sendable, Equatable {
    case uint(UInt256)
    case address(Address)
    case bool(Bool)
    /// `bytes1`…`bytes32`, right-padded.
    case fixedBytes(Data)
    case bytes(Data)
    case string(String)
    /// Dynamic array `T[]`.
    case array([ABIValue])
    case tuple([ABIValue])

    var isDynamic: Bool {
        switch self {
        case .bytes, .string, .array: return true
        case .tuple(let items): return items.contains { $0.isDynamic }
        default: return false
        }
    }

    /// Head size when static.
    var staticSize: Int {
        if case .tuple(let items) = self { return items.reduce(0) { $0 + $1.staticSize } }
        return 32
    }
}

public enum ABI {
    /// Equivalent to Solidity `abi.encode(values...)`.
    public static func encode(_ values: [ABIValue]) -> Data {
        encodeTuple(values)
    }

    /// First four bytes of `keccak256(signature)`.
    public static func selector(_ signature: String) -> Data {
        Keccak256.hash(signature).prefix(4)
    }

    public static func encodeCall(_ signature: String, _ arguments: [ABIValue]) -> Data {
        selector(signature) + encode(arguments)
    }

    static func word(_ value: UInt256) -> Data { value.bigEndianBytes }

    private static func encodeTuple(_ values: [ABIValue]) -> Data {
        let headSize = values.reduce(0) { $0 + ($1.isDynamic ? 32 : $1.staticSize) }
        var head = Data()
        var tail = Data()
        for value in values {
            if value.isDynamic {
                head += word(UInt256(headSize + tail.count))
                tail += encodeValue(value)
            } else {
                head += encodeValue(value)
            }
        }
        return head + tail
    }

    private static func encodeValue(_ value: ABIValue) -> Data {
        switch value {
        case .uint(let number):
            return word(number)
        case .address(let address):
            return address.data.leftPadded(to: 32)
        case .bool(let flag):
            return word(flag ? 1 : 0)
        case .fixedBytes(let data):
            precondition(data.count <= 32, "fixedBytes longer than 32 bytes")
            return data + Data(repeating: 0, count: 32 - data.count)
        case .bytes(let data):
            return encodeDynamicBytes(data)
        case .string(let string):
            return encodeDynamicBytes(Data(string.utf8))
        case .array(let items):
            return word(UInt256(items.count)) + encodeTuple(items)
        case .tuple(let items):
            return encodeTuple(items)
        }
    }

    private static func encodeDynamicBytes(_ data: Data) -> Data {
        let padding = (32 - data.count % 32) % 32
        return word(UInt256(data.count)) + data + Data(repeating: 0, count: padding)
    }
}

public enum ABIDecodingError: Error, Equatable {
    case outOfBounds
    case invalidValue
}

/// Reads values out of ABI-encoded return data.
public struct ABIDecoder: Sendable {
    public let data: Data

    public init(_ data: Data) {
        self.data = Data(data)
    }

    public func word(at offset: Int) throws -> Data {
        guard offset >= 0, offset + 32 <= data.count else { throw ABIDecodingError.outOfBounds }
        return data.subdata(in: offset..<offset + 32)
    }

    public func uint(at offset: Int) throws -> UInt256 {
        guard let value = UInt256(bigEndian: try word(at: offset)) else { throw ABIDecodingError.invalidValue }
        return value
    }

    public func int(at offset: Int) throws -> Int {
        guard let value = try uint(at: offset).uint64Value, value <= UInt64(Int.max) else {
            throw ABIDecodingError.invalidValue
        }
        return Int(value)
    }

    public func bool(at offset: Int) throws -> Bool {
        !(try uint(at: offset)).isZero
    }

    public func address(at offset: Int) throws -> Address {
        guard let address = Address(data: try word(at: offset).suffix(20)) else { throw ABIDecodingError.invalidValue }
        return address
    }

    /// Dynamic `bytes` whose offset word sits at `headOffset`, relative to `base`.
    public func bytes(at headOffset: Int, base: Int = 0) throws -> Data {
        let start = base + (try int(at: headOffset))
        let length = try int(at: start)
        guard start + 32 + length <= data.count else { throw ABIDecodingError.outOfBounds }
        return data.subdata(in: start + 32..<start + 32 + length)
    }

    public func string(at headOffset: Int, base: Int = 0) throws -> String {
        String(decoding: try bytes(at: headOffset, base: base), as: UTF8.self)
    }
}
