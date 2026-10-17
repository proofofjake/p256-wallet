import Foundation
import Testing
@testable import WalletCore

// Expected values generated with Foundry `cast` (see README "Testing").

@Suite struct KeccakTests {
    @Test func knownVectors() {
        #expect(Keccak256.hash(Data()).hex == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        #expect(Keccak256.hash("abc").hex == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
    }

    @Test(arguments: [
        (135, "34367dc248bbd832f4e3e69dfaac2f92638bd0bbd18f2912ba4ef454919cf446"),
        (136, "a6c4d403279fe3e0af03729caada8374b5ca54d8065329a3ebcaeb4b60aa386e"),
        (137, "d869f639c7046b4929fc92a4d988a8b22c55fbadb802c0c66ebcd484f1915f39"),
        (300, "5b7e0e47a96f32a88b4f14ca177982790807c40e1a105742ba0fc1babe1ef826"),
    ])
    func blockBoundaries(length: Int, expected: String) {
        #expect(Keccak256.hash(String(repeating: "a", count: length)).hex == expected)
    }

    @Test func selectors() {
        #expect(ABI.selector("transfer(address,uint256)").hex == "a9059cbb")
        #expect(ABI.selector("createAccount(bytes[],uint256)").hex == "3ffba36f")
        #expect(ABI.selector("getAddress(bytes[],uint256)").hex == "250b1b41")
    }
}

@Suite struct UInt256Tests {
    @Test func decimalRoundTrip() throws {
        let max = "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        #expect(UInt256(decimal: max) == UInt256.max)
        #expect(UInt256.max.decimalString == max)
        #expect(UInt256(decimal: "115792089237316195423570985008687907853269984665640564039457584007913129639936") == nil)
        #expect(UInt256(decimal: "1000000000000000000")?.hexQuantity == "0xde0b6b3a7640000")
        #expect(UInt256.zero.hexQuantity == "0x0")
    }

    @Test func arithmetic() throws {
        let a = try #require(UInt256(decimal: "340282366920938463463374607431768211456")) // 2^128
        #expect(a.multipliedReportingOverflow(by: a).overflow == true) // 2^256
        #expect(a.multipliedReportingOverflow(by: a - 1).overflow == false)
        let b = try #require(UInt256(decimal: "123456789012345678901234567890"))
        let c = try #require(UInt256(decimal: "987654321098765432109876543210"))
        let product = b * c
        #expect(product.decimalString == "121932631137021795226185032733622923332237463801111263526900")
        #expect(product / c == b)
        #expect(product % c == 0)
        #expect((product + 7) % b == 7)
        #expect((UInt256(1) << 255) >> 255 == 1)
        #expect(UInt256.zero.subtractingReportingOverflow(1).overflow)
    }

    @Test func divisionWithLargeDivisor() throws {
        let n = P256Signature.n
        let (q, r) = UInt256.max.quotientAndRemainder(dividingBy: n)
        #expect(q == 1)
        #expect(r == UInt256.max - n)
    }

    @Test func bigEndianBytes() throws {
        let value = try #require(UInt256(hex: "0x0102"))
        #expect(value.bigEndianBytes.hex == String(repeating: "0", count: 60) + "0102")
        #expect(UInt256(bigEndian: value.bigEndianBytes) == value)
    }
}

@Suite struct UnitsTests {
    @Test func parse() {
        #expect(Units.parse("1.5", decimals: 18) == UInt256(decimal: "1500000000000000000"))
        #expect(Units.parse("0.000001", decimals: 6) == 1)
        #expect(Units.parse(".5", decimals: 6) == 500_000)
        #expect(Units.parse("10", decimals: 0) == 10)
        #expect(Units.parse("0.0000001", decimals: 6) == nil)
        #expect(Units.parse("1.2.3", decimals: 18) == nil)
        #expect(Units.parse("abc", decimals: 18) == nil)
        #expect(Units.parse("", decimals: 18) == nil)
    }

    @Test func format() throws {
        #expect(Units.format(try #require(UInt256(decimal: "1234567890000000000000")), decimals: 18) == "1,234.56789")
        #expect(Units.format(1_500_000, decimals: 6) == "1.5")
        #expect(Units.format(1, decimals: 18) == "<0.000001")
        #expect(Units.format(0, decimals: 18) == "0")
        #expect(Units.plain(try #require(UInt256(decimal: "1000000000000000001")), decimals: 18) == "1.000000000000000001")
    }
}

@Suite struct AddressTests {
    @Test(arguments: [
        "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
        "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
        "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
        "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
    ])
    func eip55(_ checksummed: String) throws {
        let address = try #require(Address(checksummed.lowercased()))
        #expect(address.checksummed == checksummed)
        #expect(Address(checksummed) != nil)
    }

