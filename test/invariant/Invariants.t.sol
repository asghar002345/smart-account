// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseTest} from "../utils/BaseTest.sol";
import {MockEscrow, MockERC20, Target} from "../utils/Mocks.sol";
import {SmartAccount} from "../../src/SmartAccount.sol";
import {AccountFactory} from "../../src/AccountFactory.sol";
import {ECDSAOwnerValidator} from "../../src/modules/ECDSAOwnerValidator.sol";
import {SessionKeyValidator} from "../../src/modules/SessionKeyValidator.sol";
import {RecoveryExecutor} from "../../src/modules/RecoveryExecutor.sol";
import {EscrowExecutor} from "../../src/modules/EscrowExecutor.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";

contract Handler is BaseTest {
    SmartAccount public acc;
    Target public target;
    MockERC20 public token;
    MockEscrow public esc;
    bytes32 public sid;
    uint256 internal skKey = 0x5E55;
    address internal operator = address(0x0FE2);
    uint256 public currentOwnerKey;
    address public ghostOwner;
    uint128 public constant NATIVE_CAP = 1 ether;
    uint128 public constant TOKEN_CAP = 500;
    uint256 public ghostUnauthorizedExec;
    uint256 public ghostEscrowValueMoved;
    bytes[] internal _inits;
    bytes32[] internal _salts;
    address[] internal _created;

    constructor() {
        _etchEntryPoint();
        esc = new MockEscrow();
        _deploySystem(address(esc));
        address[] memory ops = new address[](1);
        ops[0] = operator;
        acc = _createAccount(_fullInitData(owner, ops), 0);
        vm.deal(address(acc), 100 ether);
        target = new Target();
        token = new MockERC20();
        token.mint(address(acc), 1e24);
        currentOwnerKey = ownerKey;
        ghostOwner = owner;

        SessionKeyValidator.SessionConfig memory c;
        c.sessionKey = vm.addr(skKey);
        c.nativeCap = NATIVE_CAP;
        c.permissions = new SessionKeyValidator.Permission[](3);
        c.permissions[0] = SessionKeyValidator.Permission(address(0xB0B), bytes4(0));
        c.permissions[1] = SessionKeyValidator.Permission(address(token), token.transfer.selector);
        c.permissions[2] = SessionKeyValidator.Permission(address(target), Target.setValue.selector);
        c.tokenCaps = new SessionKeyValidator.TokenCap[](1);
        c.tokenCaps[0] = SessionKeyValidator.TokenCap(address(token), TOKEN_CAP);
        sid = sessions.sessionIdOf(address(acc), c.sessionKey, c.salt);
        _ownerCall(acc, address(sessions), abi.encodeCall(SessionKeyValidator.enableSession, (c)));
    }

    function system()
        external
        view
        returns (AccountFactory, ECDSAOwnerValidator, SessionKeyValidator, RecoveryExecutor, EscrowExecutor)
    {
        return (factory, ecdsa, sessions, recovery, escrowExec);
    }

    function _try(PackedUserOperation memory op) internal returns (bool ok) {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        try EP.handleOps(ops, beneficiary) {
            ok = true;
        } catch {}
    }

    // ---- session spending (I2)
    function sessionSendEth(uint256 amount) external {
        amount = bound(amount, 0, 0.6 ether);
        _try(
            _signSession(_userOp(address(acc), address(sessions), "", _single(address(0xB0B), amount, "")), skKey, sid)
        );
    }

    function sessionSendToken(uint256 amount) external {
        amount = bound(amount, 0, 300);
        bytes memory cd = _single(address(token), 0, abi.encodeCall(token.transfer, (address(0xB0B), amount)));
        _try(_signSession(_userOp(address(acc), address(sessions), "", cd), skKey, sid));
    }

    function sessionTryRotateOwner(address newOwner) external {
        // session key attempting to rotate the owner must never succeed (I1)
        bytes memory cd = _single(address(ecdsa), 0, abi.encodeCall(ECDSAOwnerValidator.rotateOwner, (newOwner)));
        _try(_signSession(_userOp(address(acc), address(sessions), "", cd), skKey, sid));
    }

    // ---- owner rotation via owner-validated op (I1)
    function ownerRotate(uint256 newKey) external {
        newKey = bound(newKey, 1, 1e30);
        address n = vm.addr(newKey);
        if (n == address(acc)) return;
        bytes memory cd = _single(address(ecdsa), 0, abi.encodeCall(ECDSAOwnerValidator.rotateOwner, (n)));
        if (_try(_signOwner(_userOp(address(acc), address(ecdsa), "", cd), currentOwnerKey))) {
            currentOwnerKey = newKey;
            ghostOwner = n;
        }
    }

    function strangerRotate(uint256 key, address n) external {
        key = bound(key, 1, 1e30);
        if (key == currentOwnerKey) return;
        bytes memory cd = _single(address(ecdsa), 0, abi.encodeCall(ECDSAOwnerValidator.rotateOwner, (n)));
        _try(_signOwner(_userOp(address(acc), address(ecdsa), "", cd), key));
    }

    // ---- recovery (I1)
    function recoveryFlow(uint256 newKey, uint256 dt, bool cancel) external {
        newKey = bound(newKey, 1, 1e30);
        address n = vm.addr(newKey);
        if (recovery.getRequest(address(acc)).newOwner != address(0)) return;
        vm.prank(g1);
        recovery.proposeRecovery(address(acc), n);
        vm.prank(g2);
        recovery.approveRecovery(address(acc));
        if (cancel) {
            vm.prank(address(acc));
            recovery.cancelRecovery();
        }
        vm.warp(block.timestamp + bound(dt, 0, 72 hours));
        try recovery.executeRecovery(address(acc)) {
            currentOwnerKey = newKey;
            ghostOwner = n;
        } catch {
            if (!cancel) {
                vm.prank(address(acc));
                recovery.cancelRecovery();
            }
        }
    }

    // ---- unauthorized executors (I3)
    function strangerExecuteFromExecutor(address caller, uint256 v) external {
        if (caller == address(recovery) || caller == address(escrowExec) || caller == EP_ADDR) return;
        vm.prank(caller);
        try acc.executeFromExecutor(
            bytes32(0), abi.encodePacked(address(target), uint256(0), abi.encodeCall(Target.setValue, (v)))
        ) {
            ++ghostUnauthorizedExec;
        } catch {}
    }

    // ---- escrow executor never moves value (I5)
    function escrowOps(uint8 which, uint256 id, uint256 idx, bool asOperator) external {
        uint256 balBefore = address(acc).balance;
        uint256 tokBefore = token.balanceOf(address(acc));
        vm.startPrank(asOperator ? operator : address(0xBAD));
        which = which % 3;
        if (which == 0) {
            try escrowExec.submitMilestone(address(acc), id, idx) {} catch {}
        } else if (which == 1) {
            try escrowExec.claimAfterReview(address(acc), id, idx) {} catch {}
        } else {
            try escrowExec.withdraw(address(acc), address(token)) {} catch {}
        }
        vm.stopPrank();
        if (address(acc).balance != balBefore || token.balanceOf(address(acc)) != tokBefore) ++ghostEscrowValueMoved;
    }

    // ---- factory determinism (I4)
    function create(address o, bytes32 salt) external {
        if (o == address(0) || uint160(o) < 0x100) return;
        bytes memory init = _initData(o);
        address a = factory.createAccount(init, salt);
        _inits.push(init);
        _salts.push(salt);
        _created.push(a);
    }

    function createdCount() external view returns (uint256) {
        return _created.length;
    }

    function created(uint256 i) external view returns (bytes memory, bytes32, address) {
        return (_inits[i], _salts[i], _created[i]);
    }
}

