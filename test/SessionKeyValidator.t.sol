// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseTest} from "./utils/BaseTest.sol";
import {MockERC20, Target} from "./utils/Mocks.sol";
import {SmartAccount} from "../src/SmartAccount.sol";
import {SessionKeyValidator} from "../src/modules/SessionKeyValidator.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {Execution} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {MODULE_TYPE_VALIDATOR, MODULE_TYPE_EXECUTOR} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";

contract SessionKeyValidatorTest is BaseTest {
    SmartAccount internal acc;
    Target internal target;
    MockERC20 internal token;
    uint256 internal skKey = 0x5E55;
    address internal sk;
    bytes32 internal sid;

    function setUp() public {
        _etchEntryPoint();
        _deploySystem(address(0xE5C));
        acc = _createAccount(_fullInitData(owner, new address[](0)), 0);
        vm.deal(address(acc), 10 ether);
        target = new Target();
        token = new MockERC20();
        token.mint(address(acc), 1000);
        sk = vm.addr(skKey);
        sid = _enable(_cfg(0, 0, 0, 1 ether));
    }

    function _cfg(uint48 after_, uint48 until_, uint32 maxUses, uint128 nativeCap)
        internal
        view
        returns (SessionKeyValidator.SessionConfig memory c)
    {
        c.sessionKey = sk;
        c.validAfter = after_;
        c.validUntil = until_;
        c.maxUses = maxUses;
        c.nativeCap = nativeCap;
        c.salt = keccak256(abi.encode(after_, until_, maxUses, nativeCap, block.timestamp));
        c.permissions = new SessionKeyValidator.Permission[](4);
        c.permissions[0] = SessionKeyValidator.Permission(address(target), Target.setValue.selector);
        c.permissions[1] = SessionKeyValidator.Permission(address(token), token.transfer.selector);
        c.permissions[2] = SessionKeyValidator.Permission(address(0xB0B), bytes4(0));
        c.permissions[3] = SessionKeyValidator.Permission(address(token), token.approve.selector);
        c.tokenCaps = new SessionKeyValidator.TokenCap[](1);
        c.tokenCaps[0] = SessionKeyValidator.TokenCap(address(token), 100);
    }

    function _enable(SessionKeyValidator.SessionConfig memory c) internal returns (bytes32 id) {
        id = sessions.sessionIdOf(address(acc), c.sessionKey, c.salt);
        _ownerCall(acc, address(sessions), abi.encodeCall(SessionKeyValidator.enableSession, (c)));
    }

    function _sessionOp(bytes memory callData) internal view returns (PackedUserOperation memory) {
        return _signSession(_userOp(address(acc), address(sessions), "", callData), skKey, sid);
    }

    function _expectFail(PackedUserOperation memory op, string memory reason) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, reason));
        EP.handleOps(ops, beneficiary);
    }

    // ---------------------------------------------------------------- happy paths
    function test_sessionOp_allowedCall() public {
        _handle(_sessionOp(_single(address(target), 0, abi.encodeCall(Target.setValue, (77)))));
        assertEq(target.value(), 77);
        assertEq(sessions.getSession(address(acc), sid).uses, 1);
    }

    function test_sessionOp_batchWithValueAndToken() public {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(address(0xB0B), 0.3 ether, "");
        calls[1] = Execution(address(token), 0, abi.encodeCall(token.transfer, (address(0xB0B), 60)));
        _handle(_sessionOp(_batch(calls)));
        assertEq(address(0xB0B).balance, 0.3 ether);
        assertEq(token.balanceOf(address(0xB0B)), 60);
        assertEq(sessions.getSession(address(acc), sid).nativeSpent, 0.3 ether);
        assertEq(sessions.tokenUsage(address(acc), sid, address(token)).spent, 60);
    }

    // ---------------------------------------------------------------- policy failures
    function test_disallowedSelector() public {
        _expectFail(_sessionOp(_single(address(target), 0, abi.encodeCall(Target.fail, ()))), "AA24 signature error");
    }

    function test_disallowedTarget_inBatch() public {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(address(target), 0, abi.encodeCall(Target.setValue, (1)));
        calls[1] = Execution(address(0xDEAD), 0, "");
        _expectFail(_sessionOp(_batch(calls)), "AA24 signature error");
    }

    function test_nativeCapExceeded() public {
        _expectFail(_sessionOp(_single(address(0xB0B), 1 ether + 1, "")), "AA24 signature error");
    }

    function test_tokenCapExceeded_andApproveCounted() public {
        _handle(_sessionOp(_single(address(token), 0, abi.encodeCall(token.approve, (address(0xB0B), 90)))));
        _expectFail(
            _sessionOp(_single(address(token), 0, abi.encodeCall(token.transfer, (address(0xB0B), 11)))),
            "AA24 signature error"
        );
    }

    function test_tokenSelectorWithoutCap_rejected() public {
        SessionKeyValidator.SessionConfig memory c = _cfg(0, 0, 0, 0);
        c.salt = bytes32(uint256(1));
        c.tokenCaps = new SessionKeyValidator.TokenCap[](0);
        sid = _enable(c);
        _expectFail(
            _sessionOp(_single(address(token), 0, abi.encodeCall(token.transfer, (address(0xB0B), 1)))),
            "AA24 signature error"
        );
    }

    function test_maxUses() public {
        SessionKeyValidator.SessionConfig memory c = _cfg(0, 0, 1, 0);
        sid = _enable(c);
        _handle(_sessionOp(_single(address(target), 0, abi.encodeCall(Target.setValue, (1)))));
        _expectFail(
            _sessionOp(_single(address(target), 0, abi.encodeCall(Target.setValue, (2)))), "AA24 signature error"
        );
    }

    function test_expiry_enforcedByEntryPoint() public {
        vm.warp(1000);
        sid = _enable(_cfg(1100, 1200, 0, 0));
        _expectFail(
            _sessionOp(_single(address(target), 0, abi.encodeCall(Target.setValue, (1)))), "AA22 expired or not due"
        );
        vm.warp(1150);
        _handle(_sessionOp(_single(address(target), 0, abi.encodeCall(Target.setValue, (1)))));
        vm.warp(1201);
        _expectFail(
            _sessionOp(_single(address(target), 0, abi.encodeCall(Target.setValue, (2)))), "AA22 expired or not due"
        );
    }

    function test_revoke() public {
        _ownerCall(acc, address(sessions), abi.encodeCall(SessionKeyValidator.revokeSession, (sid)));
        _expectFail(
            _sessionOp(_single(address(target), 0, abi.encodeCall(Target.setValue, (1)))), "AA24 signature error"
        );
        vm.prank(address(acc));
        vm.expectRevert(SessionKeyValidator.UnknownSession.selector);
        sessions.revokeSession(bytes32(uint256(123)));
    }

    function test_wrongSessionSigner() public {
        PackedUserOperation memory op = _userOp(
            address(acc), address(sessions), "", _single(address(target), 0, abi.encodeCall(Target.setValue, (1)))
        );
        _expectFail(_signSession(op, 0xBAD, sid), "AA24 signature error");
        op.signature = hex"00";
        _expectFail(op, "AA24 signature error");
    }

    function test_badModes_rejected() public {
        bytes memory data = abi.encodePacked(address(target), uint256(0), abi.encodeCall(Target.setValue, (1)));
        // try exec type
        _expectFail(
            _sessionOp(abi.encodeCall(acc.execute, (bytes32(uint256(0x01) << 240), data))), "AA24 signature error"
        );
        // delegatecall call type
        _expectFail(
            _sessionOp(abi.encodeCall(acc.execute, (bytes32(uint256(0xff) << 248), data))), "AA24 signature error"
        );
        // non-zero mode selector
        _expectFail(_sessionOp(abi.encodeCall(acc.execute, (bytes32(uint256(1) << 200), data))), "AA24 signature error");
        // not execute()
        _expectFail(_sessionOp(abi.encodeCall(acc.installModule, (1, address(0), ""))), "AA24 signature error");
        _expectFail(_sessionOp(hex"00"), "AA24 signature error");
        // short calldata (1..3 bytes) on allowed target
        _expectFail(_sessionOp(_single(address(0xB0B), 0, hex"01")), "AA24 signature error");
        // malformed ERC-20 calldata
        _expectFail(
            _sessionOp(_single(address(token), 0, abi.encodePacked(token.transfer.selector))), "AA24 signature error"
        );
    }

    function test_enable_guards() public {
        SessionKeyValidator.SessionConfig memory c = _cfg(0, 0, 0, 0);
        vm.startPrank(address(acc));
        vm.expectRevert(SessionKeyValidator.SessionExists.selector);
        sessions.enableSession(_cfg(0, 0, 0, 1 ether));
        c.salt = bytes32(uint256(5));
        c.sessionKey = address(0);
        vm.expectRevert(SessionKeyValidator.InvalidSession.selector);
        sessions.enableSession(c);
        c.sessionKey = sk;
        c.validAfter = 10;
        c.validUntil = 5;
        vm.expectRevert(SessionKeyValidator.InvalidSession.selector);
        sessions.enableSession(c);
        c.validUntil = 0;
        c.permissions[0].target = address(acc);
        vm.expectRevert(SessionKeyValidator.InvalidSession.selector);
        sessions.enableSession(c);
        vm.stopPrank();
        vm.prank(address(0x1234));
        vm.expectRevert(SessionKeyValidator.NotInstalled.selector);
        sessions.enableSession(c);
    }

    function test_uninstall_wipesSessions_and_reinstallWithConfig() public {
        assertTrue(sessions.isAllowed(address(acc), sid, address(target), Target.setValue.selector));
        _ownerCall(
            acc, address(acc), abi.encodeCall(acc.uninstallModule, (MODULE_TYPE_VALIDATOR, address(sessions), ""))
        );
        assertFalse(sessions.installed(address(acc)));
        bytes memory init = abi.encode(_cfg(0, 0, 0, 0));
        _ownerCall(
            acc, address(acc), abi.encodeCall(acc.installModule, (MODULE_TYPE_VALIDATOR, address(sessions), init))
        );
        // old session is dead even though storage remains
        _expectFail(
            _sessionOp(_single(address(target), 0, abi.encodeCall(Target.setValue, (1)))), "AA24 signature error"
        );
    }

    function test_misc_views() public view {
        assertTrue(sessions.isModuleType(MODULE_TYPE_VALIDATOR));
        assertFalse(sessions.isModuleType(MODULE_TYPE_EXECUTOR));
        assertEq(sessions.isValidSignatureWithSender(address(0), bytes32(0), ""), bytes4(0xffffffff));
    }

    // ---------------------------------------------------------------- fuzz
    function testFuzz_targetSelectorAllowlist(address t, bytes4 sel) public {
        vm.assume(t != address(target) && t != address(token) && t != address(0xB0B));
        vm.assume(uint160(t) > 0x1000 && t != address(acc) && t != address(sessions) && t != EP_ADDR);
        _expectFail(_sessionOp(_single(t, 0, abi.encodePacked(sel, uint256(1)))), "AA24 signature error");
    }

    function testFuzz_nativeCapAccumulation(uint96 a, uint96 b) public {
        uint256 x = bound(a, 0, 2 ether);
        uint256 y = bound(b, 0, 2 ether);
        if (x <= 1 ether) {
            _handle(_sessionOp(_single(address(0xB0B), x, "")));
            if (x + y <= 1 ether) {
                _handle(_sessionOp(_single(address(0xB0B), y, "")));
            } else {
                _expectFail(_sessionOp(_single(address(0xB0B), y, "")), "AA24 signature error");
            }
        } else {
            _expectFail(_sessionOp(_single(address(0xB0B), x, "")), "AA24 signature error");
        }
        assertLe(sessions.getSession(address(acc), sid).nativeSpent, 1 ether);
    }

    function testFuzz_timeWindow(uint48 after_, uint48 len, uint48 now_) public {
        after_ = uint48(bound(after_, 1, 1e10));
        len = uint48(bound(len, 1, 1e8));
        now_ = uint48(bound(now_, 1, 1e10 + 2e8));
        vm.warp(1);
        sid = _enable(_cfg(after_, after_ + len, 0, 0));
        vm.warp(now_);
        PackedUserOperation memory op = _sessionOp(_single(address(target), 0, abi.encodeCall(Target.setValue, (1))));
        // EntryPoint v0.7: valid iff validAfter <= now <= validUntil
        if (now_ >= after_ && now_ <= after_ + len) {
            _handle(op);
            assertEq(target.value(), 1);
        } else {
            _expectFail(op, "AA22 expired or not due");
        }
    }
}
