import Foundation
@_exported import P256WalletCore

/// Networks come from the core, so contract addresses and gas settings have one source of truth.
public typealias Chain = ChainConfig

extension ChainConfig: @retroactive Identifiable {
    public static var all: [Chain] { chains() }
    public static var baseSepolia: Chain { all.first { $0.id == 84532 }! }

    public var rpc: URL { URL(string: rpcUrl)! }
    public var defaultBundler: URL { URL(string: defaultBundlerUrl)! }
    public var blockscout: URL? { blockscoutUrl.flatMap(URL.init(string:)) }

    public func explorerTransactionURL(_ hash: String) -> URL {
        URL(string: explorerUrl)!.appending(path: "tx/\(hash)")
    }

    public func explorerAddressURL(_ address: String) -> URL {
        URL(string: explorerUrl)!.appending(path: "address/\(address)")
    }
}

extension Token: @retroactive Identifiable {
    public var id: String { address }
}

/// `0x1234…abcd`
public func shortAddress(_ address: String) -> String {
    "\(address.prefix(6))…\(address.suffix(4))"
}

extension String {
    /// For quantities from the core and RPC, which are always normalized (`0x0` for zero).
    public var isZeroQuantity: Bool { self == "0x0" }
}
