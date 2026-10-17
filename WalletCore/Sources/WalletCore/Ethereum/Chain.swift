import Foundation

/// Network configuration. The bundler and paymaster can be overridden at runtime from Settings.
public struct Chain: Sendable, Hashable, Codable, Identifiable {
    public let id: UInt64
    public let name: String
    public let isTestnet: Bool
    public let rpcURL: URL
    public let defaultBundlerURL: URL
    public let explorerURL: URL
    /// Blockscout instance used to discover every ERC-20 the account holds, without an API key.
    public let blockscoutURL: URL?
    /// Checked directly over RPC if the indexer is unavailable.
    public let knownTokens: [Token]
    /// Extra verification gas added on top of the bundler estimate. The estimate runs with a placeholder
    /// signature that fails early, so it never pays for the real P-256 check. On chains without the
    /// RIP-7212 precompile the Solidity fallback costs far more.
    public let verificationGasBuffer: UInt64

    public func explorerTransactionURL(_ hash: String) -> URL {
        explorerURL.appending(path: "tx/\(hash)")
    }

    public func explorerAddressURL(_ address: Address) -> URL {
        explorerURL.appending(path: "address/\(address.checksummed)")
    }

    public static let baseSepolia = Chain(
        id: 84532,
        name: "Base Sepolia",
        isTestnet: true,
        rpcURL: URL(string: "https://sepolia.base.org")!,
        defaultBundlerURL: URL(string: "https://public.pimlico.io/v2/84532/rpc")!,
        explorerURL: URL(string: "https://sepolia.basescan.org")!,
        blockscoutURL: URL(string: "https://base-sepolia.blockscout.com")!,
        knownTokens: [
            Token(address: Address("0x036CbD53842c5426634e7929541eC2318f3dCF7e")!, symbol: "USDC", name: "USD Coin", decimals: 6),
            Token(address: Address("0x4200000000000000000000000000000000000006")!, symbol: "WETH", name: "Wrapped Ether", decimals: 18),
        ],
        verificationGasBuffer: 30_000
    )

    public static let base = Chain(
        id: 8453,
        name: "Base",
        isTestnet: false,
        rpcURL: URL(string: "https://mainnet.base.org")!,
        defaultBundlerURL: URL(string: "https://public.pimlico.io/v2/8453/rpc")!,
        explorerURL: URL(string: "https://basescan.org")!,
        blockscoutURL: URL(string: "https://base.blockscout.com")!,
        knownTokens: [
            Token(address: Address("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")!, symbol: "USDC", name: "USD Coin", decimals: 6),
            Token(address: Address("0x4200000000000000000000000000000000000006")!, symbol: "WETH", name: "Wrapped Ether", decimals: 18),
            Token(address: Address("0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf")!, symbol: "cbBTC", name: "Coinbase Wrapped BTC", decimals: 8),
        ],
        verificationGasBuffer: 30_000
    )

    public static let all: [Chain] = [.baseSepolia, .base]
}
