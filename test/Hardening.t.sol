// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseTest} from "./utils/BaseTest.sol";
import {MockERC20, Target} from "./utils/Mocks.sol";
import {SmartAccount} from "../src/SmartAccount.sol";
import {SessionKeyValidator} from "../src/modules/SessionKeyValidator.sol";
import {RecoveryExecutor} from "../src/modules/RecoveryExecutor.sol";
import {ECDSAOwnerValidator} from "../src/modules/ECDSAOwnerValidator.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {Execution} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {MODULE_TYPE_VALIDATOR, MODULE_TYPE_EXECUTOR} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";

/// @dev Calls back into the account while being called by it.
contract Reenterer {
    function poke(address acc) external {
        SmartAccount(payable(acc)).execute(bytes32(0), abi.encodePacked(address(this), uint256(0), ""));
    }

    function pokeExecutor(address acc) external {
        SmartAccount(payable(acc)).executeFromExecutor(bytes32(0), abi.encodePacked(address(this), uint256(0), ""));
    }
}

contract HardeningTest is BaseTest {
    SmartAccount internal acc;
    Target internal target;
    MockERC20 internal token;
    uint256 internal skKey = 0x5E55;
    address internal sk;
    address internal newOwner = address(0x4E3);

    function setUp() public {
        _etchEntryPoint();
        _deploySystem(address(0xE5C));
        acc = _createAccount(_fullInitData(owner, new address[](0)), 0);
        vm.deal(address(acc), 10 ether);
        target = new Target();
        token = new MockERC20();
        token.mint(address(acc), 1000);
        sk = vm.addr(skKey);
    }

    // ------------------------------------------------------------ helpers
    function _cfg(bytes32 salt, uint128 nativeCap) internal view returns (SessionKeyValidator.SessionConfig memory c) {
        c.sessionKey = sk;
        c.nativeCap = nativeCap;
        c.salt = salt;
        c.permissions = new SessionKeyValidator.Permission[](3);
        c.permissions[0] = SessionKeyValidator.Permission(address(target), Target.setValue.selector);
        c.permissions[1] = SessionKeyValidator.Permission(address(0xB0B), bytes4(0));
        c.permissions[2] = SessionKeyValidator.Permission(address(token), token.transferFrom.selector);
        c.tokenCaps = new SessionKeyValidator.TokenCap[](1);
        c.tokenCaps[0] = SessionKeyValidator.TokenCap(address(token), 100);
    }

    function _enable(SessionKeyValidator.SessionConfig memory c) internal returns (bytes32 id) {
        id = sessions.sessionIdOf(address(acc), c.sessionKey, c.salt);
        _ownerCall(acc, address(sessions), abi.encodeCall(SessionKeyValidator.enableSession, (c)));
    }

    function _sop(bytes32 sid, bytes memory callData) internal view returns (PackedUserOperation memory) {
        return _signSession(_userOp(address(acc), address(sessions), "", callData), skKey, sid);
    }

    function _expectFail(PackedUserOperation memory op, string memory reason) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, reason));
        EP.handleOps(ops, beneficiary);
    }

    function _queue() internal {
        vm.prank(g1);
        recovery.proposeRecovery(address(acc), newOwner);
        vm.prank(g2);
        recovery.approveRecovery(address(acc));
    }

    // ------------------------------------------------------------ session keys
    function test_session_nativeCapIsCumulative() public {
        bytes32 sid = _enable(_cfg("a", 1 ether));
        _handle(_sop(sid, _single(address(0xB0B), 0.6 ether, "")));
        _expectFail(_sop(sid, _single(address(0xB0B), 0.5 ether, "")), "AA24 signature error");
        _handle(_sop(sid, _single(address(0xB0B), 0.4 ether, "")));
        assertEq(sessions.getSession(address(acc), sid).nativeSpent, 1 ether);
    }

    function test_session_batchValueSummed() public {
        bytes32 sid = _enable(_cfg("b", 1 ether));
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(address(0xB0B), 0.6 ether, "");
        calls[1] = Execution(address(0xB0B), 0.6 ether, "");
        _expectFail(_sop(sid, _batch(calls)), "AA24 signature error");
    }

    function test_session_transferFromCounted() public {
        bytes32 sid = _enable(_cfg("c", 0));
        _expectFail(
            _sop(sid, _single(address(token), 0, abi.encodeCall(token.transferFrom, (address(acc), address(1), 101)))),
            "AA24 signature error"
        );
    }

    function test_session_valueOnSelectorCallAlsoCapped() public {
        bytes32 sid = _enable(_cfg("d", 0));
        _expectFail(
            _sop(sid, _single(address(target), 1, abi.encodeCall(Target.setValue, (1)))), "AA24 signature error"
        );
    }

    function test_session_uninstallReinstall_invalidatesOldSessions() public {
        bytes32 sid = _enable(_cfg("e", 1 ether));
        _ownerExec(
            acc,
            _single(
                address(acc), 0, abi.encodeCall(acc.uninstallModule, (MODULE_TYPE_VALIDATOR, address(sessions), ""))
            )
        );
        _ownerExec(
            acc,
            _single(address(acc), 0, abi.encodeCall(acc.installModule, (MODULE_TYPE_VALIDATOR, address(sessions), "")))
        );
        _expectFail(
            _sop(sid, _single(address(target), 0, abi.encodeCall(Target.setValue, (1)))), "AA24 signature error"
        );
        assertFalse(
            sessions.isAllowed(
                address(acc), sessions.sessionIdOf(address(acc), sk, "e"), address(target), Target.setValue.selector
            )
        );
    }

    function test_session_enableRequiresInstalled_andRevokedIdNotReusable() public {
        vm.prank(address(0x1234));
        vm.expectRevert(SessionKeyValidator.NotInstalled.selector);
        sessions.enableSession(_cfg("f", 0));
        bytes32 sid = _enable(_cfg("f", 0));
        vm.startPrank(address(acc));
        sessions.revokeSession(sid);
        vm.expectRevert(SessionKeyValidator.SessionExists.selector);
        sessions.enableSession(_cfg("f", 0));
        vm.stopPrank();
    }

    function test_session_cannotTargetAccountOrSelf() public {
        SessionKeyValidator.SessionConfig memory c = _cfg("g", 0);
        c.permissions[0] = SessionKeyValidator.Permission(address(acc), bytes4(0));
        vm.prank(address(acc));
        vm.expectRevert(SessionKeyValidator.InvalidSession.selector);
        sessions.enableSession(c);
    }

    function testFuzz_session_overCapAlwaysRejected(uint128 cap, uint128 value) public {
        cap = uint128(bound(cap, 0, 5 ether));
        value = uint128(bound(value, uint256(cap) + 1, 10 ether));
        bytes32 sid = _enable(_cfg(keccak256(abi.encode(cap, value)), cap));
        _expectFail(_sop(sid, _single(address(0xB0B), value, "")), "AA24 signature error");
    }

    // ------------------------------------------------------------ recovery
    function test_recovery_cannotExecuteTwice() public {
        _queue();
        vm.warp(block.timestamp + 48 hours);
        recovery.executeRecovery(address(acc));
        vm.expectRevert(RecoveryExecutor.NoActiveRequest.selector);
        recovery.executeRecovery(address(acc));
    }

    function test_recovery_oldSigInvalidAfterCancel() public {
        vm.prank(g1);
        recovery.proposeRecovery(address(acc), newOwner);
        bytes32 d = recovery.approvalDigest(address(acc), newOwner, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(g2Key, d);
        vm.prank(address(acc));
        recovery.cancelRecovery();
        vm.prank(g1);
        recovery.proposeRecovery(address(acc), newOwner);
        vm.expectRevert(RecoveryExecutor.InvalidSignature.selector);
        recovery.approveRecoveryWithSig(address(acc), g2, abi.encodePacked(r, s, v));
    }

    function test_recovery_cancelAfterReadyBeforeExecute() public {
        _queue();
        vm.warp(block.timestamp + 72 hours);
        vm.prank(address(acc));
        recovery.cancelRecovery();
        vm.expectRevert(RecoveryExecutor.NoActiveRequest.selector);
        recovery.executeRecovery(address(acc));
        assertEq(ecdsa.ownerOf(address(acc)), owner);
    }

    function test_recovery_proposalWipesScheduledUninstall() public {
        vm.prank(address(acc));
        recovery.scheduleUninstall();
        _queue();
        vm.prank(address(acc));
        recovery.cancelRecovery();
        assertEq(recovery.uninstallAllowedAt(address(acc)), 0);
    }

    function test_recovery_reinstallAfterUninstall_freshState() public {
        vm.prank(address(acc));
        recovery.scheduleUninstall();
        vm.warp(block.timestamp + 48 hours);
        vm.startPrank(EP_ADDR);
        acc.execute(
            bytes32(0),
            abi.encodePacked(
                address(acc),
                uint256(0),
                abi.encodeCall(acc.uninstallModule, (MODULE_TYPE_EXECUTOR, address(recovery), ""))
            )
        );
        address[] memory gs = new address[](1);
        gs[0] = g3;
        acc.installModule(MODULE_TYPE_EXECUTOR, address(recovery), abi.encode(gs, uint8(1), uint32(24 hours)));
        vm.stopPrank();
        assertFalse(recovery.isGuardian(address(acc), g1));
        assertTrue(recovery.isGuardian(address(acc), g3));
        assertEq(recovery.getRequest(address(acc)).newOwner, address(0));
    }

    // ------------------------------------------------------------ account / reentrancy
    function test_reentrancy_targetCannotCallExecute() public {
        Reenterer re = new Reenterer();
        vm.prank(EP_ADDR);
        vm.expectRevert();
        acc.execute(
            bytes32(0), abi.encodePacked(address(re), uint256(0), abi.encodeCall(Reenterer.poke, (address(acc))))
        );
        vm.prank(EP_ADDR);
        vm.expectRevert();
        acc.execute(
            bytes32(0),
            abi.encodePacked(address(re), uint256(0), abi.encodeCall(Reenterer.pokeExecutor, (address(acc))))
        );
    }

    function test_module_doubleInstallAndUninstallMissing_revert() public {
        vm.startPrank(EP_ADDR);
        vm.expectRevert();
        acc.installModule(MODULE_TYPE_VALIDATOR, address(ecdsa), abi.encode(owner));
        vm.expectRevert();
        acc.uninstallModule(MODULE_TYPE_EXECUTOR, address(0xdead), "");
        vm.stopPrank();
    }

    function test_module_directOnInstallIsPerCaller() public {
        // calling a module directly only configures the caller's own slot
        vm.prank(address(0x777));
        sessions.onUninstall("");
        assertTrue(sessions.installed(address(acc)));
    }
}
