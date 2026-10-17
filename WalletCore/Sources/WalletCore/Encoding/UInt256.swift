import Foundation

/// Unsigned 256-bit integer with just enough arithmetic for token amounts, gas math and curve-order checks.
public struct UInt256: Sendable, Hashable, Comparable {
    /// Little-endian 64-bit limbs: `limbs[0]` is least significant.
    private var limbs: [UInt64]

    public static let zero = UInt256(0)
    public static let max = UInt256(limbs: [.max, .max, .max, .max])

    public init(_ value: UInt64) {
        limbs = [value, 0, 0, 0]
    }

    public init(_ value: Int) {
        precondition(value >= 0, "UInt256 cannot represent negative values")
        self.init(UInt64(value))
    }

    private init(limbs: [UInt64]) {
        precondition(limbs.count == 4)
        self.limbs = limbs
    }

    /// Big-endian bytes, at most 32.
    public init?(bigEndian data: Data) {
        let trimmed = data.drop(while: { $0 == 0 })
        guard trimmed.count <= 32 else { return nil }
        let bytes = [UInt8](Data(trimmed).leftPadded(to: 32))
        var limbs = [UInt64](repeating: 0, count: 4)
        for i in 0..<32 {
            limbs[3 - i / 8] |= UInt64(bytes[i]) << (8 * UInt64(7 - i % 8))
        }
        self.limbs = limbs
    }

    /// Hex with or without `0x`.
    public init?(hex: String) {
        guard let data = try? Data(hex: hex) else { return nil }
        self.init(bigEndian: data)
    }

    /// Base-10 digits only.
    public init?(decimal: String) {
        guard !decimal.isEmpty else { return nil }
        var result = UInt256.zero
        for char in decimal.utf8 {
            guard char >= UInt8(ascii: "0"), char <= UInt8(ascii: "9") else { return nil }
            let (times10, o1) = result.multipliedReportingOverflow(by: 10)
            let (sum, o2) = times10.addingReportingOverflow(UInt256(UInt64(char - UInt8(ascii: "0"))))
            if o1 || o2 { return nil }
            result = sum
        }
        self = result
    }

