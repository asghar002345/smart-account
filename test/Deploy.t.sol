// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {ECDSAOwnerValidator} from "../src/modules/ECDSAOwnerValidator.sol";
import {SessionKeyValidator} from "../src/modules/SessionKeyValidator.sol";
import {RecoveryExecutor} from "../src/modules/RecoveryExecutor.sol";
import {EscrowExecutor} from "../src/modules/EscrowExecutor.sol";

/// @notice Simulates the deploy script in-memory on a Base Sepolia fork with a throwaway key. Nothing is broadcast.
contract DeployScriptTest is Test {
    function test_deployScript_simulated() public {
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://sepolia.base.org")), 51_235_699);
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(0xD3)));
        vm.deal(vm.addr(0xD3), 1 ether);
        (AccountFactory f,,, RecoveryExecutor r, EscrowExecutor e) = new Deploy().run();
        assertEq(f.owner(), vm.addr(0xD3));
        assertGt(f.implementation().code.length, 0);
        assertEq(address(e.escrow()), 0xD861488f2ba02df4047DDE41EFeCdCEd1FD6E528);
        assertGt(address(r.validator()).code.length, 0);
    }

    function test_deployScript_wrongChain_reverts() public {
        Deploy d = new Deploy();
        vm.expectRevert("Deploy: Base Sepolia only");
        d.run();
    }
}
