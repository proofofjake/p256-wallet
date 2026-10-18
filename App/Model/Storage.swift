import CryptoKit
import Foundation
import Security
import WalletClient

enum KeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status): "Keychain error \(status)"
        }
    }
}

enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "p256wallet"

    static func set(_ data: Data, for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func get(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Persists the wallet record in the Keychain, which (unlike UserDefaults) survives reinstalling the app.
enum WalletStore {
    private static let account = "wallet.v1"

    static func load() -> WalletRecord? {
        guard let data = Keychain.get(account) else { return nil }
        return try? JSONDecoder().decode(WalletRecord.self, from: data)
    }

    static func save(_ record: WalletRecord) throws {
        try Keychain.set(try JSONEncoder().encode(record), for: account)
    }

    static func delete() {
        Keychain.delete(account)
    }

    /// Public wallet details for backup: address, owner public keys and credential IDs. No secrets.
    static func export(_ record: WalletRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(record)
    }
}

enum DeviceKeyError: LocalizedError {
    case missing

    var errorDescription: String? {
        switch self {
        case .missing: "This device key's private key is missing from the Keychain"
        }
    }
}

/// Local P-256 keys used as stand-ins for a security key during development.
enum DeviceKeys {
    private static func account(_ credentialID: Data) -> String { "devicekey." + credentialID.hex }

    /// Creates a Secure Enclave key when available (real devices), otherwise a software key (Simulator).
    static func create(name: String) throws -> NewKey {
        let kind: KeyKind
        let blob: Data
        let publicKey: P256PublicKey
        if SecureEnclave.isAvailable {
            let key = try SecureEnclave.P256.Signing.PrivateKey()
            kind = .secureEnclave
            blob = key.dataRepresentation
            publicKey = P256PublicKey(raw: key.publicKey.rawRepresentation)
        } else {
            let key = P256.Signing.PrivateKey()
            kind = .software
            blob = key.rawRepresentation
            publicKey = P256PublicKey(raw: key.publicKey.rawRepresentation)
        }
        let credentialID = Data(SHA256.hash(data: publicKey.x + publicKey.y))
        try Keychain.set(blob, for: account(credentialID))
        return NewKey(
            credentialID: credentialID,
            publicKey: publicKey,
            kind: kind,
            name: name,
            relyingPartyID: LocalWebAuthnSigner.relyingPartyID
        )
    }

    static func signer(for key: WalletKey) throws -> LocalWebAuthnSigner {
        guard let blob = Keychain.get(account(key.credentialID)) else { throw DeviceKeyError.missing }
        let kind = key.kind
        // Capture the serialized key (Sendable) and rebuild it per signature.
        return LocalWebAuthnSigner(credentialID: key.credentialID) { message in
            if kind == .secureEnclave {
                return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob).signature(for: message).derRepresentation
            }
            return try P256.Signing.PrivateKey(rawRepresentation: blob).signature(for: message).derRepresentation
        }
    }

    static func delete(_ key: WalletKey) {
        Keychain.delete(account(key.credentialID))
    }
}
