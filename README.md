# P256 Wallet

A lightweight iOS wallet for Base where a **YubiKey signs every transaction**.

YubiKeys sign with P-256 (secp256r1), not Ethereum's secp256k1, so the wallet is a smart account whose
owner is the YubiKey's public key. Base verifies P-256 signatures cheaply with the RIP-7212 precompile.

## Platforms

| | Repo | Status |
|---|---|---|
| **iOS app** | this repo | MVP. YubiKeys need a paid Apple Developer team plus an associated domain (see [Enabling YubiKeys](#enabling-yubikeys)); until then it runs with a Secure Enclave test key. |
| **Browser extension** (Arc, Chrome, Brave, Edge) | [p256-wallet-extension](https://github.com/proofofjake/p256-wallet-extension) | Same features. Works with a YubiKey over USB-C today, no Apple account needed. |

Both run the same signing core, [p256-wallet-core](https://github.com/proofofjake/p256-wallet-core): one Rust
codebase, compiled to Swift here and to WebAssembly in the extension. It decides everything that gets signed, so it's
the one thing to audit (see its README for the review guide). Each app pins it as the `core` submodule at a release
and builds it from source.

A wallet created on one app isn't automatically available on the other, because security key credentials are bound
to a relying party ID. To share one wallet, give both the same domain as relying party ID before registering keys
(see the extension's README).

```
YubiKey ──(FIDO2 / WebAuthn, NFC or USB-C)──▶ iOS app ──(UserOperation)──▶ bundler ──▶ EntryPoint v0.6 ──▶ Coinbase Smart Wallet
  P-256 key never leaves the key              builds + signs ops                                        verifies WebAuthn sig via RIP-7212
```

## What's here

| Path | What |
|---|---|
| `core/` | The signing core (git submodule, [p256-wallet-core](https://github.com/proofofjake/p256-wallet-core)). Builds user operations, reviews them, checks security key responses and produces signatures. Exposed to Swift as the `P256WalletCore` package. |
| `WalletClient/` | Swift package around the core: JSON-RPC, bundler and paymaster clients, token balances, the prepare → sign → submit flow, and a local test signer. Decides nothing about what gets signed. |
| `App/` | SwiftUI app: onboarding (primary + backup key), balances, send/receive, arbitrary contract calls, ERC-1271 message signing, add-key, settings. |
| `UITests/` | Simulator smoke test against live Base Sepolia. |
| `web/.well-known/apple-app-site-association` | Template for the domain that YubiKey support needs. |

### Design choices

- **One signing core for both apps.** Everything that decides what gets signed is in
  [p256-wallet-core](https://github.com/proofofjake/p256-wallet-core): it builds operations, derives the wallet
  address locally, produces the review this app displays as-is, and only accepts a security key response that signed
  that operation with a registered owner key. The Swift code here does networking, storage and UI.
- **Account: [Coinbase Smart Wallet v1](https://github.com/coinbase/smart-wallet)** (audited, deployed at the same
  factory address `0x0BA5ED0c6AA8c49038F819E587E2633c4A9F428a` on Base and most L2s). It natively supports
  WebAuthn P-256 owners and multiple owners, so no custom contracts. The account address is the same on every chain.
- **No EOA.** The smart account *is* the wallet. Contract interactions are calls the account executes
  (`execute` / `executeBatch`); dapp message signatures are ERC-1271 (ERC-6492 before deployment).
- **Backup key at onboarding.** Both keys become initial owners, so either can sign from day one with no extra
  transaction. Lost only key = lost funds, so the app pushes hard for a second key.
- **Gas estimation with a balance override**, so the review screen can show the fee (and the shortfall) before
  the account is funded.
- **Tokens via Blockscout** (no API key, lists every ERC-20), falling back to a known-token list over RPC.
- **Device keys for development.** A Secure Enclave key (device) or software key (Simulator) produces
  WebAuthn-shaped signatures the contract can't distinguish from a YubiKey's, so every flow can be tested before
  security keys are set up.

## Run it

```sh
git submodule update --init    # the signing core
./core/scripts/build-swift.sh  # builds it for iOS, the Simulator and macOS (needs rustup; first build ~5 min)
brew install xcodegen          # already installed on this machine
xcodegen generate
open P256Wallet.xcodeproj
```

Rerun `./core/scripts/build-swift.sh` after moving the `core` submodule to a new release.

`Config/Local.xcconfig` (gitignored) holds your team ID and bundle ID; copy `Config/Local.example.xcconfig` on a new machine.

In the app, choose **Use a test key on this device**, then fund the address with Base Sepolia ETH
(e.g. the [CDP faucet](https://portal.cdp.coinbase.com/products/faucet)) and send something.

## Enabling YubiKeys

iOS only lets an app talk to FIDO2 security keys if it has the **Associated Domains** entitlement for the
WebAuthn relying party domain. That needs:

1. **A paid Apple Developer Program membership.** Free Personal Teams can't use Associated Domains (or Core NFC).
2. **A domain you control** serving `https://<domain>/.well-known/apple-app-site-association` over HTTPS
   with no redirects. Copy `web/.well-known/apple-app-site-association`, replacing `TEAMID` with your paid team
   ID. GitHub Pages works (add an empty `.nojekyll` so `.well-known` is served).
3. In `Config/Local.xcconfig`:
   ```
   DEVELOPMENT_TEAM = <paid team ID>
   RELYING_PARTY_ID = <domain>
   CODE_SIGN_ENTITLEMENTS = App/P256Wallet.entitlements
   ```
4. Regenerate (`xcodegen generate`), build to a device, and pick **Set up with a security key**.

Tips:
- Optionally choose **Require the key's PIN** when registering a key. Every signature from it then needs the PIN as
  well as a touch, and the signing core refuses any that weren't PIN-verified. Set the PIN first with the Yubico
  Authenticator app. iOS can't ask the key to enforce the PIN itself, so on iPhone the core enforces it.
- Both your keys work on iPhone 15 and later over USB-C; the NFC one also works by tapping the top of the phone.
- While iterating on the AASA file, use `webcredentials:<domain>?mode=developer` in the entitlements and enable
  *Settings → Developer → Associated Domains Development* on the phone to bypass Apple's CDN cache.

## Gas sponsorship

By default the app uses Pimlico's public bundler and the account pays its own gas in ETH (fractions of a cent on
Base). To sponsor gas, paste an ERC-7677 paymaster URL in Settings, for example a Coinbase Developer Platform
endpoint (`https://api.developer.coinbase.com/rpc/v1/base-sepolia/<key>`), which also works as the bundler.

## Testing

The signing core has its own unit and live tests (see its README), including proof against the deployed contracts
that it produces signatures the account accepts. This repo tests the app side:

```sh
cd WalletClient
swift test                            # offline: the local test signer's assertions pass the core's checks
WALLET_INTEGRATION=1 swift test       # + live Base Sepolia: account state, bundler estimate, prepare and sign, tokens
```

The live tests need no funds: the bundler estimates against a temporary balance override.

UI smoke test (Simulator, live network):

```sh
xcodebuild test -project P256Wallet.xcodeproj -scheme P256Wallet \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Known gaps / next steps

- **Restore from YubiKey.** Credentials are non-discoverable, so the wallet record (credential IDs + public keys)
  lives in the Keychain and can be exported from Settings. Restoring from the key alone needs discoverable
  credentials plus public-key recovery from signatures.
- **Owner sync across chains.** Keys added after setup exist only on the chain where they were added. Coinbase
  Smart Wallet's `executeWithoutChainIdValidation` can replay owner changes across chains.
- **WalletConnect** (Reown WalletKit) for dapp connections, plus EIP-712 typed-data signing.
- **More L2s.** Same factory and address; add `Chain` entries. Check each chain has the RIP-7212 precompile or
  raise `verificationGasBuffer` (the Solidity fallback costs ~300k+ gas).
- Removing keys, transaction history, fiat prices.
