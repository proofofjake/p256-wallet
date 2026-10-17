import CryptoKit
import Foundation
import Testing
@testable import WalletClient

/// Runs against live Base Sepolia. Enable with `WALLET_INTEGRATION=1 swift test`.
///
/// The signing core proves its signatures against the real contracts in its own repo. These cover the app's side:
/// fetching state, the bundler's gas estimate, the full prepare-and-sign flow, and token discovery.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WALLET_INTEGRATION"] != nil))
struct BaseSepoliaIntegrationTests {
    let chain = Chain.baseSepolia

    private func makeAccount() throws -> (SmartAccount, LocalWebAuthnSigner, [OwnerKey]) {
        let key = P256.Signing.PrivateKey()
        let signer = LocalWebAuthnSigner(privateKey: key)
        let raw = key.publicKey.rawRepresentation
        let owner = OwnerKey(
            credentialId: signer.credentialID.hexPrefixed,
            ownerIndex: 0,
            publicKey: PublicKey(x: raw.prefix(32).hexPrefixed, y: raw.suffix(32).hexPrefixed)
        )
        let initialOwners = [try ownerBytes(key: owner.publicKey)]
        let account = SmartAccount(address: try accountAddress(initialOwners: initialOwners), initialOwners: initialOwners, chain: chain)
        return (account, signer, [owner])
    }

    @Test func freshAccountState() async throws {
        let (account, _, _) = try makeAccount()
        #expect(try await account.isDeployed() == false)
        #expect(try await account.nonce() == "0x0")
        #expect(try await account.balance() == "0x0")
        #expect(try await account.nextOwnerIndex() == 1)
    }

    @Test func prepareAndSignForAnUnfundedAccount() async throws {
        let (account, signer, owners) = try makeAccount()
        let call = try transferCall(token: nil, to: "0x000000000000000000000000000000000000dEaD", amount: "0x1")
        let prepared = try await account.prepare(calls: [call], signingOwnerIndex: 0)
        #expect(prepared.review.deploysAccount)
        #expect(!prepared.review.sponsored)
        // Deployment dominates verification gas for a first operation.
        #expect(try compareQuantities(a: prepared.userOperation.verificationGasLimit, b: "0x30d40") == 1)
        #expect(prepared.review.details.first?.value == "0.000000000000000001 ETH")
        #expect(try compareQuantities(a: prepared.review.requiredBalance, b: prepared.review.maxGasCost) == 1)

        let signed = try await account.sign(prepared, signer: signer, owners: owners)
        #expect(signed.signature != "0x")
        #expect(try userOperationHash(op: signed, chainId: chain.id) == prepared.review.hash)
    }

    @Test func revertingCallSurfacesReadableReason() async throws {
        let (account, _, _) = try makeAccount()
        let usdc = chain.knownTokens[0].address
        let call = try transferCall(token: usdc, to: "0x000000000000000000000000000000000000dEaD", amount: "0x1")
        do {
            _ = try await account.prepare(calls: [call], signingOwnerIndex: 0)
            Issue.record("expected the transfer to revert in simulation")
        } catch let error as RPCError {
            #expect(error.errorDescription?.contains("transfer amount exceeds balance") == true, "\(error.message)")
        }
    }

    @Test func blockscoutListsTokens() async throws {
        let provider = BlockscoutTokenProvider(baseURL: try #require(chain.blockscout))
        // The WETH predeploy holds plenty of airdropped tokens.
        let balances = try await provider.balances(of: "0x4200000000000000000000000000000000000006")
        #expect(!balances.isEmpty)
        #expect(balances.allSatisfy { !$0.balance.isZeroQuantity })
    }

    @Test func blockscoutEmptyForFreshAddress() async throws {
        let provider = BlockscoutTokenProvider(baseURL: try #require(chain.blockscout))
        let fresh = try checksumAddress(address: Data((0..<20).map { _ in UInt8.random(in: 0...255) }).hexPrefixed)
        #expect(try await provider.balances(of: fresh).isEmpty)
    }

    @Test func knownTokensOverRPC() async throws {
        let provider = KnownTokenProvider(client: EthereumClient(url: chain.rpc), tokens: chain.knownTokens)
        let (account, _, _) = try makeAccount()
        #expect(try await provider.balances(of: account.address).isEmpty)
    }
}
