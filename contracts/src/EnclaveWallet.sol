// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@account-abstraction/contracts/core/BaseAccount.sol";
import "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";

contract EnclaveWallet is BaseAccount {
    IEntryPoint private immutable _entryPoint;
    uint256 public immutable pubKeyX;
    uint256 public immutable pubKeyY;

    address constant P256_PRECOMPILE = 0x0000000000000000000000000000000000000100;
    address constant P256_VERIFIER = 0xc2b78104907F722DABAc4C69f826a522B2754De4;

    // EIP-1271
    bytes4 private constant EIP1271_MAGIC = 0x1626ba7e;

    mapping(address => bool) public sessionKeys;

    // Spending limits: token => daily limit (0 = unlimited)
    mapping(address => uint256) public dailyLimit;
    // Spending tracking: token => day => spent
    mapping(address => mapping(uint256 => uint256)) public dailySpent;

    // address(0) represents native ETH for spending limit purposes
    address private constant ETH_TOKEN = address(0);

    constructor(IEntryPoint entryPointAddress, uint256 _x, uint256 _y) {
        _entryPoint = entryPointAddress;
        pubKeyX = _x;
        pubKeyY = _y;
    }

    function entryPoint() public view virtual override returns (IEntryPoint) {
        return _entryPoint;
    }

    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal view virtual override returns (uint256 validationData)
    {
        require(userOp.signature.length == 64, "Invalid signature length");
        (uint256 r, uint256 s) = abi.decode(userOp.signature, (uint256, uint256));

        bool isValid = _verifyP256(userOpHash, r, s);
        return isValid ? 0 : 1;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature)
        external view returns (bytes4)
    {
        if (signature.length == 65) {
            bytes32 r = bytes32(signature[:32]);
            bytes32 s = bytes32(signature[32:64]);
            uint8 v = uint8(signature[64]);
            address recovered = ecrecover(hash, v, r, s);
            if (recovered != address(0) && sessionKeys[recovered]) {
                return EIP1271_MAGIC;
            }
            return 0xffffffff;
        }

        require(signature.length == 64, "Invalid signature length");
        (uint256 r256, uint256 s256) = abi.decode(signature, (uint256, uint256));
        if (_verifyP256(hash, r256, s256)) {
            return EIP1271_MAGIC;
        }
        return 0xffffffff;
    }

    function addSessionKey(address key) external {
        require(msg.sender == address(this), "Only self");
        sessionKeys[key] = true;
    }

    function removeSessionKey(address key) external {
        require(msg.sender == address(this), "Only self");
        sessionKeys[key] = false;
    }

    function setDailyLimit(address token, uint256 amount) external {
        require(msg.sender == address(this), "Only self");
        dailyLimit[token] = amount;
    }

    function _currentDay() private view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function _checkAndRecordSpend(address token, uint256 amount) internal {
        uint256 limit = dailyLimit[token];
        if (limit == 0) return;

        uint256 day = _currentDay();
        uint256 spent = dailySpent[token][day] + amount;
        require(spent <= limit, "Daily limit exceeded");
        dailySpent[token][day] = spent;
    }

    // Override execute to enforce spending limits
    function execute(address dest, uint256 value, bytes calldata func_) external override {
        _requireFromEntryPoint();

        if (value > 0) {
            _checkAndRecordSpend(ETH_TOKEN, value);
        }

        if (func_.length >= 4) {
            bytes4 selector = bytes4(func_[:4]);
            // ERC-20 transfer(address,uint256)
            if (selector == 0xa9059cbb && func_.length >= 68) {
                uint256 amount = abi.decode(func_[36:68], (uint256));
                _checkAndRecordSpend(dest, amount);
            }
            // ERC-20 approve(address,uint256)
            else if (selector == 0x095ea7b3 && func_.length >= 68) {
                uint256 amount = abi.decode(func_[36:68], (uint256));
                _checkAndRecordSpend(dest, amount);
            }
        }

        (bool success, bytes memory result) = dest.call{value: value}(func_);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function _verifyP256(bytes32 hash, uint256 r, uint256 s) private view returns (bool) {
        bytes32 digest = sha256(abi.encodePacked(hash));
        bytes memory payload = abi.encode(digest, r, s, pubKeyX, pubKeyY);
        (bool success, bytes memory ret) = P256_PRECOMPILE.staticcall(payload);
        if (success && ret.length == 32 && abi.decode(ret, (uint256)) == 1) {
            return true;
        }
        (success, ret) = P256_VERIFIER.staticcall(payload);
        return success && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
    }

    receive() external payable {}
}
