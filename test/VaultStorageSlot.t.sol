// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {VaultStorage} from "../src/libraries/VaultStorage.sol";
import {VaultV2Storage} from "./mocks/VaultV2.sol";

/// @notice 守护硬编码的 ERC-7201 槽位常量。
/// @dev 这些常量里只要有一个字母打错，金库的全部状态就会被悄无声息地搬到别处，
///      因此这里按 ERC-7201 规定的公式，从命名空间字符串重新推导一遍。
contract VaultStorageSlotTest is Test {
    /// @dev `keccak256(abi.encode(uint256(keccak256(label)) - 1)) & ~bytes32(uint256(0xff))`。
    function _erc7201Slot(string memory label) private pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(label))) - 1)) & ~bytes32(uint256(0xff));
    }

    function test_VaultStorageSlotMatchesNamespace() public pure {
        assertEq(VaultStorage.SLOT, _erc7201Slot("vault.storage.BlockchainVault"));
    }

    function test_VaultV2StorageSlotMatchesNamespace() public pure {
        assertEq(VaultV2Storage.SLOT, _erc7201Slot("vault.storage.BlockchainVaultV2"));
    }

    function test_VaultNamespacesAreDistinct() public pure {
        assertNotEq(VaultStorage.SLOT, VaultV2Storage.SLOT);
    }
}
