# Enclave Project

## Build & Run

- Build: `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project EnclaveWallet.xcodeproj -scheme EnclaveWallet -configuration Release build`
- Run: `pkill -f EnclaveWallet; sleep 1 && open <path-to-app>`
- Always `pkill -f EnclaveWallet` before relaunching to avoid stale cached process
- Logging: Use `os.Logger` (not `print()`) so output is captured in system logs
- Read logs: `/usr/bin/log show --process EnclaveWallet --last 1m`
