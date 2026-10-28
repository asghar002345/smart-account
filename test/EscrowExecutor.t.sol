// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseTest} from "./utils/BaseTest.sol";
import {MockEscrow} from "./utils/Mocks.sol";
import {SmartAccount} from "../src/SmartAccount.sol";
import {EscrowExecutor} from "../src/modules/EscrowExecutor.sol";
import {IMilestoneEscrow} from "../src/interfaces/IMilestoneEscrow.sol";
import {MODULE_TYPE_VALIDATOR, MODULE_TYPE_EXECUTOR} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";

contract EscrowExecutorTest is BaseTest {
    SmartAccount internal acc;
    MockEscrow internal esc;
    address internal operator = address(0x0FE2);

    function setUp() public {
        _etchEntryPoint();
        esc = new MockEscrow();
        _deploySystem(address(esc));
        address[] memory ops = new address[](1);
        ops[0] = operator;
        acc = _createAccount(_fullInitData(owner, ops), 0);
        vm.deal(address(acc), 1 ether);
        uint128[] memory a = new uint128[](2);
        a[0] = 100;
        a[1] = 50;
        esc.setMilestones(1, a);
    }

    function test_operatorProviderActions() public {
        vm.startPrank(operator);
        escrowExec.submitMilestone(address(acc), 1, 0);
        assertEq(esc.lastCaller(), address(acc));
        assertEq(esc.lastSelector(), IMilestoneEscrow.submitMilestone.selector);
        escrowExec.claimAfterReview(address(acc), 1, 0);
        assertEq(esc.lastSelector(), IMilestoneEscrow.claimAfterReview.selector);
        escrowExec.withdraw(address(acc), address(0));
        assertEq(esc.lastSelector(), IMilestoneEscrow.withdraw.selector);
        vm.stopPrank();
        assertEq(address(acc).balance, 1 ether);
    }

    function test_nonOperator_reverts() public {
        vm.expectRevert(EscrowExecutor.NotOperator.selector);
        escrowExec.submitMilestone(address(acc), 1, 0);
        vm.prank(operator);
        vm.expectRevert(EscrowExecutor.NotInstalled.selector);
        escrowExec.submitMilestone(address(0x1234), 1, 0);
    }

    function test_approve_requiresWhitelist_andCap() public {
        vm.prank(operator);
        vm.expectRevert(EscrowExecutor.NotApprovable.selector);
        escrowExec.approveMilestone(address(acc), 1, 0);
        vm.prank(address(acc));
        escrowExec.setApprovable(1, true, 120);
        vm.startPrank(operator);
        escrowExec.approveMilestone(address(acc), 1, 0);
        assertEq(esc.lastSelector(), IMilestoneEscrow.approveMilestone.selector);
        vm.expectRevert(EscrowExecutor.CapExceeded.selector);
        escrowExec.approveMilestone(address(acc), 1, 1);
        vm.stopPrank();
        assertEq(escrowExec.allowance(address(acc), 1).used, 100);
        // uncapped
        vm.prank(address(acc));
        escrowExec.setApprovable(2, true, 0);
        vm.prank(operator);
        escrowExec.approveMilestone(address(acc), 2, 9);
    }

    function test_cap_outOfRangeIndexCountsZero() public {
        vm.prank(address(acc));
        escrowExec.setApprovable(1, true, 1);
        vm.prank(operator);
        escrowExec.approveMilestone(address(acc), 1, 99);
        assertEq(escrowExec.allowance(address(acc), 1).used, 0);
    }

    function test_setOperator_and_uninstall() public {
        vm.prank(address(acc));
        escrowExec.setOperator(operator, false);
        assertFalse(escrowExec.isOperator(address(acc), operator));
        vm.prank(address(0x1234));
        vm.expectRevert(EscrowExecutor.NotInstalled.selector);
        escrowExec.setOperator(operator, true);
        vm.prank(address(0x1234));
        vm.expectRevert(EscrowExecutor.NotInstalled.selector);
        escrowExec.setApprovable(1, true, 0);

        vm.prank(address(acc));
        escrowExec.setOperator(operator, true);
        _ownerCall(
            acc, address(acc), abi.encodeCall(acc.uninstallModule, (MODULE_TYPE_EXECUTOR, address(escrowExec), ""))
        );
        _ownerCall(
            acc, address(acc), abi.encodeCall(acc.installModule, (MODULE_TYPE_EXECUTOR, address(escrowExec), ""))
        );
        assertFalse(escrowExec.isOperator(address(acc), operator)); // wiped by epoch bump
    }

    function test_misc() public {
        assertTrue(escrowExec.isModuleType(MODULE_TYPE_EXECUTOR));
        assertFalse(escrowExec.isModuleType(MODULE_TYPE_VALIDATOR));
        assertEq(address(escrowExec.escrow()), address(esc));
        vm.expectRevert(EscrowExecutor.ZeroAddress.selector);
        new EscrowExecutor(IMilestoneEscrow(address(0)));
    }
}
