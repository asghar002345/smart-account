// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {ECDSAOwnerValidator} from "../src/modules/ECDSAOwnerValidator.sol";
import {SessionKeyValidator} from "../src/modules/SessionKeyValidator.sol";
import {RecoveryExecutor} from "../src/modules/RecoveryExecutor.sol";
import {EscrowExecutor} from "../src/modules/EscrowExecutor.sol";
import {IMilestoneEscrow} from "../src/interfaces/IMilestoneEscrow.sol";

/// @notice Deploys factory (+ account implementation) and all modules to Base Sepolia.
///         Reads PRIVATE_KEY from the environment. NOT executed by this repo's tooling — dry-run with
///         `forge script script/Deploy.s.sol --rpc-url base_sepolia` (no --broadcast) until a deploy is approved.
contract Deploy is Script {
    address internal constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address internal constant MILESTONE_ESCROW = 0xD861488f2ba02df4047DDE41EFeCdCEd1FD6E528;
    uint256 internal constant BASE_SEPOLIA = 84532;

    function run()
        external
        returns (
            AccountFactory factory,
            ECDSAOwnerValidator ecdsa,
            SessionKeyValidator sessions,
            RecoveryExecutor recovery,
            EscrowExecutor escrowExec
        )
    {
        require(block.chainid == BASE_SEPOLIA, "Deploy: Base Sepolia only");
        require(ENTRY_POINT_V07.code.length != 0, "Deploy: EntryPoint v0.7 missing");
        require(MILESTONE_ESCROW.code.length != 0, "Deploy: MilestoneEscrow missing");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        factory = new AccountFactory(deployer);
        ecdsa = new ECDSAOwnerValidator();
        sessions = new SessionKeyValidator();
        recovery = new RecoveryExecutor(ecdsa);
        escrowExec = new EscrowExecutor(IMilestoneEscrow(MILESTONE_ESCROW));
        vm.stopBroadcast();

        console2.log("AccountFactory      ", address(factory));
        console2.log("SmartAccount impl   ", factory.implementation());
        console2.log("ECDSAOwnerValidator ", address(ecdsa));
        console2.log("SessionKeyValidator ", address(sessions));
        console2.log("RecoveryExecutor    ", address(recovery));
        console2.log("EscrowExecutor      ", address(escrowExec));
        console2.log("NOTE: stake the factory (addStake) before bundler use; see README.");
    }
}
