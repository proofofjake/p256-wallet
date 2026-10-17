import CryptoKit
import Foundation
import Testing
@testable import WalletCore

/// Runs against live Base Sepolia contracts. Enable with `WALLETCORE_INTEGRATION=1 swift test`.
///
/// These prove the whole signing pipeline against the real Coinbase Smart Wallet and EntryPoint without
/// needing funds: `simulateValidation` with zero gas fees requires no prefund, and reports whether the
/// account accepted the signature.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WALLETCORE_INTEGRATION"] != nil))
struct BaseSepoliaIntegrationTests {
    let chain = Chain.baseSepolia
    let client = EthereumClient(url: Chain.baseSepolia.rpcURL)

    private func makeAccount(owners: [P256PublicKey]) async throws -> SmartAccount {
        let ownerBytes = owners.map(CoinbaseSmartWallet.ownerBytes)
        let address = try await CoinbaseSmartWallet.accountAddress(owners: ownerBytes, client: client)
        return SmartAccount(address: address, initialOwners: ownerBytes, chain: chain)
    }

    private func testOperation(for account: SmartAccount) -> UserOperation {
        UserOperation(
            sender: account.address,
            nonce: 0,
            initCode: CoinbaseSmartWallet.initCode(owners: account.initialOwners),
            callData: CoinbaseSmartWallet.executeCalldata(.init(target: Address("0x000000000000000000000000000000000000dEaD")!)),
            callGasLimit: 100_000,
            verificationGasLimit: 3_000_000,
            preVerificationGas: 100_000
        )
    }

    /// Calls `EntryPoint.simulateValidation`, which always reverts; returns `sigFailed` from `ValidationResult`.
    private func simulateValidation(_ op: UserOperation) async throws -> Bool {
        let call = ABI.encodeCall(
            "simulateValidation((address,uint256,bytes,bytes,uint256,uint256,uint256,uint256,uint256,bytes,bytes))",
            [op.abiTuple]
        )
        do {
            _ = try await client.call(to: CoinbaseSmartWallet.entryPoint, data: call)
            Issue.record("simulateValidation unexpectedly succeeded")
            return true
        } catch let error as RPCError {
            let revert = try #require(error.revertData, "no revert data: \(error.message)")
            let selector = revert.prefix(4).hex
            if selector == ABI.selector("FailedOp(uint256,string)").hex {
                let reason = try ABIDecoder(revert.dropFirst(4)).string(at: 32)
                Issue.record("FailedOp: \(reason)")
                return true
            }
            #expect(selector == ABI.selector("ValidationResult((uint256,uint256,bool,uint48,uint48,bytes),(uint256,uint256),(uint256,uint256),(uint256,uint256))").hex)
            let result = ABIDecoder(revert.dropFirst(4))
            let returnInfo = try result.int(at: 0)
            return try result.bool(at: returnInfo + 64)
        }
    }

    @Test func counterfactualAddressIsStableAcrossChains() async throws {
        let owner = try P256PublicKey(raw: P256.Signing.PrivateKey().publicKey.rawRepresentation)
        let owners = [CoinbaseSmartWallet.ownerBytes(owner)]
        let sepolia = try await CoinbaseSmartWallet.accountAddress(owners: owners, client: client)
        let mainnet = try await CoinbaseSmartWallet.accountAddress(owners: owners, client: EthereumClient(url: Chain.base.rpcURL))
        #expect(sepolia == mainnet)
        #expect(try await client.isDeployed(sepolia) == false)
    }

    @Test func userOpHashMatchesEntryPoint() async throws {
        let owner = try P256PublicKey(raw: P256.Signing.PrivateKey().publicKey.rawRepresentation)
        let account = try await makeAccount(owners: [owner])
        var op = testOperation(for: account)
        op.maxFeePerGas = 1_000_000
        op.maxPriorityFeePerGas = 1000
        op.paymasterAndData = Data([1, 2, 3])
        let call = ABI.encodeCall(
            "getUserOpHash((address,uint256,bytes,bytes,uint256,uint256,uint256,uint256,uint256,bytes,bytes))",
            [op.abiTuple]
        )
        let onchain = try await client.call(to: CoinbaseSmartWallet.entryPoint, data: call)
        #expect(onchain == op.hash(chainID: chain.id))
    }

    @Test func webAuthnSignatureValidatesOnchain() async throws {
        let signer = try LocalWebAuthnSigner(privateKey: P256.Signing.PrivateKey())
        let account = try await makeAccount(owners: [signer.publicKey])
        let owners = [OwnerKey(credentialID: signer.credentialID, ownerIndex: 0, publicKey: signer.publicKey)]

        var op = testOperation(for: account)
        op.signature = try await account.signature(for: op.hash(chainID: chain.id), signer: signer, owners: owners)
        let sigFailed = try await simulateValidation(op)
        #expect(sigFailed == false, "the smart wallet rejected a valid WebAuthn signature")
    }

