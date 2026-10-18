import AuthenticationServices
import UIKit
import WalletClient

enum SecurityKeyError: LocalizedError {
    case busy
    case cancelled
    case unexpectedCredential
    case missingAttestation
    case unavailable
    case noKeys

    var errorDescription: String? {
        switch self {
        case .busy: "A security key request is already in progress"
        case .cancelled: "Cancelled"
        case .unexpectedCredential: "The security key returned an unexpected credential type"
        case .missingAttestation: "The security key didn't return its public key"
        case .unavailable: "Security keys aren't configured for this build. See README → Enabling YubiKeys."
        case .noKeys: "This wallet has no keys that can sign on this network"
        }
    }
}

/// Talks to FIDO2 security keys (YubiKeys over NFC, USB-C or Lightning) through iOS's built-in WebAuthn support.
///
/// Requires the Associated Domains entitlement with `webcredentials:<relyingPartyID>`, and that domain must
/// serve an `apple-app-site-association` file listing this app. Free Personal Teams can't use that entitlement.
@MainActor
final class SecurityKeyAuthenticator: NSObject {
    let relyingPartyID: String

    private enum Outcome: Sendable {
        case registration(credentialID: Data, attestationObject: Data?)
        case assertion(credentialID: Data, authenticatorData: Data, clientDataJSON: Data, signature: Data)
    }

    private var continuation: CheckedContinuation<Outcome, Error>?
    private var controller: ASAuthorizationController?

    init(relyingPartyID: String) {
        self.relyingPartyID = relyingPartyID
    }

    /// Creates a new P-256 credential on the key and has the core check it: the right relying party, a hardware key
    /// (not a synced passkey), and a verified PIN when `requirePIN` is set.
    func register(displayName: String, excluding existingCredentialIDs: [Data], requirePIN: Bool) async throws -> NewKey {
        let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyID)
        let request = provider.createCredentialRegistrationRequest(
            challenge: Self.randomBytes(32),
            displayName: displayName,
            name: "P256 Wallet",
            userID: Self.randomBytes(16)
        )
        request.credentialParameters = [ASAuthorizationPublicKeyCredentialParameters(algorithm: .ES256)]
        // Non-discoverable: doesn't use one of the key's limited resident slots or force PIN setup.
        // The credential ID is stored in the wallet record instead.
        request.residentKeyPreference = .discouraged
        // With a PIN chosen, the key must verify it now and on every signature. iOS has no credProtect option, so
        // here it's enforced by the core rather than by the key itself.
        request.userVerificationPreference = requirePIN ? .required : .preferred
        request.attestationPreference = .none
        // Stops the same physical key being registered twice (e.g. as its own backup).
        request.excludedCredentials = existingCredentialIDs.map(Self.descriptor)

        guard case .registration(let credentialID, let attestationObject) = try await perform(request) else {
            throw SecurityKeyError.unexpectedCredential
        }
        guard let attestationObject else { throw SecurityKeyError.missingAttestation }
        let registration = try verifyRegistration(
            attestationObject: attestationObject.hexPrefixed,
            credentialId: credentialID.hexPrefixed,
            rpId: relyingPartyID,
            requireUserVerification: requirePIN
        )
        return NewKey(
            credentialID: credentialID,
            publicKey: try P256PublicKey(registration.publicKey),
            kind: .securityKey,
            name: displayName,
            relyingPartyID: relyingPartyID,
            requirePIN: requirePIN,
            pinEnforcedByKey: registration.pinEnforcedByKey
        )
    }

    /// Asks the user to present one of the given keys and sign `challenge`. The response goes to the core as-is.
    func assert(challenge: Data, allowedCredentialIDs: [Data], requireUserVerification: Bool) async throws -> Assertion {
        let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyID)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.allowedCredentials = allowedCredentialIDs.map(Self.descriptor)
        // Prompts for the key's FIDO2 PIN: always for keys registered with one, otherwise if a PIN is set.
        request.userVerificationPreference = requireUserVerification ? .required : .preferred

        guard case .assertion(let credentialID, let authenticatorData, let clientDataJSON, let signature) = try await perform(request) else {
            throw SecurityKeyError.unexpectedCredential
        }
        return Assertion(
            credentialId: credentialID.hexPrefixed,
            authenticatorData: authenticatorData.hexPrefixed,
            clientDataJson: clientDataJSON.hexPrefixed,
            signature: signature.hexPrefixed
        )
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> Outcome {
        guard continuation == nil else { throw SecurityKeyError.busy }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<Outcome, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        controller = nil
    }

    private static func descriptor(_ credentialID: Data) -> ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor {
        ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
            credentialID: credentialID,
            transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported
        )
    }

    private static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }
}

extension SecurityKeyAuthenticator: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        switch authorization.credential {
        case let registration as ASAuthorizationSecurityKeyPublicKeyCredentialRegistration:
            finish(.success(.registration(credentialID: registration.credentialID, attestationObject: registration.rawAttestationObject)))
        case let assertion as ASAuthorizationSecurityKeyPublicKeyCredentialAssertion:
            finish(.success(.assertion(
                credentialID: assertion.credentialID,
                authenticatorData: assertion.rawAuthenticatorData,
                clientDataJSON: assertion.rawClientDataJSON,
                signature: assertion.signature
            )))
        default:
            finish(.failure(SecurityKeyError.unexpectedCredential))
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            finish(.failure(SecurityKeyError.cancelled))
        } else {
            finish(.failure(error))
        }
    }
}

extension SecurityKeyAuthenticator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

/// Routes signing to the right key type: security keys through the system sheet, device keys locally.
struct WalletSigner: WebAuthnSigner {
    let keys: [WalletKey]
    let authenticator: SecurityKeyAuthenticator?

    func assert(challenge: Data, allowedCredentialIDs: [Data], requireUserVerification: Bool) async throws -> Assertion {
        let allowed = keys.filter { allowedCredentialIDs.contains($0.credentialID) }
        let securityKeys = allowed.filter { $0.kind == .securityKey }
        if !securityKeys.isEmpty {
            guard let authenticator else { throw SecurityKeyError.unavailable }
            return try await authenticator.assert(
                challenge: challenge,
                allowedCredentialIDs: securityKeys.map(\.credentialID),
                requireUserVerification: securityKeys.contains { $0.requirePIN }
            )
        }
        guard let deviceKey = allowed.first else { throw SecurityKeyError.noKeys }
        return try await DeviceKeys.signer(for: deviceKey).assert(
            challenge: challenge,
            allowedCredentialIDs: [deviceKey.credentialID],
            requireUserVerification: requireUserVerification
        )
    }

    /// Whether confirming will prompt for a security key.
    var usesSecurityKey: Bool { keys.contains { $0.kind == .securityKey } }
}
