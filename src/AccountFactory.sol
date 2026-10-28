// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IEntryPointStake} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {SmartAccount} from "./SmartAccount.sol";

/// @title AccountFactory
/// @notice CREATE2 factory deploying immutable ERC-1167 clones of {SmartAccount}.
///         The CREATE2 salt is `keccak256(initData, userSalt)` so the counterfactual address commits to the
///         initial module set (and therefore the owner): nobody can front-run with a different owner.
contract AccountFactory is Ownable {
    address public constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address public immutable implementation;

    event AccountCreated(address indexed account, bytes32 indexed salt);

    error InvalidInitData();

    constructor(address owner_) Ownable(owner_) {
        implementation = address(new SmartAccount());
    }

    /// @param initData abi-encoded call to {SmartAccount-initialize}
    /// @param salt user-chosen salt (e.g. 0 for the first account of an owner)
    function createAccount(bytes calldata initData, bytes32 salt) external returns (address account) {
        if (initData.length < 4 || bytes4(initData) != SmartAccount.initialize.selector) revert InvalidInitData();
        bytes32 s = _salt(initData, salt);
        account = Clones.predictDeterministicAddress(implementation, s);
        if (account.code.length != 0) return account; // idempotent
        Clones.cloneDeterministic(implementation, s);
        emit AccountCreated(account, salt);
        Address.functionCall(account, initData);
    }

    function getAddress(bytes calldata initData, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(initData, salt));
    }

    function _salt(bytes calldata initData, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256(initData), salt));
    }

    // --- EntryPoint stake (needed by ERC-7562 STO-022 because init writes module storage) ---
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        IEntryPointStake(ENTRY_POINT).addStake{value: msg.value}(unstakeDelaySec);
    }

    function unlockStake() external onlyOwner {
        IEntryPointStake(ENTRY_POINT).unlockStake();
    }

    function withdrawStake(address payable to) external onlyOwner {
        IEntryPointStake(ENTRY_POINT).withdrawStake(to);
    }
}
