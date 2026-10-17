import SwiftUI
import WalletClient

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var bundlerURL = ""
    @State private var paymasterURL = ""
    @State private var addKeyRequest: TransactionRequest?
    @State private var addKeyError: String?
    @State private var isRegistering = false
    @State private var confirmRemove = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Network") {
                    Picker("Network", selection: $model.chain) {
                        ForEach(Chain.all) { Text($0.name).tag($0) }
                    }
                }

                Section {
                    TextField(model.chain.defaultBundlerUrl, text: $bundlerURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Paymaster URL (optional)", text: $paymasterURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Save endpoints") {
                        model.setEndpoints(Endpoints(bundlerURL: bundlerURL, paymasterURL: paymasterURL), for: model.chain)
                    }
                    .disabled(Endpoints(bundlerURL: bundlerURL, paymasterURL: paymasterURL) == model.endpoints(for: model.chain))
                } header: {
                    Text("Bundler & paymaster")
                } footer: {
                    Text("Defaults to Pimlico's public bundler. For gas sponsorship, paste an ERC-7677 paymaster URL, e.g. a Coinbase Developer Platform endpoint, which serves as both bundler and paymaster on Base.")
                }

                keysSection

                if let wallet = model.wallet {
                    Section("Wallet") {
                        LabeledContent("Address") { AddressText(address: wallet.address) }
                        Link(destination: model.chain.explorerAddressURL(wallet.address)) {
                            Label("View on explorer", systemImage: "arrow.up.right.square")
                        }
                        if let export = try? WalletStore.export(wallet), let json = String(data: export, encoding: .utf8) {
                            ShareLink(item: json, subject: Text("P256 Wallet backup")) {
                                Label("Export wallet details", systemImage: "square.and.arrow.up")
                            }
                        }
                        Button("Remove wallet from this device", role: .destructive) { confirmRemove = true }
                    }
                }

                Section("About") {
                    LabeledContent("Relying party", value: AppConfig.relyingPartyID.isEmpty ? "Not configured" : AppConfig.relyingPartyID)
                    LabeledContent("Security keys", value: model.authenticator == nil ? "Unavailable" : "Available")
                    LabeledContent("Account", value: "Coinbase Smart Wallet v1")
                    LabeledContent("EntryPoint", value: "v0.6")
                    LabeledContent("Signing core", value: coreVersion())
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: loadEndpoints)
            .onChange(of: model.chain) { loadEndpoints() }
            .sheet(item: $addKeyRequest) { TransactionSheet(request: $0) }
            .confirmationDialog("Remove wallet?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    model.removeWallet()
                    dismiss()
                }
            } message: {
                Text("Funds stay in the account onchain, but this device forgets the key credential IDs needed to sign. Export the wallet details first if you want to restore it later.")
            }
        }
    }

    private var keysSection: some View {
        Section {
            ForEach(model.wallet?.keys ?? []) { key in
                HStack {
                    Image(systemName: key.kind.symbol).foregroundStyle(.tint).frame(width: 28)
                    VStack(alignment: .leading) {
                        Text(key.name)
                        Text("\(key.kind.label) · owner #\(key.ownerIndex)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !key.isOwner(on: model.chain) {
                        Text("Not on \(model.chain.name)").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if model.authenticator != nil {
                Button {
                    Task { await addSecurityKey() }
                } label: {
                    if isRegistering {
                        ProgressView()
                    } else {
                        Label("Add a security key", systemImage: "plus")
                    }
                }
                .disabled(isRegistering)
            }
            if let addKeyError { ErrorText(message: addKeyError) }
        } header: {
            Text("Keys")
        } footer: {
            Text("Any one of these keys can sign. Keys added after setup are owners only on the network where you added them.")
        }
    }

    private func loadEndpoints() {
        let endpoints = model.endpoints(for: model.chain)
        bundlerURL = endpoints.bundlerURL
        paymasterURL = endpoints.paymasterURL
    }

    /// Registers a new key, then sends `addOwnerPublicKey` signed by an existing key.
    private func addSecurityKey() async {
        guard let authenticator = model.authenticator, let account = model.account, let wallet = model.wallet else { return }
        isRegistering = true
        defer { isRegistering = false }
        addKeyError = nil
        do {
            let name = "Key \(wallet.keys.count + 1)"
            let registration = try await authenticator.register(displayName: name, excluding: wallet.keys.map(\.credentialID))
            let ownerIndex = try await account.nextOwnerIndex()
            let newKey = NewKey(credentialID: registration.credentialID, publicKey: registration.publicKey, kind: .securityKey, name: name)
            addKeyRequest = TransactionRequest(
                title: "Add \(name)",
                calls: [try addOwnerCall(account: account.address, key: registration.publicKey.core)],
                onConfirmed: { _ in
                    do {
                        try model.recordAddedKey(newKey, ownerIndex: Int(ownerIndex))
                    } catch {
                        addKeyError = error.localizedDescription
                    }
                }
            )
        } catch SecurityKeyError.cancelled {
        } catch {
            addKeyError = error.localizedDescription
        }
    }
}
