import Foundation

public enum P256Error: Error, Equatable {
    case invalidDER
    case invalidLength
    case invalidCOSEKey(String)
    case invalidAuthenticatorData(String)
}

/// Uncompressed P-256 public key coordinates.
public struct P256PublicKey: Sendable, Hashable, Codable {
    public let x: Data
    public let y: Data

    public init(x: Data, y: Data) throws {
        guard x.count <= 32, y.count <= 32 else { throw P256Error.invalidLength }
        self.x = x.leftPadded(to: 32)
        self.y = y.leftPadded(to: 32)
    }

    /// 64 bytes `x || y` (CryptoKit `rawRepresentation`).
    public init(raw: Data) throws {
        guard raw.count == 64 else { throw P256Error.invalidLength }
        try self.init(x: raw.prefix(32), y: raw.suffix(32))
    }

    public var raw: Data { x + y }

    /// Parses a COSE_Key (EC2, ES256, P-256) as found in WebAuthn attested credential data.
    public init(coseKey: CBOR) throws {
        guard coseKey[intKey: 1]?.intValue == 2 else { throw P256Error.invalidCOSEKey("kty is not EC2") }
        guard coseKey[intKey: 3]?.intValue == -7 else { throw P256Error.invalidCOSEKey("alg is not ES256") }
        guard coseKey[intKey: -1]?.intValue == 1 else { throw P256Error.invalidCOSEKey("crv is not P-256") }
        guard let x = coseKey[intKey: -2]?.bytesValue, let y = coseKey[intKey: -3]?.bytesValue,
              x.count == 32, y.count == 32 else { throw P256Error.invalidCOSEKey("missing coordinates") }
        try self.init(x: x, y: y)
    }
}

/// ECDSA P-256 signature as `(r, s)`.
public struct P256Signature: Sendable, Equatable {
    public let r: UInt256
    public let s: UInt256

    /// Curve order n.
    public static let n = UInt256(hex: "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")!
    public static let halfN = UInt256(hex: "7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8")!

    public init(r: UInt256, s: UInt256) {
        self.r = r
        self.s = s
    }

    /// 64 bytes `r || s`.
    public init(raw: Data) throws {
        guard raw.count == 64 else { throw P256Error.invalidLength }
        r = UInt256(bigEndian: raw.prefix(32))!
        s = UInt256(bigEndian: raw.suffix(32))!
    }

    /// ASN.1 DER `SEQUENCE { INTEGER r, INTEGER s }`, as returned by WebAuthn authenticators.
    public init(der: Data) throws {
        let bytes = [UInt8](der)
        var offset = 0

        func readLength() throws -> Int {
            guard offset < bytes.count else { throw P256Error.invalidDER }
            let first = bytes[offset]
            offset += 1
            if first < 0x80 { return Int(first) }
            let count = Int(first & 0x7f)
            guard count >= 1, count <= 2, offset + count <= bytes.count else { throw P256Error.invalidDER }
            var length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[offset])
                offset += 1
            }
            return length
        }

        func readInteger() throws -> UInt256 {
            guard offset < bytes.count, bytes[offset] == 0x02 else { throw P256Error.invalidDER }
            offset += 1
            let length = try readLength()
            guard length >= 1, offset + length <= bytes.count else { throw P256Error.invalidDER }
            let value = Data(bytes[offset..<offset + length])
            offset += length
            guard let number = UInt256(bigEndian: value) else { throw P256Error.invalidDER }
            return number
        }

        guard bytes.first == 0x30 else { throw P256Error.invalidDER }
        offset = 1
        let sequenceLength = try readLength()
        guard offset + sequenceLength == bytes.count else { throw P256Error.invalidDER }
        r = try readInteger()
        s = try readInteger()
        guard offset == bytes.count else { throw P256Error.invalidDER }
    }

    /// Low-s form. Coinbase Smart Wallet's WebAuthn verifier rejects `s > n/2` to prevent malleability,
    /// but authenticators (including YubiKeys) return either form.
    public var normalized: P256Signature {
        s > Self.halfN ? P256Signature(r: r, s: Self.n - s) : self
    }

    public var raw: Data { r.bigEndianBytes + s.bigEndianBytes }
}