contract InvariantsTest is BaseTest {
    Handler internal h;

    function setUp() public {
        h = new Handler();
        (factory, ecdsa, sessions, recovery, escrowExec) = h.system();
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](9);
        sel[0] = Handler.sessionSendEth.selector;
        sel[1] = Handler.sessionSendToken.selector;
        sel[2] = Handler.sessionTryRotateOwner.selector;
        sel[3] = Handler.ownerRotate.selector;
        sel[4] = Handler.strangerRotate.selector;
        sel[5] = Handler.recoveryFlow.selector;
        sel[6] = Handler.strangerExecuteFromExecutor.selector;
        sel[7] = Handler.escrowOps.selector;
        sel[8] = Handler.create.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    /// I1: owner only changes through owner-validated ops or completed recovery
    function invariant_I1_ownerChangesOnlyViaOwnerOrRecovery() public view {
        assertEq(ecdsa.ownerOf(address(h.acc())), h.ghostOwner());
    }

    /// I2: cumulative session spend never exceeds caps
    function invariant_I2_sessionSpendWithinCap() public view {
        address a = address(h.acc());
        assertLe(sessions.getSession(a, h.sid()).nativeSpent, h.NATIVE_CAP());
        assertLe(sessions.tokenUsage(a, h.sid(), address(h.token())).spent, h.TOKEN_CAP());
        assertLe(address(0xB0B).balance, h.NATIVE_CAP());
        assertLe(h.token().balanceOf(address(0xB0B)), h.TOKEN_CAP());
    }

    /// I3: no non-installed executor succeeds on executeFromExecutor
    function invariant_I3_onlyInstalledExecutors() public view {
        assertEq(h.ghostUnauthorizedExec(), 0);
    }

    /// I4: factory.getAddress matches every deployed account
    function invariant_I4_factoryDeterminism() public view {
        for (uint256 i; i < h.createdCount(); ++i) {
            (bytes memory init, bytes32 salt, address a) = h.created(i);
            assertEq(factory.getAddress(init, salt), a);
            assertGt(a.code.length, 0);
        }
    }

    /// I5: EscrowExecutor never moves value out of the account
    function invariant_I5_escrowExecutorMovesNoValue() public view {
        assertEq(h.ghostEscrowValueMoved(), 0);
    }
}
