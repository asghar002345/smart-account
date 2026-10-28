// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseTest} from "./utils/BaseTest.sol";
import {Target} from "./utils/Mocks.sol";
import {SmartAccount} from "../src/SmartAccount.sol";
import {RecoveryExecutor} from "../src/modules/RecoveryExecutor.sol";
import {MODULE_TYPE_VALIDATOR, MODULE_TYPE_EXECUTOR} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";

contract RecoveryExecutorTest is BaseTest {
    SmartAccount internal acc;
    uint256 internal newKey = 0x4E3;
    address internal newOwner;

    function setUp() public {
        _etchEntryPoint();
        _deploySystem(address(0xE5C));
        acc = _createAccount(_fullInitData(owner, new address[](0)), 0);
        vm.deal(address(acc), 10 ether);
        newOwner = vm.addr(newKey);
    }

    function _queue() internal {
        vm.prank(g1);
        recovery.proposeRecovery(address(acc), newOwner);
        vm.prank(g2);
        recovery.approveRecovery(address(acc));
    }

    function test_config_defaults() public view {
        RecoveryExecutor.Config memory c = recovery.getConfig(address(acc));
        assertEq(c.guardians.length, 3);
        assertEq(c.threshold, 2);
        assertEq(c.timelock, 48 hours);
        assertTrue(recovery.isModuleType(MODULE_TYPE_EXECUTOR));
        assertFalse(recovery.isModuleType(MODULE_TYPE_VALIDATOR));
    }

    function test_fullRecovery_2of3_after48h() public {
        _queue();
        RecoveryExecutor.Request memory r = recovery.getRequest(address(acc));
        assertEq(r.readyAt, block.timestamp + 48 hours);
        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(RecoveryExecutor.NotReady.selector);
        recovery.executeRecovery(address(acc));
        vm.warp(block.timestamp + 1);
        recovery.executeRecovery(address(acc));
        assertEq(ecdsa.ownerOf(address(acc)), newOwner);
        assertEq(recovery.nonce(address(acc)), 1);
        // new owner can operate, old cannot
        Target t = new Target();
        PackedUserOperation memory op =
            _userOp(address(acc), address(ecdsa), "", _single(address(t), 0, abi.encodeCall(Target.setValue, (8))));
        _handle(_signOwner(op, newKey));
        assertEq(t.value(), 8);
    }

    function test_belowThreshold_notReady() public {
        vm.prank(g1);
        recovery.proposeRecovery(address(acc), newOwner);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(RecoveryExecutor.NotReady.selector);
        recovery.executeRecovery(address(acc));
    }

    function test_ownerCancel() public {
        _queue();
        _ownerCall(acc, address(recovery), abi.encodeCall(RecoveryExecutor.cancelRecovery, ()));
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(RecoveryExecutor.NoActiveRequest.selector);
        recovery.executeRecovery(address(acc));
        assertEq(ecdsa.ownerOf(address(acc)), owner);
        // old approvals do not carry over to the next request
        vm.prank(g1);
        recovery.proposeRecovery(address(acc), newOwner);
        assertEq(recovery.getRequest(address(acc)).approvals, 1);
        vm.prank(address(acc));
        recovery.cancelRecovery();
        vm.prank(address(acc));
        vm.expectRevert(RecoveryExecutor.NoActiveRequest.selector);
        recovery.cancelRecovery();
        vm.prank(address(0x1234));
        vm.expectRevert(RecoveryExecutor.NotInstalled.selector);
        recovery.cancelRecovery();
    }

    function test_guards() public {
        vm.expectRevert(RecoveryExecutor.NotGuardian.selector);
        recovery.proposeRecovery(address(acc), newOwner);
        vm.startPrank(g1);
        vm.expectRevert(RecoveryExecutor.InvalidOwner.selector);
        recovery.proposeRecovery(address(acc), address(0));
        vm.expectRevert(RecoveryExecutor.NoActiveRequest.selector);
        recovery.approveRecovery(address(acc));
        recovery.proposeRecovery(address(acc), newOwner);
        vm.expectRevert(RecoveryExecutor.AlreadyApproved.selector);
        recovery.approveRecovery(address(acc));
        vm.stopPrank();
        vm.prank(g2);
        vm.expectRevert(RecoveryExecutor.RequestActive.selector);
        recovery.proposeRecovery(address(acc), address(0x55));
        vm.expectRevert(RecoveryExecutor.NoActiveRequest.selector);
        recovery.executeRecovery(address(0x1234));
    }

    function test_approveWithSig_andReplayProtection() public {
        vm.prank(g1);
        recovery.proposeRecovery(address(acc), newOwner);
        bytes32 d = recovery.approvalDigest(address(acc), newOwner, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(g3Key, d);
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.expectRevert(RecoveryExecutor.InvalidSignature.selector);
        recovery.approveRecoveryWithSig(address(acc), g2, sig);
        recovery.approveRecoveryWithSig(address(acc), g3, sig);
        assertGt(recovery.getRequest(address(acc)).readyAt, 0);
        // cancel bumps nonce; the old signature is useless for the next request
        vm.prank(address(acc));
        recovery.cancelRecovery();
        vm.prank(g1);
        recovery.proposeRecovery(address(acc), newOwner);
        vm.expectRevert(RecoveryExecutor.InvalidSignature.selector);
        recovery.approveRecoveryWithSig(address(acc), g3, sig);
        vm.prank(address(acc));
        recovery.cancelRecovery();
        vm.expectRevert(RecoveryExecutor.NoActiveRequest.selector);
        recovery.approveRecoveryWithSig(address(acc), g3, sig);
    }

    function test_guardianUpdate_timelocked() public {
        address[] memory gs = new address[](1);
        gs[0] = address(0x61);
        vm.startPrank(address(acc));
        recovery.scheduleGuardianUpdate(gs, 1, 24 hours);
        vm.expectRevert(RecoveryExecutor.Timelocked.selector);
        recovery.applyGuardianUpdate(address(acc));
        recovery.cancelGuardianUpdate();
        vm.expectRevert(RecoveryExecutor.NothingScheduled.selector);
        recovery.cancelGuardianUpdate();
        vm.expectRevert(RecoveryExecutor.NothingScheduled.selector);
        recovery.applyGuardianUpdate(address(acc));
        recovery.scheduleGuardianUpdate(gs, 1, 24 hours);
        vm.stopPrank();
        assertEq(recovery.getPendingConfig(address(acc)).executableAt, block.timestamp + 48 hours);
        // an in-flight recovery from the old set is cleared on apply
        vm.prank(g1);
        recovery.proposeRecovery(address(acc), newOwner);
        vm.warp(block.timestamp + 48 hours);
        recovery.applyGuardianUpdate(address(acc));
        assertFalse(recovery.isGuardian(address(acc), g1));
        assertTrue(recovery.isGuardian(address(acc), address(0x61)));
        assertEq(recovery.getRequest(address(acc)).newOwner, address(0));
    }

    function test_invalidConfigs() public {
        address[] memory gs = new address[](4);
        gs[0] = address(1);
        gs[1] = address(2);
        gs[2] = address(3);
        gs[3] = address(4);
        vm.startPrank(address(acc));
        vm.expectRevert(RecoveryExecutor.InvalidConfig.selector);
        recovery.scheduleGuardianUpdate(gs, 2, 48 hours); // not a strict majority
        vm.expectRevert(RecoveryExecutor.InvalidConfig.selector);
        recovery.scheduleGuardianUpdate(gs, 5, 48 hours);
        vm.expectRevert(RecoveryExecutor.InvalidConfig.selector);
        recovery.scheduleGuardianUpdate(gs, 3, 1 hours);
        vm.expectRevert(RecoveryExecutor.InvalidConfig.selector);
        recovery.scheduleGuardianUpdate(gs, 3, 31 days);
        vm.expectRevert(RecoveryExecutor.InvalidConfig.selector);
        recovery.scheduleGuardianUpdate(new address[](0), 1, 48 hours);
        vm.expectRevert(RecoveryExecutor.InvalidConfig.selector);
        recovery.scheduleGuardianUpdate(new address[](11), 6, 48 hours);
        gs[3] = address(0);
        vm.expectRevert(RecoveryExecutor.InvalidConfig.selector);
        recovery.scheduleGuardianUpdate(gs, 3, 48 hours);
        vm.expectRevert(RecoveryExecutor.AlreadyInstalled.selector);
        recovery.onInstall(abi.encode(gs, uint8(3), uint32(0)));
        vm.stopPrank();
        // duplicates
        address[] memory dup = new address[](2);
        dup[0] = address(7);
        dup[1] = address(7);
        vm.prank(address(0x999));
        vm.expectRevert(RecoveryExecutor.InvalidConfig.selector);
        recovery.onInstall(abi.encode(dup, uint8(2), uint32(0)));
        vm.prank(address(0x999));
        vm.expectRevert(RecoveryExecutor.NotInstalled.selector);
        recovery.scheduleUninstall();
    }

    function test_uninstall_timelocked() public {
        bytes memory call = abi.encodeCall(acc.uninstallModule, (MODULE_TYPE_EXECUTOR, address(recovery), ""));
        vm.prank(EP_ADDR);
        vm.expectRevert(RecoveryExecutor.Timelocked.selector);
        acc.execute(bytes32(0), abi.encodePacked(address(acc), uint256(0), call));
        vm.prank(address(acc));
        recovery.scheduleUninstall();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(EP_ADDR);
        acc.execute(bytes32(0), abi.encodePacked(address(acc), uint256(0), call));
        assertFalse(acc.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(recovery), ""));
        assertFalse(recovery.isGuardian(address(acc), g1));
        // module can no longer rotate the owner
        vm.prank(g1);
        vm.expectRevert(RecoveryExecutor.NotGuardian.selector);
        recovery.proposeRecovery(address(acc), newOwner);
    }

    function test_recoveryFails_ifExecutorUninstalledElsewhere() public {
        // account without RecoveryExecutor installed: executeFromExecutor reverts
        SmartAccount other = _createAccount(_initData(owner), bytes32(uint256(5)));
        address[] memory gs = new address[](1);
        gs[0] = g1;
        vm.prank(address(other));
        recovery.onInstall(abi.encode(gs, uint8(1), uint32(24 hours)));
        vm.prank(g1);
        recovery.proposeRecovery(address(other), newOwner);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert();
        recovery.executeRecovery(address(other));
    }

    // ---------------------------------------------------------------- fuzz
    function testFuzz_timelockBoundary(uint32 timelock, uint32 dt) public {
        timelock = uint32(bound(timelock, 24 hours, 30 days));
        dt = uint32(bound(dt, 0, 31 days));
        SmartAccount other = _createAccount(_initData(owner), bytes32(uint256(6)));
        address[] memory gs = new address[](3);
        gs[0] = g1;
        gs[1] = g2;
        gs[2] = g3;
        vm.prank(EP_ADDR);
        other.installModule(MODULE_TYPE_EXECUTOR, address(recovery), abi.encode(gs, uint8(2), timelock));
        vm.prank(g1);
        recovery.proposeRecovery(address(other), newOwner);
        vm.prank(g3);
        recovery.approveRecovery(address(other));
        vm.warp(block.timestamp + dt);
        if (dt < timelock) {
            vm.expectRevert(RecoveryExecutor.NotReady.selector);
            recovery.executeRecovery(address(other));
        } else {
            recovery.executeRecovery(address(other));
            assertEq(ecdsa.ownerOf(address(other)), newOwner);
        }
    }
}
