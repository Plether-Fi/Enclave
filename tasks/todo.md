# Enclave V2 Implementation Progress

## Sprint 1: Phase 0 — Close V1 Gaps
- [x] 0.2 Dynamic gas prices: `getGasPrice()` + `getMaxPriorityFeePerGas()` in RPC.swift, used in send flow
- [x] 0.3 Fix deployment detection: `getCode()` in RPC.swift, EnclaveEngine uses `eth_getCode` instead of nonce

## Sprint 2: Phase 1 — Transaction Simulation & Preview
- [x] 1.1 CalldataDecoder.swift: decodes execute/executeBatch into DecodedAction enum
- [x] 1.2 TransactionPreviewView: shows decoded actions + estimated gas before signing

## Sprint 3: Phase 2 — Security Hardening
- [x] 2.1 On-chain spending limits: daily per-token limits in EnclaveWallet.sol with auto-reset
- [x] 2.2 EIP-1271 isValidSignature: P-256 verification via RIP-7212 precompile
- [x] 2.3 AppPermissions.swift: per-dApp permission model with session expiry, persisted to disk
- [x] 2.4 Expanded Foundry tests: 17 tests covering factory, EIP-1271, spending limits, reset

## Sprint 4: Phase 3 — Provider Bridge
- [x] 3.1-3.2 ProviderBridge.swift: EIP-1193-like request/response with RPC proxy
- [x] 3.3 WalledGardenWebView: injects `window.enclave` at document start, delegates to bridge
- [x] 3.4 kitchen_sink.html: connect, sign, send via provider API

## Sprint 5: Phase 4-5 — Batch & Paymaster
- [x] 4.1 executeBatch + buildExecuteCallData in UserOperation.swift
- [x] 5.1 Paymaster: `getPaymasterData()` in Bundler.swift, `paymasterURL` in Config.swift

## Sprint 6: Phase 6 — App Platform
- [x] 6.3 Network switching: dropdown in balance bar to switch Sepolia/One
- [ ] 6.1 App manifests (future: replace hardcoded app list)
- [ ] 6.2 IPFS loading (future: load dApp bundles from IPFS)

## Remaining Manual Steps
- [ ] 0.1 Deploy factory to Arbitrum Sepolia: `forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast`
- [ ] Update `Config.factoryAddress` with deployed address
- [ ] Session keys (Phase 4.2) — future
- [ ] Self-hosted paymaster contract (Phase 5.2) — future
