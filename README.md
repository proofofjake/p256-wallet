# P256 Wallet

A lightweight iOS wallet for Base where a **YubiKey signs every transaction**.

YubiKeys sign with P-256 (secp256r1), not Ethereum's secp256k1, so the wallet is a smart account whose
owner is the YubiKey's public key. Base verifies P-256 signatures cheaply with the RIP-7212 precompile.

```
YubiKey ──(FIDO2 / WebAuthn, NFC or USB-C)──▶ iOS app ──(UserOperation)──▶ bundler ──▶ EntryPoint v0.6 ──▶ Coinbase Smart Wallet
  P-256 key never leaves the key              builds + signs ops                                        verifies WebAuthn sig via RIP-7212
```

## What's here

| Path | What |
|---|---|
| `WalletCore/` | Swift package, no dependencies. Keccak, ABI, UInt256, CBOR/COSE, WebAuthn → smart-wallet signature encoding, UserOperation v0.6, bundler/paymaster clients, token balances. Fully tested on macOS. |
| `App/` | SwiftUI app: onboarding (primary + backup key), balances, send/receive, arbitrary contract calls, ERC-1271 message signing, add-key, settings. |
| `UITests/` | Simulator smoke test against live Base Sepolia. |
| `web/.well-known/apple-app-site-association` | Template for the domain that YubiKey support needs. |

### Design choices

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
brew install xcodegen          # already installed on this machine
xcodegen generate
open P256Wallet.xcodeproj
```

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
- Set a FIDO2 PIN on each YubiKey (Yubico Authenticator app). The app asks for user verification when a PIN is set.
- Both your keys work on iPhone 15 and later over USB-C; the NFC one also works by tapping the top of the phone.
- While iterating on the AASA file, use `webcredentials:<domain>?mode=developer` in the entitlements and enable
  *Settings → Developer → Associated Domains Development* on the phone to bypass Apple's CDN cache.

## Gas sponsorship

By default the app uses Pimlico's public bundler and the account pays its own gas in ETH (fractions of a cent on
Base). To sponsor gas, paste an ERC-7677 paymaster URL in Settings, for example a Coinbase Developer Platform
endpoint (`https://api.developer.coinbase.com/rpc/v1/base-sepolia/<key>`), which also works as the bundler.

## Testing

```sh
cd WalletCore
swift test                              # unit tests (offline)
WALLETCORE_INTEGRATION=1 swift test     # + live Base Sepolia tests
```

Unit test expectations come from Foundry's `cast` (ABI encodings, selectors, Keccak vectors) and from the
deployed contracts. The integration tests need no funds: they run `EntryPoint.simulateValidation` with zero gas
fees and check that the real Coinbase Smart Wallet accepts our WebAuthn signatures (and rejects a wrong key),
that our UserOperation hash matches the EntryPoint's, and that a fully prepared operation validates within the
gas the bundler estimated.

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