    /// Accepts decimal digits or `0x`-prefixed hex.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            self.init(hex: trimmed)
        } else {
            self.init(decimal: trimmed)
        }
    }

    public var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

    /// 32 big-endian bytes.
    public var bigEndianBytes: Data {
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 {
            out[i] = UInt8(truncatingIfNeeded: limbs[3 - i / 8] >> (8 * UInt64(7 - i % 8)))
        }
        return Data(out)
    }

    /// JSON-RPC quantity encoding: `0x`-prefixed hex without leading zeros (`0x0` for zero).
    public var hexQuantity: String {
        let digits = bigEndianBytes.hex.drop(while: { $0 == "0" })
        return "0x" + (digits.isEmpty ? "0" : digits)
    }

    public var decimalString: String {
        if isZero { return "0" }
        var chunks = [UInt64]()
        var value = self
        let base: UInt64 = 10_000_000_000_000_000_000 // 10^19
        while !value.isZero {
            let (q, r) = value.quotientAndRemainder(dividingBy: base)
            chunks.append(r)
            value = q
        }
        var out = String(chunks.removeLast())
        for chunk in chunks.reversed() {
            let s = String(chunk)
            out += String(repeating: "0", count: 19 - s.count) + s
        }
        return out
    }

    /// Value as UInt64 if it fits.
    public var uint64Value: UInt64? {
        limbs[1] == 0 && limbs[2] == 0 && limbs[3] == 0 ? limbs[0] : nil
    }

    public var bitWidth: Int {
        for i in stride(from: 3, through: 0, by: -1) where limbs[i] != 0 {
            return i * 64 + (64 - limbs[i].leadingZeroBitCount)
        }
        return 0
    }

    // MARK: Arithmetic

    public func addingReportingOverflow(_ other: UInt256) -> (partialValue: UInt256, overflow: Bool) {
        var out = [UInt64](repeating: 0, count: 4)
        var carry = false
        for i in 0..<4 {
            let (s1, c1) = limbs[i].addingReportingOverflow(other.limbs[i])
            let (s2, c2) = s1.addingReportingOverflow(carry ? 1 : 0)
            out[i] = s2
            carry = c1 || c2
        }
        return (UInt256(limbs: out), carry)
    }

    public func subtractingReportingOverflow(_ other: UInt256) -> (partialValue: UInt256, overflow: Bool) {
        var out = [UInt64](repeating: 0, count: 4)
        var borrow = false
        for i in 0..<4 {
            let (d1, b1) = limbs[i].subtractingReportingOverflow(other.limbs[i])
            let (d2, b2) = d1.subtractingReportingOverflow(borrow ? 1 : 0)
            out[i] = d2
            borrow = b1 || b2
        }
        return (UInt256(limbs: out), borrow)
    }

    public func multipliedReportingOverflow(by other: UInt256) -> (partialValue: UInt256, overflow: Bool) {
        var wide = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (high, low) = limbs[i].multipliedFullWidth(by: other.limbs[j])
                let (s1, c1) = wide[i + j].addingReportingOverflow(low)
                let (s2, c2) = s1.addingReportingOverflow(carry)
                wide[i + j] = s2
                // Cannot overflow: the full column sum fits in 128 bits.
                carry = high &+ (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
            }
            wide[i + 4] = carry
        }
        let overflow = wide[4...].contains { $0 != 0 }
        return (UInt256(limbs: Array(wide[0..<4])), overflow)
    }

    public func quotientAndRemainder(dividingBy divisor: UInt64) -> (quotient: UInt256, remainder: UInt64) {
        precondition(divisor != 0, "Division by zero")
        var quotient = [UInt64](repeating: 0, count: 4)
        var remainder: UInt64 = 0
        for i in stride(from: 3, through: 0, by: -1) {
            let (q, r) = divisor.dividingFullWidth((high: remainder, low: limbs[i]))
            quotient[i] = q
            remainder = r
        }
        return (UInt256(limbs: quotient), remainder)
    }

    public func quotientAndRemainder(dividingBy divisor: UInt256) -> (quotient: UInt256, remainder: UInt256) {
        precondition(!divisor.isZero, "Division by zero")
        if self < divisor { return (.zero, self) }
        if let small = divisor.uint64Value {
            let (q, r) = quotientAndRemainder(dividingBy: small)
            return (q, UInt256(r))
        }
        var quotient = UInt256.zero
        var remainder = UInt256.zero
        for bit in stride(from: bitWidth - 1, through: 0, by: -1) {
            let carriedOut = remainder.testBit(255)
            remainder = remainder << 1
            if testBit(bit) { remainder.limbs[0] |= 1 }
            if carriedOut || remainder >= divisor {
                // Wrapping subtraction is exact here because the true value is < 2 * divisor.
                remainder = remainder.subtractingReportingOverflow(divisor).partialValue
                quotient.limbs[bit / 64] |= 1 << UInt64(bit % 64)
            }
        }
        return (quotient, remainder)
    }

    public func testBit(_ index: Int) -> Bool {
        (limbs[index / 64] >> UInt64(index % 64)) & 1 == 1
    }

    public static func << (lhs: UInt256, rhs: Int) -> UInt256 {
        guard rhs > 0 else { return lhs }
        guard rhs < 256 else { return .zero }
        var out = [UInt64](repeating: 0, count: 4)
        let limbShift = rhs / 64
        let bitShift = UInt64(rhs % 64)
        for i in stride(from: 3, through: limbShift, by: -1) {
            out[i] = lhs.limbs[i - limbShift] << bitShift
            if bitShift > 0, i - limbShift - 1 >= 0 {
                out[i] |= lhs.limbs[i - limbShift - 1] >> (64 - bitShift)
            }
        }
        return UInt256(limbs: out)
    }

    public static func >> (lhs: UInt256, rhs: Int) -> UInt256 {
        guard rhs > 0 else { return lhs }
        guard rhs < 256 else { return .zero }
        var out = [UInt64](repeating: 0, count: 4)
        let limbShift = rhs / 64
        let bitShift = UInt64(rhs % 64)
        for i in 0..<(4 - limbShift) {
            out[i] = lhs.limbs[i + limbShift] >> bitShift
            if bitShift > 0, i + limbShift + 1 < 4 {
                out[i] |= lhs.limbs[i + limbShift + 1] << (64 - bitShift)
            }
        }
        return UInt256(limbs: out)
    }

    /// Trapping operators, for internal math where overflow indicates a bug.
    public static func + (lhs: UInt256, rhs: UInt256) -> UInt256 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        precondition(!overflow, "UInt256 addition overflow")
        return value
    }

    public static func - (lhs: UInt256, rhs: UInt256) -> UInt256 {
        let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
        precondition(!overflow, "UInt256 subtraction underflow")
        return value
    }

    public static func * (lhs: UInt256, rhs: UInt256) -> UInt256 {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        precondition(!overflow, "UInt256 multiplication overflow")
        return value
    }

    public static func / (lhs: UInt256, rhs: UInt256) -> UInt256 {
        lhs.quotientAndRemainder(dividingBy: rhs).quotient
    }

    public static func % (lhs: UInt256, rhs: UInt256) -> UInt256 {
        lhs.quotientAndRemainder(dividingBy: rhs).remainder
    }

    public static func < (lhs: UInt256, rhs: UInt256) -> Bool {
        for i in stride(from: 3, through: 0, by: -1) where lhs.limbs[i] != rhs.limbs[i] {
            return lhs.limbs[i] < rhs.limbs[i]
        }
        return false
    }

    public static func power(_ base: UInt256, _ exponent: Int) -> UInt256? {
        var result = UInt256(1)
        for _ in 0..<exponent {
            let (next, overflow) = result.multipliedReportingOverflow(by: base)
            if overflow { return nil }
            result = next
        }
        return result
    }
}

extension UInt256: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        self.init(value)
    }
}

extension UInt256: CustomStringConvertible {
    public var description: String { decimalString }
}

extension UInt256: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = UInt256(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid UInt256: \(text)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexQuantity)
    }
}
