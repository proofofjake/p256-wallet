import Foundation

public struct Address: Sendable, Hashable {
    public let data: Data

    public static let zero = Address(unchecked: Data(repeating: 0, count: 20))

    public init?(data: Data) {
        guard data.count == 20 else { return nil }
        self.data = data
    }

    private init(unchecked data: Data) {
        self.data = data
    }

    /// Parses `0x`-prefixed hex. Mixed-case input must carry a valid EIP-55 checksum.
    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("0x"), trimmed.count == 42,
              let data = try? Data(hex: trimmed), data.count == 20 else { return nil }
        let body = trimmed.dropFirst(2)
        let isMixedCase = body != body.lowercased() && body != body.uppercased()
        self.data = data
        if isMixedCase, checksummed != trimmed { return nil }
    }

    /// EIP-55 mixed-case checksum encoding.
    public var checksummed: String {
        let lower = data.hex
        let hash = Keccak256.hash(Data(lower.utf8)).hex
        var out = "0x"
        for (char, hashChar) in zip(lower, hash) {
            if char.isLetter, let nibble = hashChar.hexDigitValue, nibble >= 8 {
                out.append(char.uppercased())
            } else {
                out.append(char)
            }
        }
        return out
    }

    /// `0x1234…abcd`
    public var short: String {
        let full = checksummed
        return "\(full.prefix(6))…\(full.suffix(4))"
    }
}

extension Address: CustomStringConvertible {
    public var description: String { checksummed }
}

extension Address: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let address = Address(text.lowercased()) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid address: \(text)")
        }
        self = address
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(checksummed)
    }
}
