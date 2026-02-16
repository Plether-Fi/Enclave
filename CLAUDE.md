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

## Architecture

- `EnclaveEngine.swift` — Secure Enclave key management, signing, CREATE2 address computation
- `RPC.swift` — JSON-RPC client for Arbitrum (balance, nonce, eth_call)
- `Bundler.swift` — ERC-4337 bundler API (sendUserOperation, estimateGas, getReceipt)
- `UserOperation.swift` — UserOp construction, hashing, callData encoding
- `Config.swift` — Network config, contract addresses, creation bytecode
- `ContentView.swift` — Main UI: wallet selector, balance display, send/receive sheets
- `TransactionHistory.swift` — Tx history from Arbiscan API
- `WalledGardenWebView.swift` — WebView showing activity feed
- `contracts/src/EnclaveWallet.sol` — ERC-4337 wallet with P-256 (RIP-7212) signature verification
- `contracts/src/EnclaveWalletFactory.sol` — CREATE2 factory for wallet deployment