    @Test func secondOwnerCanSign() async throws {
        let primary = try LocalWebAuthnSigner(privateKey: P256.Signing.PrivateKey())
        let backup = try LocalWebAuthnSigner(privateKey: P256.Signing.PrivateKey())
        let account = try await makeAccount(owners: [primary.publicKey, backup.publicKey])
        let owners = [
            OwnerKey(credentialID: primary.credentialID, ownerIndex: 0, publicKey: primary.publicKey),
            OwnerKey(credentialID: backup.credentialID, ownerIndex: 1, publicKey: backup.publicKey),
        ]

        var op = testOperation(for: account)
        op.signature = try await account.signature(for: op.hash(chainID: chain.id), signer: backup, owners: owners)
        #expect(try await simulateValidation(op) == false)
    }

    @Test func wrongKeyIsRejectedOnchain() async throws {
        let owner = try LocalWebAuthnSigner(privateKey: P256.Signing.PrivateKey())
        let attacker = try LocalWebAuthnSigner(privateKey: P256.Signing.PrivateKey())
        let account = try await makeAccount(owners: [owner.publicKey])

        var op = testOperation(for: account)
        let hash = op.hash(chainID: chain.id)
        let assertion = try await attacker.assert(challenge: hash, allowedCredentialIDs: [])
        op.signature = CoinbaseSmartWallet.wrapSignature(
            ownerIndex: 0,
            signatureData: try CoinbaseSmartWallet.encodeWebAuthnAuth(assertion, challenge: hash)
        )
        #expect(try await simulateValidation(op) == true)
    }

    @Test func bundlerEstimatesGasWithDummySignature() async throws {
        let owner = try P256PublicKey(raw: P256.Signing.PrivateKey().publicKey.rawRepresentation)
        let account = try await makeAccount(owners: [owner])
        let price = try await account.gasPrice()
        let op = UserOperation(
            sender: account.address,
            nonce: 0,
            initCode: CoinbaseSmartWallet.initCode(owners: account.initialOwners),
            callData: CoinbaseSmartWallet.executeCalldata(.init(target: Address("0x000000000000000000000000000000000000dEaD")!)),
            maxFeePerGas: price.maxFeePerGas,
            maxPriorityFeePerGas: price.maxPriorityFeePerGas,
            signature: CoinbaseSmartWallet.dummySignature(ownerIndex: 0)
        )
        let estimate = try await account.bundler.estimateGas(op, stateOverride: SmartAccount.fundedOverride(for: account.address))
        // Deployment dominates verification gas for a first operation.
        #expect(estimate.verificationGasLimit > 200_000)
        #expect(estimate.callGasLimit > 0)
        #expect(estimate.preVerificationGas > 0)
    }

    @Test func prepareBuildsAFullOperationForAnUnfundedAccount() async throws {
        let signer = try LocalWebAuthnSigner(privateKey: P256.Signing.PrivateKey())
        let account = try await makeAccount(owners: [signer.publicKey])
        let prepared = try await account.prepare(
            calls: [.init(target: Address("0x000000000000000000000000000000000000dEaD")!, value: 1)],
            signingOwnerIndex: 0
        )
        #expect(prepared.deploysAccount)
        #expect(!prepared.isSponsored)
        #expect(prepared.requiredBalance == prepared.maxGasCost + 1)
        #expect(prepared.hash == prepared.userOperation.hash(chainID: chain.id))

        // Sign it for real and check the account accepts it, with the actual gas fields the bundler chose.
        let owners = [OwnerKey(credentialID: signer.credentialID, ownerIndex: 0, publicKey: signer.publicKey)]
        var op = try await account.sign(prepared, signer: signer, owners: owners)
        op.maxFeePerGas = 0
        op.maxPriorityFeePerGas = 0
        op.signature = try await account.signature(for: op.hash(chainID: chain.id), signer: signer, owners: owners)
        #expect(try await simulateValidation(op) == false)
    }

    @Test func revertingCallSurfacesReadableReason() async throws {
        let signer = try LocalWebAuthnSigner(privateKey: P256.Signing.PrivateKey())
        let account = try await makeAccount(owners: [signer.publicKey])
        let usdc = chain.knownTokens[0].address
        do {
            _ = try await account.prepare(
                calls: [.init(target: usdc, data: ERC20.transfer(to: Address("0x000000000000000000000000000000000000dEaD")!, amount: 1))],
                signingOwnerIndex: 0
            )
            Issue.record("expected the transfer to revert in simulation")
        } catch let error as RPCError {
            #expect(error.errorDescription?.contains("transfer amount exceeds balance") == true, "\(error.message)")
        }
    }

    @Test func blockscoutListsTokens() async throws {
        let provider = BlockscoutTokenProvider(baseURL: try #require(chain.blockscoutURL))
        // The WETH predeploy holds plenty of airdropped tokens.
        let balances = try await provider.balances(of: Address("0x4200000000000000000000000000000000000006")!)
        #expect(!balances.isEmpty)
        #expect(balances.allSatisfy { !$0.balance.isZero })
    }

    @Test func blockscoutEmptyForFreshAddress() async throws {
        let provider = BlockscoutTokenProvider(baseURL: try #require(chain.blockscoutURL))
        let fresh = Address(data: Data((0..<20).map { _ in UInt8.random(in: 0...255) }))!
        #expect(try await provider.balances(of: fresh).isEmpty)
    }
}
