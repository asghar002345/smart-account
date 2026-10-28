// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Account} from "@openzeppelin/contracts/account/Account.sol";
import {AccountERC7579} from "@openzeppelin/contracts/account/extensions/draft-AccountERC7579.sol";
import {AccountERC7579Hooked} from "@openzeppelin/contracts/account/extensions/draft-AccountERC7579Hooked.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/ERC4337Utils.sol";
import {ERC7579Utils, Mode, CallType} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {IEntryPoint} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {MODULE_TYPE_VALIDATOR} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @title VaultLite SmartAccount
/// @notice Thin, immutable ERC-7579 account on OpenZeppelin's AccountERC7579Hooked, bound to EntryPoint v0.7.
///         Deployed as ERC-1167 clones by {AccountFactory}. Validator is selected by the top 20 bytes of the
///         userOp nonce key (OZ convention: `validator(20) | key(4) | seq(8)`). Delegatecall execution is disabled.
contract SmartAccount is AccountERC7579Hooked, Initializable, ERC721Holder, ERC1155Holder {
    using ERC7579Utils for Mode;

    struct ModuleInit {
        uint256 moduleTypeId;
        address module;
        bytes initData;
    }

    error NoValidator();
    error DelegateCallDisabled();

    constructor() {
        _disableInitializers();
    }

    /// @notice One-time initializer called by the factory in the same tx as the clone deployment.
    /// @param modules modules to install; at least one validator is required.
    function initialize(ModuleInit[] calldata modules) external initializer {
        bool hasValidator = false;
        for (uint256 i; i < modules.length; ++i) {
            if (modules[i].moduleTypeId == MODULE_TYPE_VALIDATOR) hasValidator = true;
            _installModule(modules[i].moduleTypeId, modules[i].module, modules[i].initData);
        }
        if (!hasValidator) revert NoValidator();
    }

    /// @inheritdoc Account
    function entryPoint() public pure override returns (IEntryPoint) {
        return ERC4337Utils.ENTRYPOINT_V07;
    }

    function accountId() public pure override returns (string memory) {
        return "vaultlite.smartaccount.v1";
    }

    /// @dev Same as OZ minus CALLTYPE_DELEGATECALL (disabled in v1).
    function supportsExecutionMode(bytes32 encodedMode) public view override returns (bool) {
        (CallType callType,,,) = Mode.wrap(encodedMode).decodeMode();
        if (callType == ERC7579Utils.CALLTYPE_DELEGATECALL) return false;
        return super.supportsExecutionMode(encodedMode);
    }

    function _execute(Mode mode, bytes calldata executionCalldata)
        internal
        override
        returns (bytes[] memory returnData)
    {
        (CallType callType,,,) = mode.decodeMode();
        if (callType == ERC7579Utils.CALLTYPE_DELEGATECALL) revert DelegateCallDisabled();
        return super._execute(mode, executionCalldata);
    }
}
