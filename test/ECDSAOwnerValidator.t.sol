// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseTest} from "./utils/BaseTest.sol";
import {ECDSAOwnerValidator} from "../src/modules/ECDSAOwnerValidator.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MODULE_TYPE_VALIDATOR, MODULE_TYPE_EXECUTOR} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";

contract ECDSAOwnerValidatorTest is BaseTest {
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    address internal acct = address(0xACC);

    function setUp() public {
        ecdsa = new ECDSAOwnerValidator();
        owner = vm.addr(ownerKey);
        vm.prank(acct);
        ecdsa.onInstall(abi.encode(owner));
    }

    function _op(bytes memory sig) internal view returns (PackedUserOperation memory op) {
        op.sender = acct;
        op.signature = sig;
    }

    function test_moduleType() public view {
        assertTrue(ecdsa.isModuleType(MODULE_TYPE_VALIDATOR));
        assertFalse(ecdsa.isModuleType(MODULE_TYPE_EXECUTOR));
    }

    function test_install_guards() public {
        vm.prank(acct);
        vm.expectRevert(ECDSAOwnerValidator.AlreadyInstalled.selector);
        ecdsa.onInstall(abi.encode(owner));
        vm.prank(address(0x1));
        vm.expectRevert(ECDSAOwnerValidator.InvalidOwner.selector);
        ecdsa.onInstall(abi.encode(address(0)));
        vm.prank(address(0x1));
        vm.expectRevert(ECDSAOwnerValidator.InvalidOwner.selector);
        ecdsa.onInstall(abi.encode(address(0x1)));
    }

    function test_validate_personalSign() public {
        bytes32 h = keccak256("op");
        vm.prank(acct);
        assertEq(ecdsa.validateUserOp(_op(_personalSign(ownerKey, h)), h), 0);
        vm.prank(acct);
        assertEq(ecdsa.validateUserOp(_op(_personalSign(0xBAD, h)), h), 1);
        // raw (non EIP-191) signature rejected
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, h);
        vm.prank(acct);
        assertEq(ecdsa.validateUserOp(_op(abi.encodePacked(r, s, v)), h), 1);
        // wrong length
        vm.prank(acct);
        assertEq(ecdsa.validateUserOp(_op(hex"1234"), h), 1);
        // not installed account
        vm.prank(address(0x999));
        assertEq(ecdsa.validateUserOp(_op(_personalSign(ownerKey, h)), h), 1);
    }

    function testFuzz_highS_rejected(bytes32 h) public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, MessageHashUtils.toEthSignedMessageHash(h));
        bytes32 s2 = bytes32(N - uint256(s));
        uint8 v2 = v == 27 ? 28 : 27;
        vm.prank(acct);
        assertEq(ecdsa.validateUserOp(_op(abi.encodePacked(r, s2, v2)), h), 1);
        vm.prank(acct);
        assertEq(ecdsa.validateUserOp(_op(abi.encodePacked(r, s, v)), h), 0);
    }

    function testFuzz_randomSigner_rejected(uint256 key, bytes32 h) public {
        key = bound(key, 1, N - 1);
        vm.assume(key != ownerKey);
        vm.prank(acct);
        assertEq(ecdsa.validateUserOp(_op(_personalSign(key, h)), h), 1);
    }

    function test_rotate_and_uninstall() public {
        vm.prank(address(0x777));
        vm.expectRevert(ECDSAOwnerValidator.NotInstalled.selector);
        ecdsa.rotateOwner(address(0x2));
        vm.prank(acct);
        ecdsa.rotateOwner(address(0x2));
        assertEq(ecdsa.ownerOf(acct), address(0x2));
        vm.prank(acct);
        ecdsa.onUninstall("");
        assertEq(ecdsa.ownerOf(acct), address(0));
        vm.prank(acct);
        assertEq(ecdsa.isValidSignatureWithSender(address(0), bytes32(0), ""), bytes4(0xffffffff));
    }
}
