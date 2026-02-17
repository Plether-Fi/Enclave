# 🛡️ Enclave

**The Secure Web3 Operating System for macOS.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS%2014+-black.svg?logo=apple)]()
[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg?logo=swift)]()
[![Network: Arbitrum](https://img.shields.io/badge/Network-Arbitrum%20L2-28A0F0.svg?logo=arbitrum)]()
[![Standard: ERC-4337](https://img.shields.io/badge/Standard-ERC--4337-lightgrey.svg)]()

**Enclave** is a native macOS application that fundamentally redesigns how users interact with Web3. Rather than forcing standard Ethereum cryptography (`secp256k1`) into vulnerable Web2 browser extensions, Enclave leverages **Apple's physical Secure Enclave (`secp256r1`)** and **Account Abstraction (ERC-4337)** to turn your Mac into a literal hardware wallet.

Private keys are generated in silicon, physically cannot be extracted by malware, and are mathematically verified on-chain via modern Layer-2 precompiles (RIP-7212).

---

## 📖 The Philosophy

The current standard of injecting a global `window.ethereum` JavaScript object into a standard web browser is fundamentally broken. Users lose billions to front-end compromises, DNS hijacking, poisoned libraries, and malicious browser extensions.

Enclave is built strictly on two uncompromising principles:

### 1. Best-In-Class Security

* **True Hardware Isolation:** Keys never leave the hardware. Your private key is physically bound to your Mac's motherboard and biometric sensor. Transactions are signed strictly via **Touch ID**.
* **The Walled Garden:** Enclave abandons the browser extension model entirely. dApps run inside isolated, sandboxed native views (`WKWebView`) within the wallet application.
* **No JS Injection:** `window.ethereum` does not exist here. dApps communicate through `window.enclave` — an EIP-1193-like provider with per-app permissions and session expiry, injected at document start via `WKScriptMessageHandler`.
* **Immutable dApps:** dApps are explicitly versioned, loaded strictly via IPFS, and must be cryptographically signed by verified developers.
* **Transaction Previews:** Every transaction is decoded into human-readable actions and shown for approval *before* Touch ID appears. No blind signing.
* **On-Chain Spending Limits:** Per-token daily limits enforced at the smart contract level, auto-resetting every 24 hours.

### 2. Delightful User Experience

* **Native Speed:** Optimistic UI updates make Web3 feel like a centralized service. When Touch ID succeeds, balances update instantly while the Bundler handles blockchain settlement seamlessly in the background.
* **Gas Abstraction:** Users never need to hold native ETH to pay for network fees. Enclave uses ERC-4337 Paymasters to sponsor gas entirely or allow payments in USDC.
* **Atomic Batching:** Approve a token and execute a swap in a single Touch ID confirmation via `executeBatch`.
* **Human-Readable Previews:** Unified transaction previews ensure you know exactly what is happening *before* the biometric prompt appears (e.g., *"🟢 Receive 3,000 USDC, 🔴 Pay 1 ETH"*). No more blind signing hex strings.
* **Network Switching:** Switch between Arbitrum Sepolia and Arbitrum One from the balance bar.

---

## 🏗️ Architecture

Enclave bridges Apple's proprietary silicon to the Ethereum Virtual Machine (EVM) by orchestrating three isolated layers. Targeted at **Arbitrum L2**, which natively supports the **RIP-7212 precompile** at address `0x0100` for cheap P-256 signature verification.

### Swift Application

| File | Purpose |
|---|---|
| `EnclaveEngine.swift` | Secure Enclave key management, P-256 signing, CREATE2 address computation |
| `RPC.swift` | JSON-RPC client (balance, nonce, gasPrice, getCode, eth_call) |
| `Bundler.swift` | ERC-4337 bundler API (sendUserOperation, estimateGas, paymaster) |
| `UserOperation.swift` | UserOp construction, hashing, execute/executeBatch calldata |
| `CalldataDecoder.swift` | Decode execute calldata into human-readable `DecodedAction` enum |
| `ProviderBridge.swift` | EIP-1193-like `window.enclave` provider for dApp communication |
| `AppPermissions.swift` | Per-dApp permission model with session expiry |
| `ContentView.swift` | Main UI: wallet selector, balance display, send with tx preview |
| `WalledGardenWebView.swift` | WebView with injected provider script |
| `Config.swift` | Network config, contract addresses, creation bytecode |

### Smart Contracts (Foundry)

| File | Purpose |
|---|---|
| `EnclaveWallet.sol` | ERC-4337 account with P-256 verification, EIP-1271, daily spending limits |
| `EnclaveWalletFactory.sol` | CREATE2 deterministic deployment factory |

### Provider Bridge Methods

| Method | Touch ID? | Description |
|---|---|---|
| `eth_requestAccounts` / `eth_accounts` | No | Return connected wallet address |
| `eth_chainId` | No | Current chain ID |
| `personal_sign` | Yes | Sign an arbitrary message |
| `eth_signTypedData_v4` | Yes | Sign EIP-712 typed data |
| `eth_sendTransaction` | Yes | Build UserOp, preview, sign, submit |
| `eth_getBalance` / `eth_call` / `eth_blockNumber` / `eth_estimateGas` | No | Proxied to RPC |

### Feature Status

- [x] Secure Enclave key generation and Touch ID signing
- [x] CREATE2 counterfactual address computation
- [x] EVM high-S malleability fix
- [x] Multi-wallet support with Keychain persistence
- [x] ERC-4337 UserOp construction, gas estimation, bundler submission
- [x] Send/Receive UI with ETH and USDC
- [x] Dynamic gas prices (eth_gasPrice, eth_maxPriorityFeePerGas)
- [x] Deployment detection via eth_getCode
- [x] Transaction calldata decoder (transfer, approve, execute, executeBatch)
- [x] Transaction preview sheet with approve/reject before signing
- [x] EIP-1271 `isValidSignature` (P-256 via RIP-7212)
- [x] On-chain daily spending limits with auto-reset
- [x] EIP-1193-like provider bridge (`window.enclave`)
- [x] Per-dApp permissions with session expiry
- [x] executeBatch support for atomic multi-call
- [x] Paymaster integration (pm_sponsorUserOperation)
- [x] Network switching (Arbitrum Sepolia / One)
- [ ] Factory deployment to Arbitrum Sepolia
- [ ] Session keys for gasless dApp interactions
- [ ] IPFS dApp loading with content verification
- [ ] App manifest system

---

## 🛠️ Getting Started

We welcome Swift engineers, Solidity developers, and cryptographers.

### Prerequisites

* **macOS 14.0+** (Requires a physical Mac with Touch ID; Enclave cannot be fully simulated in a VM)
* **Xcode 15.0+**
* **Foundry** (for smart contract testing)

### Build & Run

```bash
git clone https://github.com/Plether-fi/enclave.git
cd enclave

# Build
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project EnclaveWallet.xcodeproj -scheme EnclaveWallet -configuration Release build

# Run
pkill -f EnclaveWallet; sleep 1 && open ~/Library/Developer/Xcode/DerivedData/EnclaveWallet-*/Build/Products/Release/EnclaveWallet.app
```

Or open `EnclaveWallet.xcodeproj` in Xcode and hit `Cmd + R`.

**CRITICAL:** Go to **Project Settings → Target → Signing & Capabilities**. You must select your Apple Developer Team and add the **Keychain Sharing** capability. If you do not do this, CryptoKit will instantly crash due to access control restrictions when attempting to reach the Secure Enclave.

### Smart Contract Tests

```bash
cd contracts
forge test -vv
```

17 tests covering factory deployment, EIP-1271 signature validation, and spending limit enforcement.

### Deploy Factory

```bash
cd contracts
PRIVATE_KEY=<funded-deployer-key> forge script script/Deploy.s.sol \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc --broadcast
```

After deployment, update `Config.factoryAddress` in `Config.swift` with the logged address, then run `forge inspect EnclaveWallet bytecode` and update `Config.walletCreationCode`.

### Testing the Kitchen Sink

The Kitchen Sink dApp exercises the provider bridge:

1. **Connect Wallet** — returns your counterfactual address
2. **Get Chain ID / Balance / Block Number** — read-only RPC calls proxied through Swift
3. **Sign Message** — triggers Touch ID, returns P-256 signature
4. **Send 0.0001 ETH** — builds a UserOp, shows transaction preview, signs, submits to bundler

---

## ⚠️ Cryptographic Traps (Must Read for Contributors)

If you are contributing to the cryptographic engine or the Smart Contract, please be aware of the following:

### 1. The "High-S" Malleability Rule (EIP-2)

Apple's Secure Enclave does not care about Ethereum's strict malleability rules. It randomly generates signatures with an `s` value in the upper half of the curve (~50% of the time). The EVM strictly rejects high `s` values to prevent transaction replay attacks.

**The Rule:** In `EnclaveEngine.swift`, we capture the raw signature, check if `s > N/2` using the `BigInt` library, and mathematically flip it (`s = N - s`). Do not alter this logic, or ~50% of Arbitrum transactions will mysteriously fail.

### 2. Counterfactual Deployment

The Mac app does not send a standard transaction to "create" the wallet. It mathematically calculates what the address *will be* using the `CREATE2` opcode. The wallet is natively deployed by the Arbitrum Bundler during the user's very first outbound transaction via the `initCode` field.

### 3. On-Chain Spending Limits

`EnclaveWallet.sol` enforces per-token daily spending limits at the contract level. Limits are set by the wallet itself (via `execute` calling `setDailyLimit`), checked on every `execute` call for ETH value and ERC-20 transfer/approve amounts, and auto-reset every 24 hours based on block timestamp.

---

## 🤝 How to Contribute

Enclave is an open-source project. The following areas have been implemented or are actively looking for help:

* ~~**Transaction Simulation Engine:** Calldata decoder and transaction preview sheet now show human-readable actions before Touch ID appears.~~ ✅
* ~~**Bundler Networking:** Full ERC-4337 UserOp construction, gas estimation, and bundler submission.~~ ✅
* ~~**EIP-1271 Implementation:** `isValidSignature` with P-256 verification via RIP-7212 precompile.~~ ✅
* **IPFS dApp Resolver:** Building the native Swift architecture to securely fetch, verify developer signatures, and load versioned HTML/JS payloads from IPFS directly into the Walled Garden.
* **Session Keys:** Temporary secp256k1 session keys with per-contract, per-spend, and time-bound constraints for gasless dApp interactions.
* **App Manifest System:** Replace the hardcoded app list with manifest-driven dApp catalog.

---

## 📄 License

This project is released under the [MIT License](https://opensource.org/licenses/MIT).
