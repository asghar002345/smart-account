// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseTest} from "../utils/BaseTest.sol";
import {SmartAccount} from "../../src/SmartAccount.sol";
import {AccountFactory} from "../../src/AccountFactory.sol";
import {SessionKeyValidator} from "../../src/modules/SessionKeyValidator.sol";
import {IMilestoneEscrow} from "../../src/interfaces/IMilestoneEscrow.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {Execution} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";

/// @notice Fork test against the live EntryPoint v0.7 and deployed MilestoneEscrow on Base Sepolia.
///         RPC: $BASE_SEPOLIA_RPC_URL or https://sepolia.base.org. Nothing is broadcast.
contract BaseSepoliaForkTest is BaseTest {
    uint256 internal constant FORK_BLOCK = 51_235_699;
    IMilestoneEscrow internal constant ESCROW = IMilestoneEscrow(ESCROW_ADDR);

    uint256 internal providerOwnerKey = 0xB0B0;
    uint256 internal operatorKey = 0x0FE2A70;
    address internal operator;
    address internal arbiter = address(0xA2B1);
    SmartAccount internal client;
    SmartAccount internal provider;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://sepolia.base.org")), FORK_BLOCK);
        assertGt(EP_ADDR.code.length, 0, "EntryPoint v0.7 missing");
        assertGt(ESCROW_ADDR.code.length, 0, "MilestoneEscrow missing");
        _deploySystem(ESCROW_ADDR);
        operator = vm.addr(operatorKey);
    }

    function _deployViaInitCode(bytes memory init, uint256 key, bytes memory callData)
        internal
        returns (address sender)
    {
        sender = factory.getAddress(init, 0);
        vm.deal(sender, 1 ether);
        bytes memory initCode =
            abi.encodePacked(address(factory), abi.encodeCall(AccountFactory.createAccount, (init, 0)));
        _handle(_signOwner(_userOp(sender, address(ecdsa), initCode, callData), key));
    }

    function test_fork_fullEscrowFlow_viaHandleOps() public {
        // ---- provider account: deployed by its first op, which also enables the scoped operator session key
        address[] memory ops = new address[](1);
        ops[0] = operator; // also allowed on EscrowExecutor (keeper path)
        SessionKeyValidator.SessionConfig memory c;
        c.sessionKey = operator;
        c.validUntil = uint48(block.timestamp + 30 days);
        c.permissions = new SessionKeyValidator.Permission[](3);
        c.permissions[0] = SessionKeyValidator.Permission(ESCROW_ADDR, IMilestoneEscrow.submitMilestone.selector);
        c.permissions[1] = SessionKeyValidator.Permission(ESCROW_ADDR, IMilestoneEscrow.claimAfterReview.selector);
        c.permissions[2] = SessionKeyValidator.Permission(ESCROW_ADDR, IMilestoneEscrow.withdraw.selector);
        address pAddr = factory.getAddress(_fullInitData(vm.addr(providerOwnerKey), ops), 0);
        _deployViaInitCode(
            _fullInitData(vm.addr(providerOwnerKey), ops),
            providerOwnerKey,
            _single(address(sessions), 0, abi.encodeCall(SessionKeyValidator.enableSession, (c)))
        );
        provider = SmartAccount(payable(pAddr));
        // id depends on the module epoch, which is set at install time (during deployment)
        bytes32 sid = sessions.sessionIdOf(pAddr, operator, 0);
        assertEq(sessions.getSession(pAddr, sid).sessionKey, operator);

        // ---- client account: deployed + createEscrow + fund in ONE batched op (escrowId predicted)
        uint256 id = ESCROW.nextEscrowId();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0.01 ether;
        amounts[1] = 0.02 ether;
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(
            ESCROW_ADDR,
            0,
            abi.encodeCall(
                IMilestoneEscrow.createEscrow,
                (pAddr, arbiter, address(0), amounts, uint64(1 hours), uint64(block.timestamp + 7 days))
            )
        );
        calls[1] = Execution(ESCROW_ADDR, 0.03 ether, abi.encodeCall(IMilestoneEscrow.fund, (id)));
        client = SmartAccount(payable(_deployViaInitCode(_initData(owner), ownerKey, _batch(calls))));
        assertEq(ESCROW.nextEscrowId(), id + 1);

        // ---- operator session key submits milestone 0 (gas paid by provider account deposit)
        _handle(
            _signSession(
                _userOp(
                    pAddr,
                    address(sessions),
                    "",
                    _single(ESCROW_ADDR, 0, abi.encodeCall(IMilestoneEscrow.submitMilestone, (id, 0)))
                ),
                operatorKey,
                sid
            )
        );
        // session key cannot reach owner-only selectors (raiseDispute)
        PackedUserOperation[] memory bad = new PackedUserOperation[](1);
        bad[0] = _signSession(
            _userOp(
                pAddr,
                address(sessions),
                "",
                _single(ESCROW_ADDR, 0, abi.encodeCall(IMilestoneEscrow.raiseDispute, (id)))
            ),
            operatorKey,
            sid
        );
        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA24 signature error"));
        EP.handleOps(bad, beneficiary);

        // ---- client owner approves milestone 0 on-chain via userOp
        _ownerCall(client, ESCROW_ADDR, abi.encodeCall(IMilestoneEscrow.approveMilestone, (id, 0)));

        // ---- keeper path: operator submits milestone 1 through EscrowExecutor
        vm.prank(operator);
        escrowExec.submitMilestone(pAddr, id, 1);

        // ---- client approves milestone 1 off-chain (ERC-1271), relayed by anyone
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = ESCROW.approvalDigest(id, 1, 0.02 ether, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, ecdsa.accountMessageDigest(address(client), digest));
        vm.prank(address(0x5EED));
        ESCROW.approveMilestoneWithSig(id, 1, deadline, abi.encodePacked(address(ecdsa), r, s, v));

        // ---- operator session key withdraws; funds land in the provider account
        uint256 credit = ESCROW.withdrawable(pAddr, address(0));
        assertGt(credit, 0);
        assertLe(credit, 0.03 ether);
        uint256 balBefore = pAddr.balance;
        _handle(
            _signSession(
                _userOp(
                    pAddr,
                    address(sessions),
                    "",
                    _single(ESCROW_ADDR, 0, abi.encodeCall(IMilestoneEscrow.withdraw, (address(0))))
                ),
                operatorKey,
                sid
            )
        );
        assertEq(ESCROW.withdrawable(pAddr, address(0)), 0);
        // received the credit minus the gas the account prefunded for this op
        assertGt(pAddr.balance, balBefore);
        assertGt(pAddr.balance + 0.01 ether, balBefore + credit);
    }

    function test_fork_ownerOp_getUserOpHashMatchesLiveEntryPoint() public view {
        bytes memory init = _initData(owner);
        address sender = factory.getAddress(init, 0);
        PackedUserOperation memory op = _userOp(sender, address(ecdsa), "", "");
        // userOpHash must commit to chainId 84532 and the v0.7 EntryPoint
        bytes32 expected = keccak256(
            abi.encode(
                keccak256(
                    abi.encode(
                        op.sender,
                        op.nonce,
                        keccak256(op.initCode),
                        keccak256(op.callData),
                        op.accountGasLimits,
                        op.preVerificationGas,
                        op.gasFees,
                        keccak256(op.paymasterAndData)
                    )
                ),
                EP_ADDR,
                uint256(84532)
            )
        );
        assertEq(block.chainid, 84532);
        assertEq(EP.getUserOpHash(op), expected);
    }
}
