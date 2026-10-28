// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Subset of the deployed MilestoneEscrow (Base Sepolia 0xD861488f2ba02df4047DDE41EFeCdCEd1FD6E528)
///         used by the account modules and tests. Mirrors `IEscrowModule` in /workspace/milestone-escrow.
interface IMilestoneEscrow {
    struct Milestone {
        uint128 amount;
        uint64 submittedAt;
        uint8 status;
    }

    function createEscrow(
        address provider,
        address arbiter,
        address token,
        uint256[] calldata amounts,
        uint64 reviewPeriod,
        uint64 deadline
    ) external returns (uint256 escrowId);
    function fund(uint256 escrowId) external payable;
    function submitMilestone(uint256 escrowId, uint256 index) external;
    function approveMilestone(uint256 escrowId, uint256 index) external;
    function approveMilestoneWithSig(uint256 escrowId, uint256 index, uint256 sigDeadline, bytes calldata signature)
        external;
    function approvalDigest(uint256 escrowId, uint256 index, uint256 amount, uint256 sigDeadline)
        external
        view
        returns (bytes32);
    function claimAfterReview(uint256 escrowId, uint256 index) external;
    function raiseDispute(uint256 escrowId) external;
    function withdraw(address token) external returns (uint256 amount);
    function withdrawable(address account, address token) external view returns (uint256);
    function getMilestones(uint256 escrowId) external view returns (Milestone[] memory);
    function nextEscrowId() external view returns (uint256);
}
