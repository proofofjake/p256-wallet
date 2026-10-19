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
    @State private var newKeyRequiresPIN = false

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
                    Text("Leave blank to use Pimlico's free public bundler. To have gas sponsored, paste an ERC-7677 paymaster URL, such as a Coinbase Developer Platform endpoint (it works as both bundler and paymaster on Base).")
                }

                keysSection

                if let wallet = model.wallet {
                    Section {
                        LabeledContent("Address") { AddressText(address: wallet.address) }
                        Link(destination: model.chain.explorerAddressURL(wallet.address)) {
                            Label("View on explorer", systemImage: "arrow.up.right.square")
                        }
                        if let url = backupFile(for: wallet) {
                            ShareLink(item: url, subject: Text("P256 Wallet backup")) {
                                Label("Export backup file", systemImage: "square.and.arrow.up")
                            }
                        }
                        Button("Remove wallet from this phone", role: .destructive) { confirmRemove = true }
                    } header: {
                        Text("Wallet")
                    } footer: {
                        Text("Save the backup file somewhere safe, such as Files or iCloud Drive. To restore this wallet you'll need the file and one of its keys: a YubiKey on its own can't restore it. The file has no secrets, but it does reveal your wallet's address.")
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
            .confirmationDialog("Remove wallet from this phone?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    model.removeWallet()
                    dismiss()
                }
            } message: {
                Text("Your funds stay onchain, but this phone forgets the wallet. A YubiKey on its own can't bring it back: to restore it you'll need the backup file (Export backup file) and one of your keys. Test keys stored on this phone are deleted for good.")
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
                        Text("\(key.kind.label) · owner #\(key.ownerIndex)\(pinLabel(key))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if key.kind != .securityKey && !DeviceKeys.exists(key) {
                        Text("Private key not on this phone").font(.caption).foregroundStyle(.orange)
                    } else if !key.isOwner(on: model.chain) {
                        Text("Not on \(model.chain.name)").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if model.authenticator != nil {
                PINToggle(requirePIN: $newKeyRequiresPIN)
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

    /// The backup file to share: the wallet record as JSON, named so it's recognizable in Files.
    private func backupFile(for wallet: WalletRecord) -> URL? {
        guard let data = try? WalletStore.export(wallet) else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "p256-wallet-\(wallet.address.prefix(10)).json")
        #if DEBUG
        // UI tests restore from this copy, since driving the system file picker is unreliable.
        if ProcessInfo.processInfo.arguments.contains("-writeTestBackup") {
            try? data.write(to: URL.documentsDirectory.appending(path: "uitest-backup.json"))
        }
        #endif
        return (try? data.write(to: url)) != nil ? url : nil
    }

    private func pinLabel(_ key: WalletKey) -> String {
        guard key.requirePIN else { return "" }
        return key.pinEnforcedByKey ? " · PIN (enforced by the key)" : " · PIN required"
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
            let newKey = try await authenticator.register(
                displayName: name,
                excluding: wallet.keys.map(\.credentialID),
                requirePIN: newKeyRequiresPIN
            )
            let ownerIndex = try await account.nextOwnerIndex()
            addKeyRequest = TransactionRequest(
                title: "Add \(name)",
                calls: [try addOwnerCall(account: account.address, key: newKey.publicKey.core)],
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
