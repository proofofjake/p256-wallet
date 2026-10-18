import SwiftUI
import WalletClient

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    private enum Step {
        case welcome
        case primary
        case backup(primary: NewKey)
        case creating
    }

    @State private var step: Step = .welcome
    @State private var isWorking = false
    @State private var error: String?
    /// Off by default: a touch is enough unless the owner chooses a PIN.
    @State private var requirePIN = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            content
            if let error { ErrorText(message: error) }
            Spacer()
        }
        .padding(24)
        .animation(.default, value: isWorking)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .primary: registerPrimary
        case .backup(let primary): registerBackup(primary)
        case .creating:
            ProgressView("Creating wallet…")
        }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("P256 Wallet").font(.largeTitle.bold())
            Text("A smart wallet on Base controlled by your YubiKey. The key signs every transaction, and nothing secret is stored on this phone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                Button("Set up with a security key") { step = .primary }
                    .primaryAction()
                    .disabled(model.authenticator == nil)
                if model.authenticator == nil {
                    Text(AppConfig.isSimulator
                         ? "Security keys don't work in the Simulator."
                         : "Security keys need a relying party domain and the Associated Domains entitlement. See README → Enabling YubiKeys.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Use a test key on this device") { Task { await createWithDeviceKey() } }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isWorking)
            }
            .padding(.top, 12)
        }
    }

    private var registerPrimary: some View {
        VStack(spacing: 20) {
            Image(systemName: "wave.3.right.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Register your primary key").font(.title2.bold())
            Text("Plug in your YubiKey or hold it near the top of the phone when prompted.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            PINToggle(requirePIN: $requirePIN)
            Button("Register primary key") { Task { await register(name: "Primary key", excluding: []) } }
                .primaryAction()
                .disabled(isWorking)
            Button("Back") { step = .welcome }
        }
    }

    private func registerBackup(_ primary: NewKey) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "key.2.on.ring.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Add a backup key").font(.title2.bold())
            Text("If your only key is lost or broken, the funds in this wallet are gone for good. Register a second YubiKey now and keep it somewhere safe.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            PINToggle(requirePIN: $requirePIN)
            Button("Register backup key") {
                Task { await register(name: "Backup key", excluding: [primary.credentialID], primary: primary) }
            }
            .primaryAction()
            .disabled(isWorking)
            Button("Skip for now", role: .destructive) { Task { await create([primary]) } }
                .disabled(isWorking)
        }
    }

    private func register(name: String, excluding: [Data], primary: NewKey? = nil) async {
        guard let authenticator = model.authenticator else { return }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            let key = try await authenticator.register(displayName: name, excluding: excluding, requirePIN: requirePIN)
            if let primary {
                await create([primary, key])
            } else {
                step = .backup(primary: key)
            }
        } catch SecurityKeyError.cancelled {
            // User dismissed the sheet; stay on this step.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createWithDeviceKey() async {
        isWorking = true
        defer { isWorking = false }
        do {
            await create([try DeviceKeys.create(name: "Test key")])
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func create(_ keys: [NewKey]) async {
        let previous = step
        step = .creating
        error = nil
        do {
            try await model.createWallet(with: keys)
        } catch {
            self.error = error.localizedDescription
            step = previous
        }
    }
}

/// The per-key PIN choice, off by default.
struct PINToggle: View {
    @Binding var requirePIN: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Require the key's PIN", isOn: $requirePIN)
            Text("Every signature will need the key's FIDO2 PIN as well as a touch, so a lost key can't be used on its own. Set a PIN first with Yubico Authenticator.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
