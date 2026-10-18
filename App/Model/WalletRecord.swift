import Foundation
import WalletClient

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

/// Uncompressed P-256 public key coordinates. Stored as in earlier versions, so existing wallet records still load.
struct P256PublicKey: Codable, Hashable, Sendable {
    let x: Data
    let y: Data

    /// 64 bytes `x || y` (CryptoKit `rawRepresentation`).
    init(raw: Data) {
        precondition(raw.count == 64, "P-256 raw public key must be 64 bytes")
        x = raw.prefix(32)
        y = raw.suffix(32)
    }

    init(_ key: PublicKey) throws {
        x = try Data(hex: key.x)
        y = try Data(hex: key.y)
    }

    /// The core's form.
    var core: PublicKey { PublicKey(x: x.hexPrefixed, y: y.hexPrefixed) }
}

/// A key that has been registered but not yet assigned an owner index.
struct NewKey: Sendable {
    let credentialID: Data
    let publicKey: P256PublicKey
    let kind: KeyKind
    let name: String
    /// The WebAuthn relying party ID the key was registered under.
    let relyingPartyID: String
    /// The owner chose to protect the key with its PIN, so every signature must be PIN-verified.
    var requirePIN = false
    /// The key itself refuses to sign without its PIN (`credProtect`), whatever any app asks for.
    var pinEnforcedByKey = false
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
    /// Recorded at registration. Nil in records from before it was stored; see `rpID`.
    let relyingPartyID: String?
    let requirePIN: Bool
    let pinEnforcedByKey: Bool

    init(_ key: NewKey, ownerIndex: Int, addedOnChainID: UInt64?) {
        credentialID = key.credentialID
        publicKey = key.publicKey
        name = key.name
        kind = key.kind
        self.ownerIndex = ownerIndex
        self.addedOnChainID = addedOnChainID
        relyingPartyID = key.relyingPartyID
        requirePIN = key.requirePIN
        pinEnforcedByKey = key.pinEnforcedByKey
    }

    /// Older records don't have the PIN or relying party fields.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credentialID = try container.decode(Data.self, forKey: .credentialID)
        publicKey = try container.decode(P256PublicKey.self, forKey: .publicKey)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(KeyKind.self, forKey: .kind)
        ownerIndex = try container.decode(Int.self, forKey: .ownerIndex)
        addedOnChainID = try container.decodeIfPresent(UInt64.self, forKey: .addedOnChainID)
        relyingPartyID = try container.decodeIfPresent(String.self, forKey: .relyingPartyID)
        requirePIN = try container.decodeIfPresent(Bool.self, forKey: .requirePIN) ?? false
        pinEnforcedByKey = try container.decodeIfPresent(Bool.self, forKey: .pinEnforcedByKey) ?? false
    }

    func isOwner(on chain: Chain) -> Bool {
        addedOnChainID == nil || addedOnChainID == chain.id
    }

    /// The relying party the key answers for: as registered, or for older records the app's configured domain
    /// (security keys) or the local test signer's (device keys).
    var rpID: String {
        relyingPartyID ?? (kind == .securityKey ? AppConfig.relyingPartyID : LocalWebAuthnSigner.relyingPartyID)
    }

    var ownerKey: OwnerKey {
        OwnerKey(
            credentialId: credentialID.hexPrefixed,
            ownerIndex: UInt32(ownerIndex),
            publicKey: publicKey.core,
            rpId: rpID,
            requireUserVerification: requirePIN
        )
    }
}

/// Everything needed to use the wallet. None of it is secret (security key private keys stay on the key),
/// but losing it means losing the credential IDs the keys need to sign, so it can be exported.
struct WalletRecord: Codable, Sendable {
    /// Checksummed. Derived by the core from `initialOwners`, which it re-checks before every signature.
    let address: String
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
