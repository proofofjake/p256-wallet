import Foundation
import WalletCore

enum KeyKind: String, Codable, Sendable {
    /// A FIDO2 security key such as a YubiKey. The private key never leaves the hardware.
    case securityKey
    /// A P-256 key in this phone's Secure Enclave. Development stand-in for a security key.
    case secureEnclave
    /// A software P-256 key in the Keychain. Simulator only.
    case software

    var label: String {
        switch self {
        case .securityKey: "Security key"
        case .secureEnclave: "Device key (Secure Enclave)"
        case .software: "Test key (software)"
        }
    }

    var symbol: String {
        switch self {
        case .securityKey: "key.horizontal.fill"
        case .secureEnclave: "iphone"
        case .software: "hammer"
        }
    }
}

/// A key that has been registered but not yet assigned an owner index.
struct NewKey: Sendable {
    let credentialID: Data
    let publicKey: P256PublicKey
    let kind: KeyKind
    let name: String
}

struct WalletKey: Codable, Hashable, Identifiable, Sendable {
    var id: Data { credentialID }
    let credentialID: Data
    let publicKey: P256PublicKey
    var name: String
    let kind: KeyKind
    /// Position in the smart wallet's owner list, which signatures must reference.
    let ownerIndex: Int
    /// Owners the account was created with exist on every chain. Owners added later only exist on the chain
    /// where the `addOwnerPublicKey` transaction ran.
    let addedOnChainID: UInt64?

    init(_ key: NewKey, ownerIndex: Int, addedOnChainID: UInt64?) {
        credentialID = key.credentialID
        publicKey = key.publicKey
        name = key.name
        kind = key.kind
        self.ownerIndex = ownerIndex
        self.addedOnChainID = addedOnChainID
    }

    func isOwner(on chain: Chain) -> Bool {
        addedOnChainID == nil || addedOnChainID == chain.id
    }

    var ownerKey: OwnerKey {
        OwnerKey(credentialID: credentialID, ownerIndex: ownerIndex, publicKey: publicKey)
    }
}

/// Everything needed to use the wallet. None of it is secret (security key private keys stay on the key),
/// but losing it means losing the credential IDs the keys need to sign, so it can be exported.
struct WalletRecord: Codable, Sendable {
    let address: Address
    /// Owner bytes passed to the factory at creation. They fix the address and the deployment `initCode`.
    let initialOwners: [Data]
    var keys: [WalletKey]
    let createdAt: Date
}

struct Endpoints: Codable, Hashable, Sendable {
    var bundlerURL = ""
    var paymasterURL = ""

    var bundler: URL? { Self.url(bundlerURL) }
    var paymaster: URL? { Self.url(paymasterURL) }

    private static func url(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" else { return nil }
        return url
    }
}
