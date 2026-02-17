# Enclave Project

## Build & Run

- Build Swift app: `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project EnclaveWallet.xcodeproj -scheme EnclaveWallet -configuration Release build`
- Run: `pkill -f EnclaveWallet; sleep 1 && open ~/Library/Developer/Xcode/DerivedData/EnclaveWallet-hiifqhkbvxglyhdmfhfhojuoicgx/Build/Products/Release/EnclaveWallet.app`
- Always `pkill -f EnclaveWallet` before relaunching to avoid stale cached process
- Logging: Use `os.Logger` (not `print()`) so output is captured in system logs
- Read logs: `/usr/bin/log show --process EnclaveWallet --last 1m`

## Smart Contracts

- Foundry project in `contracts/`
- Build: `cd contracts && forge build`
- Test: `cd contracts && forge test -vv`
- Deploy factory: `cd contracts && forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast`
- EntryPoint v0.7: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`
- Factory address: update `Config.factoryAddress` after deploying
- After modifying `EnclaveWallet.sol`: run `forge inspect EnclaveWallet bytecode` and update `Config.walletCreationCode`

## Architecture

- `EnclaveEngine.swift` — Secure Enclave key management, signing, CREATE2 address computation
- `RPC.swift` — JSON-RPC client for Arbitrum (balance, nonce, eth_call, gasPrice, getCode)
- `Bundler.swift` — ERC-4337 bundler API (sendUserOperation, estimateGas, getReceipt, paymaster)
- `UserOperation.swift` — UserOp construction, hashing, callData encoding, batch support
- `Config.swift` — Network config, contract addresses, creation bytecode, paymaster URL
- `ContentView.swift` — Main UI: wallet selector, balance display, send/receive sheets, tx preview
- `CalldataDecoder.swift` — Decodes execute/executeBatch calldata into human-readable actions
- `AppPermissions.swift` — Per-dApp permission model with session expiry
- `ProviderBridge.swift` — EIP-1193-like request/response bridge for dApps in WebView
- `TransactionHistory.swift` — Tx history from Arbiscan API
- `WalledGardenWebView.swift` — WebView with injected provider script, delegates to ProviderBridge
- `contracts/src/EnclaveWallet.sol` — ERC-4337 wallet: P-256 sig verification, EIP-1271, daily spending limits
- `contracts/src/EnclaveWalletFactory.sol` — CREATE2 factory for wallet deployment
