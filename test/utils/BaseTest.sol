// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {PackedUserOperation, IEntryPoint} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {Execution} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {
    MODULE_TYPE_VALIDATOR,
    MODULE_TYPE_EXECUTOR,
    IERC7579Execution
} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SmartAccount} from "../../src/SmartAccount.sol";
import {AccountFactory} from "../../src/AccountFactory.sol";
import {ECDSAOwnerValidator} from "../../src/modules/ECDSAOwnerValidator.sol";
import {SessionKeyValidator} from "../../src/modules/SessionKeyValidator.sol";
import {RecoveryExecutor} from "../../src/modules/RecoveryExecutor.sol";
import {EscrowExecutor} from "../../src/modules/EscrowExecutor.sol";
import {IMilestoneEscrow} from "../../src/interfaces/IMilestoneEscrow.sol";

interface IEntryPointV07 is IEntryPoint {
    function getUserOpHash(PackedUserOperation calldata userOp) external view returns (bytes32);
    function senderCreator() external view returns (address);
}

/// @dev Shared fixture. Unit tests etch the real EntryPoint v0.7 runtime bytecode (fetched from Base Sepolia,
///      see test/fixtures) at the canonical address; fork tests use the live contract instead.
abstract contract BaseTest is Test {
    address internal constant EP_ADDR = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address internal constant SENDER_CREATOR = 0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C;
    address internal constant ESCROW_ADDR = 0xD861488f2ba02df4047DDE41EFeCdCEd1FD6E528;
    IEntryPointV07 internal constant EP = IEntryPointV07(EP_ADDR);

    AccountFactory internal factory;
    ECDSAOwnerValidator internal ecdsa;
    SessionKeyValidator internal sessions;
    RecoveryExecutor internal recovery;
    EscrowExecutor internal escrowExec;

    uint256 internal ownerKey = 0xA11CE;
    address internal owner;
    address payable internal beneficiary = payable(address(0xBEEF));
    uint256 internal g1Key = 0x6001;
    uint256 internal g2Key = 0x6002;
    uint256 internal g3Key = 0x6003;
    address internal g1;
    address internal g2;
    address internal g3;

    function _etchEntryPoint() internal {
        vm.etch(EP_ADDR, vm.parseBytes(vm.trim(vm.readFile("test/fixtures/EntryPointV07.hex"))));
        vm.etch(SENDER_CREATOR, vm.parseBytes(vm.trim(vm.readFile("test/fixtures/SenderCreatorV07.hex"))));
    }

    function _deploySystem(address escrowAddr) internal {
        owner = vm.addr(ownerKey);
        g1 = vm.addr(g1Key);
        g2 = vm.addr(g2Key);
        g3 = vm.addr(g3Key);
        factory = new AccountFactory(address(this));
        ecdsa = new ECDSAOwnerValidator();
        sessions = new SessionKeyValidator();
        recovery = new RecoveryExecutor(ecdsa);
        escrowExec = new EscrowExecutor(IMilestoneEscrow(escrowAddr));
    }

    // ---------------------------------------------------------------- init data
    function _initData(address owner_) internal view returns (bytes memory) {
        SmartAccount.ModuleInit[] memory m = new SmartAccount.ModuleInit[](1);
        m[0] = SmartAccount.ModuleInit(MODULE_TYPE_VALIDATOR, address(ecdsa), abi.encode(owner_));
        return abi.encodeCall(SmartAccount.initialize, (m));
    }

    function _fullInitData(address owner_, address[] memory operators) internal view returns (bytes memory) {
        address[] memory gs = new address[](3);
        gs[0] = g1;
        gs[1] = g2;
        gs[2] = g3;
        SmartAccount.ModuleInit[] memory m = new SmartAccount.ModuleInit[](4);
        m[0] = SmartAccount.ModuleInit(MODULE_TYPE_VALIDATOR, address(ecdsa), abi.encode(owner_));
        m[1] = SmartAccount.ModuleInit(MODULE_TYPE_VALIDATOR, address(sessions), "");
        m[2] = SmartAccount.ModuleInit(MODULE_TYPE_EXECUTOR, address(recovery), abi.encode(gs, uint8(2), uint32(0)));
        m[3] = SmartAccount.ModuleInit(MODULE_TYPE_EXECUTOR, address(escrowExec), abi.encode(operators));
        return abi.encodeCall(SmartAccount.initialize, (m));
    }

    function _createAccount(bytes memory initData, bytes32 salt) internal returns (SmartAccount) {
        return SmartAccount(payable(factory.createAccount(initData, salt)));
    }

    // ---------------------------------------------------------------- calldata
    function _single(address target, uint256 value, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC7579Execution.execute, (bytes32(0), abi.encodePacked(target, value, data)));
    }

    function _batch(Execution[] memory calls) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC7579Execution.execute, (bytes32(uint256(0x01) << 248), abi.encode(calls)));
    }

    // ---------------------------------------------------------------- userops
    function _nonceKey(address validator) internal pure returns (uint192) {
        return uint192(uint160(validator)) << 32;
    }

    function _userOp(address sender, address validator, bytes memory initCode, bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = sender;
        op.nonce = EP.getNonce(sender, _nonceKey(validator));
        op.initCode = initCode;
        op.callData = callData;
        op.accountGasLimits = bytes32((uint256(1_000_000) << 128) | uint256(1_000_000));
        op.preVerificationGas = 60_000;
        op.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(2 gwei));
    }

    function _personalSign(uint256 key, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(hash));
        return abi.encodePacked(r, s, v);
    }

    function _signOwner(PackedUserOperation memory op, uint256 key) internal view returns (PackedUserOperation memory) {
        op.signature = _personalSign(key, EP.getUserOpHash(op));
        return op;
    }

    function _signSession(PackedUserOperation memory op, uint256 key, bytes32 sessionId)
        internal
        view
        returns (PackedUserOperation memory)
    {
        op.signature = abi.encodePacked(sessionId, _personalSign(key, EP.getUserOpHash(op)));
        return op;
    }

    function _handle(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.recordLogs();
        EP.handleOps(ops, beneficiary);
        // EntryPoint does not revert when execution fails: assert UserOperationEvent.success == true
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == EP_ADDR && logs[i].topics[0] == topic) {
                (, bool success,,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                assertTrue(success, "userOp execution failed");
                found = true;
            }
        }
        assertTrue(found, "no UserOperationEvent");
    }

    /// @dev Executes `callData` from the account through a real owner-signed userOp.
    function _ownerExec(SmartAccount acc, bytes memory callData) internal {
        _handle(_signOwner(_userOp(address(acc), address(ecdsa), "", callData), ownerKey));
    }

    function _ownerCall(SmartAccount acc, address target, bytes memory data) internal {
        _ownerExec(acc, _single(target, 0, data));
    }
}
