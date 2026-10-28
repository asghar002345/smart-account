// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    IERC7579Module,
    IERC7579Hook,
    MODULE_TYPE_HOOK,
    MODULE_TYPE_FALLBACK
} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {IMilestoneEscrow} from "../../src/interfaces/IMilestoneEscrow.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Target {
    uint256 public value;
    address public lastCaller;

    function setValue(uint256 v) external payable {
        value = v;
        lastCaller = msg.sender;
    }

    function fail() external pure {
        revert("nope");
    }
}

contract MockHook is IERC7579Hook {
    uint256 public pre;
    uint256 public post;

    function onInstall(bytes calldata) external {}
    function onUninstall(bytes calldata) external {}

    function isModuleType(uint256 t) external pure returns (bool) {
        return t == MODULE_TYPE_HOOK;
    }

    function preCheck(address, uint256, bytes calldata) external returns (bytes memory) {
        ++pre;
        return "";
    }

    function postCheck(bytes calldata) external {
        ++post;
    }
}

contract MockFallback is IERC7579Module {
    function onInstall(bytes calldata) external {}
    function onUninstall(bytes calldata) external {}

    function isModuleType(uint256 t) external pure returns (bool) {
        return t == MODULE_TYPE_FALLBACK;
    }

    function hello() external pure returns (uint256) {
        return 42;
    }
}

/// @dev Minimal stand-in for MilestoneEscrow (msg.sender-authorized) used in unit tests only.
contract MockEscrow {
    address public lastCaller;
    bytes4 public lastSelector;
    uint256 public calls;
    mapping(uint256 => uint128[]) internal _amounts;

    function setMilestones(uint256 id, uint128[] calldata a) external {
        _amounts[id] = a;
    }

    function getMilestones(uint256 id) external view returns (IMilestoneEscrow.Milestone[] memory ms) {
        uint128[] memory a = _amounts[id];
        ms = new IMilestoneEscrow.Milestone[](a.length);
        for (uint256 i; i < a.length; ++i) {
            ms[i].amount = a[i];
        }
    }

    function _rec() internal {
        lastCaller = msg.sender;
        lastSelector = msg.sig;
        ++calls;
    }

    function submitMilestone(uint256, uint256) external {
        _rec();
    }

    function approveMilestone(uint256, uint256) external {
        _rec();
    }

    function claimAfterReview(uint256, uint256) external {
        _rec();
    }

    function withdraw(address) external returns (uint256) {
        _rec();
        return 0;
    }
}
