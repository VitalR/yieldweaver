// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";

abstract contract BaseScript is Script {
    function _addrOrZero(string memory key) internal view returns (address a) {
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return address(0);
        }
    }

    function _envUintOr(string memory key, uint256 def) internal view returns (uint256 v) {
        try vm.envUint(key) returns (uint256 u) {
            return u;
        } catch {
            return def;
        }
    }

    function _envBool(string memory key) internal view returns (bool v) {
        try vm.envBool(key) returns (bool b) {
            return b;
        } catch {
            (bool parsed, bool success) = _tryParseBool(key);
            if (success) return parsed;
            return false;
        }
    }

    function _envBoolOr(string memory key, bool def) internal view returns (bool v) {
        try vm.envBool(key) returns (bool b) {
            return b;
        } catch {
            (bool parsed, bool success) = _tryParseBool(key);
            if (success) return parsed;
            return def;
        }
    }

    function _boolToString(bool value) internal pure returns (string memory) {
        return value ? "true" : "false";
    }

    function _tryParseBool(string memory key) internal view returns (bool parsed, bool success) {
        try vm.envString(key) returns (string memory raw) {
            bytes32 h = keccak256(bytes(_lower(raw)));
            if (h == keccak256("true") || h == keccak256("1") || h == keccak256("yes")) return (true, true);
            if (h == keccak256("false") || h == keccak256("0") || h == keccak256("no")) return (false, true);
            return (false, false);
        } catch {
            return (false, false);
        }
    }

    function _lower(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 65 && c <= 90) b[i] = bytes1(c + 32);
        }
        return string(b);
    }

    function _syncDeployerNonce(address signer) internal returns (uint256 onchainNonce) {
        onchainNonce = _getOnchainNonceOrDefault(signer);
        uint256 localNonce = vm.getNonce(signer);
        if (localNonce != onchainNonce) {
            vm.setNonce(signer, uint64(onchainNonce));
        }
    }

    function _getOnchainNonceOrDefault(address signer) internal returns (uint256 nonce) {
        string memory params = string.concat("[\"", vm.toString(signer), "\",\"latest\"]");
        try vm.rpc("eth_getTransactionCount", params) returns (bytes memory raw) {
            if (raw.length > 0) {
                nonce = _decodeRpcUint(raw);
                return nonce;
            }
        } catch { }
        nonce = vm.getNonce(signer);
    }

    function _decodeRpcUint(bytes memory raw) internal pure returns (uint256 value) {
        if (raw.length >= 2 && raw[0] == "0" && (raw[1] == "x" || raw[1] == "X")) {
            for (uint256 i = 2; i < raw.length; i++) {
                uint8 c = uint8(raw[i]);
                uint8 nibble;
                if (c >= 48 && c <= 57) nibble = c - 48;
                else if (c >= 97 && c <= 102) nibble = 10 + c - 97;
                else if (c >= 65 && c <= 70) nibble = 10 + c - 65;
                else continue;
                value = (value << 4) | nibble;
            }
            return value;
        }

        if (raw.length <= 32) {
            for (uint256 i; i < raw.length; i++) {
                value = (value << 8) | uint8(raw[i]);
            }
            return value;
        }

        return abi.decode(raw, (uint256));
    }
}