    @Test func rejectsBadChecksum() {
        #expect(Address("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD") == nil)
        #expect(Address("0x1234") == nil)
    }
}

@Suite struct ABITests {
    @Test func createAccount() {
        let owners = [Data(repeating: 0x11, count: 64), Data(repeating: 0x22, count: 64)]
        let expected = "3ffba36f000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000004011111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000004022222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222"
        #expect(CoinbaseSmartWallet.createAccountCalldata(owners: owners).hex == expected)
    }

    @Test func executeBatch() {
        let calls = [
            CoinbaseSmartWallet.Call(target: Address("0x1111111111111111111111111111111111111111")!, value: 1, data: Data([0xde, 0xad, 0xbe, 0xef])),
            CoinbaseSmartWallet.Call(target: Address("0x2222222222222222222222222222222222222222")!),
        ]
        let expected = "34fcd5be00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000004deadbeef000000000000000000000000000000000000000000000000000000000000000000000000000000002222222222222222222222222222222222222222000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000"
        #expect(CoinbaseSmartWallet.executeBatchCalldata(calls).hex == expected)
    }

    @Test func execute() {
        let call = CoinbaseSmartWallet.Call(
            target: Address("0x3333333333333333333333333333333333333333")!,
            value: UInt256(decimal: "1000000000000000000")!,
            data: Data([0xa9, 0x05, 0x9c, 0xbb])
        )
        let expected = "b61d27f600000000000000000000000033333333333333333333333333333333333333330000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000004a9059cbb00000000000000000000000000000000000000000000000000000000"
        #expect(CoinbaseSmartWallet.executeCalldata(call).hex == expected)
    }

    @Test func signatureWrapper() {
        let expected = "0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000004cafebabe00000000000000000000000000000000000000000000000000000000"
        #expect(CoinbaseSmartWallet.wrapSignature(ownerIndex: 2, signatureData: Data([0xca, 0xfe, 0xba, 0xbe])).hex == expected)
    }

    @Test func webAuthnAuthStruct() {
        let encoded = ABI.encode([.tuple([.bytes(Data([1, 2])), .string("abc"), .uint(23), .uint(1), .uint(5), .uint(6)])])
        let expected = "000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000170000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000002010200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000036162630000000000000000000000000000000000000000000000000000000000"
        #expect(encoded.hex == expected)
    }

    @Test func functionCallEncoder() throws {
        let transfer = try FunctionCall.encode(
            signature: "transfer(address to, uint amount)",
            arguments: ["0x036CbD53842c5426634e7929541eC2318f3dCF7e", "1500000"]
        )
        #expect(transfer.hex == "a9059cbb000000000000000000000000036cbd53842c5426634e7929541ec2318f3dcf7e000000000000000000000000000000000000000000000000000000000016e360")

        let mixed = try FunctionCall.encode(signature: "foo(bool,bytes4,string,uint8)", arguments: ["true", "0xdeadbeef", "hello", "255"])
        #expect(mixed.hex == "f13264560000000000000000000000000000000000000000000000000000000000000001deadbeef00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000ff000000000000000000000000000000000000000000000000000000000000000568656c6c6f000000000000000000000000000000000000000000000000000000")

        #expect(throws: FunctionCallError.invalidArgument(type: "uint8", value: "256")) {
            try FunctionCall.encode(signature: "f(uint8)", arguments: ["256"])
        }
        #expect(throws: FunctionCallError.self) {
            try FunctionCall.encode(signature: "f(uint256[])", arguments: ["1"])
        }
    }

    @Test func decoder() throws {
        let data = ABI.encode([.uint(42), .bytes(Data([1, 2, 3])), .address(Address("0x1111111111111111111111111111111111111111")!)])
        let decoder = ABIDecoder(data)
        #expect(try decoder.uint(at: 0) == 42)
        #expect(try decoder.bytes(at: 32) == Data([1, 2, 3]))
        #expect(try decoder.address(at: 64) == Address("0x1111111111111111111111111111111111111111"))
    }
}

@Suite struct MessageHashTests {
    @Test func personalSign() {
        #expect(personalMessageHash(Data("hello world".utf8)).hex == "d9eba16ed0ecae432b71fe008c98cc872bb4cc214d3220a36f365326cf807d68")
    }

    @Test func replaySafeHash() throws {
        // Matches CoinbaseSmartWallet.replaySafeHash() on the deployed implementation (checked via eth_call).
        let hash = Data(repeating: 0xab, count: 32)
        let account = try #require(Address("0x1234567890123456789012345678901234567890"))
        #expect(CoinbaseSmartWallet.replaySafeHash(hash, account: account, chainID: 84532).hex
            == "635f6857102c57d2fc12f5a61f2606c6f85d88e0a00999dc0e3663fd2f633a4a")
    }
}
