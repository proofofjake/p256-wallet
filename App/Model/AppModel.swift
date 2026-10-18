import Foundation
import Observation
import WalletClient

enum AppConfig {
    /// WebAuthn relying party ID: the domain in the associated-domains entitlement. Set in Config/Local.xcconfig.
    static let relyingPartyID: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "RelyingPartyID") as? String ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }()

    static var securityKeysConfigured: Bool { !relyingPartyID.isEmpty && !isSimulator }
}

@MainActor
@Observable
final class AppModel {
    private(set) var wallet: WalletRecord?
    /// Wei, as a hex quantity.
    private(set) var ethBalance: String?
    private(set) var tokens: [TokenBalance] = []
    private(set) var isDeployed: Bool?
    private(set) var isRefreshing = false
    var refreshError: String?

    var chain: Chain {
        didSet {
            guard chain != oldValue else { return }
            UserDefaults.standard.set(Int(chain.id), forKey: Self.chainKey)
            ethBalance = nil
            tokens = []
            isDeployed = nil
            Task { await refresh() }
        }
    }

    private(set) var endpointOverrides: [UInt64: Endpoints]

    let authenticator: SecurityKeyAuthenticator?

    private static let chainKey = "selectedChainID"
    private static let endpointsKey = "endpointOverrides.v1"

    init() {
        wallet = WalletStore.load()
        let savedChainID = UInt64(UserDefaults.standard.integer(forKey: Self.chainKey))
        chain = Chain.all.first { $0.id == savedChainID } ?? .baseSepolia
        if let data = UserDefaults.standard.data(forKey: Self.endpointsKey),
           let saved = try? JSONDecoder().decode([UInt64: Endpoints].self, from: data) {
            endpointOverrides = saved
        } else {
            endpointOverrides = [:]
        }
        authenticator = AppConfig.securityKeysConfigured ? SecurityKeyAuthenticator(relyingPartyID: AppConfig.relyingPartyID) : nil

        #if DEBUG
        // UI tests start from a clean slate on Base Sepolia.
        if ProcessInfo.processInfo.arguments.contains("-resetWallet") {
            removeWallet()
            chain = .baseSepolia
        }
        // UI tests: forget the wallet record but keep device keys, as after reinstalling (the Keychain survives).
        if ProcessInfo.processInfo.arguments.contains("-forgetWalletRecord") {
            WalletStore.delete()
            wallet = nil
        }
        #endif
    }

    // MARK: Derived

    var account: SmartAccount? {
        guard let wallet else { return nil }
        let endpoints = endpoints(for: chain)
        return SmartAccount(
            address: wallet.address,
            initialOwners: wallet.initialOwners.map(\.hexPrefixed),
            chain: chain,
            bundlerURL: endpoints.bundler,
            paymasterURL: endpoints.paymaster
        )
    }

    /// Keys that are owners on the selected chain.
    var activeKeys: [WalletKey] {
        wallet?.keys.filter { $0.isOwner(on: chain) } ?? []
    }

    var ownerKeys: [OwnerKey] { activeKeys.map(\.ownerKey) }

    var signer: WalletSigner { WalletSigner(keys: activeKeys, authenticator: authenticator) }

    /// Tokens the review can name: the network's known tokens plus any the indexer found in this wallet.
    var reviewTokens: [Token] {
        let found = tokens.map(\.token).filter { token in !chain.knownTokens.contains { $0.address == token.address } }
        return chain.knownTokens + found
    }

    func endpoints(for chain: Chain) -> Endpoints {
        endpointOverrides[chain.id] ?? Endpoints()
    }

    func setEndpoints(_ endpoints: Endpoints, for chain: Chain) {
        endpointOverrides[chain.id] = endpoints
        if let data = try? JSONEncoder().encode(endpointOverrides) {
            UserDefaults.standard.set(data, forKey: Self.endpointsKey)
        }
    }

    // MARK: Actions

    func refresh() async {
        guard let wallet else { return }
        let chain = self.chain
        let client = EthereumClient(url: chain.rpc)
        let provider = CompositeTokenProvider(
            primary: chain.blockscout.map { BlockscoutTokenProvider(baseURL: $0) },
            fallback: KnownTokenProvider(client: client, tokens: chain.knownTokens)
        )
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let balance = client.balance(of: wallet.address)
            async let deployed = client.isDeployed(wallet.address)
            async let tokenBalances = provider.balances(of: wallet.address)
            let results = try await (balance, deployed, tokenBalances)
            // Drop results if the user switched networks mid-flight.
            guard chain == self.chain else { return }
            (ethBalance, isDeployed, tokens) = results
            refreshError = nil
        } catch {
            guard chain == self.chain else { return }
            refreshError = error.localizedDescription
        }
    }

    /// Has the core derive the counterfactual address for `keys` (in order) and saves the wallet. Nothing goes
    /// onchain until the first transaction, which deploys the account.
    func createWallet(with keys: [NewKey]) async throws {
        let owners = try keys.map { try ownerBytes(key: $0.publicKey.core) }
        let address = try accountAddress(initialOwners: owners)
        let record = WalletRecord(
            address: address,
            initialOwners: try owners.map { try Data(hex: $0) },
            keys: keys.enumerated().map { WalletKey($1, ownerIndex: $0, addedOnChainID: nil) },
            createdAt: .now
        )
        try WalletStore.save(record)
        wallet = record
        await refresh()
    }

    /// Restores a wallet from a backup file exported in Settings. The signing core checks the file's keys produce its
    /// address before anything is saved.
    func restoreWallet(from data: Data) async throws {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let keys = object["keys"] as? [[String: Any]], keys.contains(where: { $0["credentialId"] != nil }) {
            throw RestoreError.fromExtension
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(WalletRecord.self, from: data) else { throw RestoreError.notABackup }
        let address = try checkWalletRecord(
            address: record.address,
            initialOwners: record.initialOwners.map(\.hexPrefixed),
            keys: record.keys.map(\.ownerKey)
        )
        guard record.keys.contains(where: { $0.kind == .securityKey || DeviceKeys.exists($0) }) else {
            throw RestoreError.noUsableKeys
        }
        let restored = WalletRecord(address: address, initialOwners: record.initialOwners, keys: record.keys, createdAt: record.createdAt)
        try WalletStore.save(restored)
        wallet = restored
        await refresh()
    }

    /// Records a key after its `addOwnerPublicKey` transaction confirmed on the current chain.
    func recordAddedKey(_ key: NewKey, ownerIndex: Int) throws {
        guard var record = wallet else { return }
        record.keys.append(WalletKey(key, ownerIndex: ownerIndex, addedOnChainID: chain.id))
        try WalletStore.save(record)
        wallet = record
    }

    func removeWallet() {
        for key in wallet?.keys ?? [] where key.kind != .securityKey {
            DeviceKeys.delete(key)
        }
        WalletStore.delete()
        wallet = nil
        ethBalance = nil
        tokens = []
        isDeployed = nil
    }
}

enum RestoreError: LocalizedError {
    case notABackup
    case fromExtension
    case noUsableKeys

    var errorDescription: String? {
        switch self {
        case .notABackup:
            "This file isn't a P256 Wallet backup. Choose the file saved from Settings → Export backup file."
        case .fromExtension:
            "This backup is from the browser extension. Its keys only work there, so it can't be restored on iPhone."
        case .noUsableKeys:
            "None of this backup's keys can sign on this phone. Test keys live only on the phone that made them, and are deleted when a wallet is removed."
        }
    }
}
