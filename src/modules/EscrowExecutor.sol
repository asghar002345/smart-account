// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    IERC7579Module,
    IERC7579Execution,
    MODULE_TYPE_EXECUTOR
} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {IMilestoneEscrow} from "../interfaces/IMilestoneEscrow.sol";

/// @title EscrowExecutor
/// @notice ERC-7579 executor letting owner-approved operators (keeper/backend) drive a restricted subset of the
///         immutable MilestoneEscrow on the account's behalf, always with value 0:
///         provider side `submitMilestone`, `claimAfterReview`, `withdraw` (funds land in the account), and client
///         side `approveMilestone` only for escrows the owner whitelisted, with an optional cumulative cap.
///         `createEscrow`, `fund`, `raiseDispute` are never reachable through this module.
contract EscrowExecutor is IERC7579Module {
    /// @dev ERC-7579 mode: CALLTYPE_SINGLE (0x00), EXECTYPE_DEFAULT (0x00), no selector/payload.
    bytes32 internal constant _MODE_SINGLE_DEFAULT = bytes32(0);

    IMilestoneEscrow public immutable escrow;

    struct ApprovalAllowance {
        bool allowed;
        uint256 cap; // 0 = uncapped
        uint256 used;
    }

    mapping(address account => uint64) public epochOf;
    mapping(address account => bool) public installed;
    mapping(address account => mapping(uint64 epoch => mapping(address operator => bool))) internal _operators;
    mapping(address account => mapping(uint64 epoch => mapping(uint256 escrowId => ApprovalAllowance))) internal
        _allowances;

    event OperatorSet(address indexed account, address indexed operator, bool allowed);
    event ApprovableSet(address indexed account, uint256 indexed escrowId, bool allowed, uint256 cap);

    error NotInstalled();
    error NotOperator();
    error NotApprovable();
    error CapExceeded();
    error ZeroAddress();

    constructor(IMilestoneEscrow escrow_) {
        if (address(escrow_) == address(0)) revert ZeroAddress();
        escrow = escrow_;
    }

    // ------------------------------------------------------------------ module config
    /// @param data abi.encode(address[] operators) or empty
    function onInstall(bytes calldata data) external override {
        installed[msg.sender] = true;
        uint64 e = ++epochOf[msg.sender];
        if (data.length != 0) {
            address[] memory ops = abi.decode(data, (address[]));
            for (uint256 i; i < ops.length; ++i) {
                _operators[msg.sender][e][ops[i]] = true;
                emit OperatorSet(msg.sender, ops[i], true);
            }
        }
    }

    function onUninstall(bytes calldata) external override {
        installed[msg.sender] = false;
        ++epochOf[msg.sender];
    }

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    // ------------------------------------------------------------------ owner (account) config
    function setOperator(address operator, bool allowed) external {
        if (!installed[msg.sender]) revert NotInstalled();
        _operators[msg.sender][epochOf[msg.sender]][operator] = allowed;
        emit OperatorSet(msg.sender, operator, allowed);
    }

    function setApprovable(uint256 escrowId, bool allowed, uint256 cap) external {
        if (!installed[msg.sender]) revert NotInstalled();
        ApprovalAllowance storage a = _allowances[msg.sender][epochOf[msg.sender]][escrowId];
        a.allowed = allowed;
        a.cap = cap;
        emit ApprovableSet(msg.sender, escrowId, allowed, cap);
    }

    // ------------------------------------------------------------------ operator actions
    function submitMilestone(address account, uint256 escrowId, uint256 index) external {
        _exec(account, abi.encodeCall(IMilestoneEscrow.submitMilestone, (escrowId, index)));
    }

    function claimAfterReview(address account, uint256 escrowId, uint256 index) external {
        _exec(account, abi.encodeCall(IMilestoneEscrow.claimAfterReview, (escrowId, index)));
    }

    function withdraw(address account, address token) external {
        _exec(account, abi.encodeCall(IMilestoneEscrow.withdraw, (token)));
    }

    function approveMilestone(address account, uint256 escrowId, uint256 index) external {
        ApprovalAllowance storage a = _allowances[account][epochOf[account]][escrowId];
        if (!a.allowed) revert NotApprovable();
        if (a.cap != 0) {
            IMilestoneEscrow.Milestone[] memory ms = escrow.getMilestones(escrowId);
            uint256 used = a.used + (index < ms.length ? ms[index].amount : 0);
            if (used > a.cap) revert CapExceeded();
            a.used = used;
        }
        _exec(account, abi.encodeCall(IMilestoneEscrow.approveMilestone, (escrowId, index)));
    }

    // ------------------------------------------------------------------ views
    function isOperator(address account, address operator) external view returns (bool) {
        return _operators[account][epochOf[account]][operator];
    }

    function allowance(address account, uint256 escrowId) external view returns (ApprovalAllowance memory) {
        return _allowances[account][epochOf[account]][escrowId];
    }

    // ------------------------------------------------------------------ internals
    function _exec(address account, bytes memory data) internal {
        if (!installed[account]) revert NotInstalled();
        if (!_operators[account][epochOf[account]][msg.sender]) revert NotOperator();
        IERC7579Execution(account)
            .executeFromExecutor(_MODE_SINGLE_DEFAULT, abi.encodePacked(address(escrow), uint256(0), data));
    }
}
