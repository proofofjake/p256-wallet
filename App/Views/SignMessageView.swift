import SwiftUI
import WalletClient

/// Signs an EIP-191 message as the smart account. Dapps verify it through ERC-1271 (`isValidSignature`),
/// or ERC-6492 before the account is deployed.
struct SignMessageView: View {
    @Environment(AppModel.self) private var model
    @State private var message = ""
    @State private var result: MessageSignature?
    @State private var isSigning = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Message") {
                TextField("Hello from my YubiKey", text: $message, axis: .vertical)
                    .lineLimit(3...10)
            }
            if let result {
                Section("Signature") {
                    Text(result.signature)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(6)
                    CopyButton(text: result.signature, label: "Copy signature")
                    switch result.verifiedOnchain {
                    case true?:
                        Label("Verified by the account's isValidSignature", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    case false?:
                        ErrorText(message: "The account rejected this signature")
                    case nil:
                        Label("Account not deployed yet, so the signature is ERC-6492 wrapped. Verifiers that support ERC-6492 (viem, most SIWE libraries) can check it.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let error {
                Section { ErrorText(message: error) }
            }
        }
        .navigationTitle("Sign message")
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await sign() }
            } label: {
                if isSigning {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label(model.signer.usesSecurityKey ? "Sign with security key" : "Sign", systemImage: "signature")
                        .frame(maxWidth: .infinity)
                }
            }
            .primaryAction()
            .disabled(message.isEmpty || isSigning)
            .padding()
        }
    }

    private func sign() async {
        guard let account = model.account else { return }
        isSigning = true
        defer { isSigning = false }
        error = nil
        result = nil
        do {
            result = try await account.signPersonalMessage(message, signer: model.signer, owners: model.ownerKeys)
        } catch SecurityKeyError.cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
