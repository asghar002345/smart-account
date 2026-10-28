// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseTest} from "./utils/BaseTest.sol";
import {MockERC20, Target, MockHook, MockFallback} from "./utils/Mocks.sol";
import {SmartAccount} from "../src/SmartAccount.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {Execution} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {
    MODULE_TYPE_VALIDATOR,
    MODULE_TYPE_EXECUTOR,
    MODULE_TYPE_FALLBACK,
    MODULE_TYPE_HOOK
} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract NFT is ERC721("N", "N") {
    function mint(address to, uint256 id) external {
        _safeMint(to, id);
    }
}

contract SmartAccountTest is BaseTest {
    SmartAccount internal acc;
    Target internal target;

    function setUp() public {
        _etchEntryPoint();
        _deploySystem(address(0xE5C));
        acc = _createAccount(_initData(owner), 0);
        vm.deal(address(acc), 10 ether);
        target = new Target();
    }

    // ---------------------------------------------------------------- factory
    function test_factory_counterfactualAndIdempotent() public {
        bytes memory init = _initData(address(0x1234));
        address predicted = factory.getAddress(init, bytes32(uint256(7)));
        assertEq(predicted.code.length, 0);
        address a = factory.createAccount(init, bytes32(uint256(7)));
        assertEq(a, predicted);
        assertEq(factory.createAccount(init, bytes32(uint256(7))), a);
        assertEq(ecdsa.ownerOf(a), address(0x1234));
    }

    function test_factory_saltCommitsToOwner() public view {
        assertTrue(factory.getAddress(_initData(address(1)), 0) != factory.getAddress(_initData(address(2)), 0));
    }

    function test_factory_rejectsBadInitData() public {
        vm.expectRevert(AccountFactory.InvalidInitData.selector);
        factory.createAccount(hex"deadbeef", 0);
        vm.expectRevert(AccountFactory.InvalidInitData.selector);
        factory.createAccount(hex"00", 0);
    }

    function test_factory_requiresValidator() public {
        SmartAccount.ModuleInit[] memory m = new SmartAccount.ModuleInit[](0);
        vm.expectRevert(SmartAccount.NoValidator.selector);
        factory.createAccount(abi.encodeCall(SmartAccount.initialize, (m)), 0);
    }

    function test_factory_stakeOnlyOwner() public {
        vm.deal(address(this), 1 ether);
        factory.addStake{value: 0.1 ether}(1 days);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        factory.unlockStake();
        factory.unlockStake();
        vm.warp(block.timestamp + 1 days + 1);
        factory.withdrawStake(payable(address(0xCAFE)));
        assertEq(address(0xCAFE).balance, 0.1 ether);
    }

    function test_implementation_cannotBeInitialized() public {
        SmartAccount.ModuleInit[] memory m = new SmartAccount.ModuleInit[](0);
        SmartAccount impl = SmartAccount(payable(factory.implementation()));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(m);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        acc.initialize(m);
    }

    // ---------------------------------------------------------------- config
    function test_config() public view {
        assertEq(address(acc.entryPoint()), EP_ADDR);
        assertEq(acc.accountId(), "vaultlite.smartaccount.v1");
        assertTrue(acc.supportsModule(MODULE_TYPE_HOOK));
        assertTrue(acc.supportsExecutionMode(bytes32(0)));
        assertTrue(acc.supportsExecutionMode(bytes32(uint256(0x0101) << 240)));
        assertFalse(acc.supportsExecutionMode(bytes32(uint256(0xff) << 248)));
        assertTrue(acc.isModuleInstalled(MODULE_TYPE_VALIDATOR, address(ecdsa), ""));
    }

    // ---------------------------------------------------------------- userops
    function test_deployViaInitCode_andExecute() public {
        bytes memory init = _initData(owner);
        address sender = factory.getAddress(init, bytes32(uint256(99)));
        vm.deal(sender, 1 ether);
        bytes memory initCode = abi.encodePacked(
            address(factory), abi.encodeCall(AccountFactory.createAccount, (init, bytes32(uint256(99))))
        );
        PackedUserOperation memory op = _userOp(
            sender, address(ecdsa), initCode, _single(address(target), 0, abi.encodeCall(Target.setValue, (5)))
        );
        _handle(_signOwner(op, ownerKey));
        assertEq(target.value(), 5);
        assertEq(target.lastCaller(), sender);
        assertEq(EP.getNonce(sender, _nonceKey(address(ecdsa))), (uint256(_nonceKey(address(ecdsa))) << 64) | 1);
    }

    function test_batchExecute() public {
        MockERC20 token = new MockERC20();
        token.mint(address(acc), 100);
        Execution[] memory calls = new Execution[](3);
        calls[0] = Execution(address(target), 1 ether, abi.encodeCall(Target.setValue, (9)));
        calls[1] = Execution(address(token), 0, abi.encodeCall(token.transfer, (address(0xB0B), 40)));
        calls[2] = Execution(address(0xB0B), 0.5 ether, "");
        _ownerExec(acc, _batch(calls));
        assertEq(target.value(), 9);
        assertEq(address(target).balance, 1 ether);
        assertEq(token.balanceOf(address(0xB0B)), 40);
        assertEq(address(0xB0B).balance, 0.5 ether);
    }

    function test_wrongSigner_failsAA24() public {
        PackedUserOperation memory op = _userOp(
            address(acc), address(ecdsa), "", _single(address(target), 0, abi.encodeCall(Target.setValue, (1)))
        );
        op = _signOwner(op, 0xBAD);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA24 signature error"));
        EP.handleOps(ops, beneficiary);
    }

    function test_uninstalledValidatorNonce_fails() public {
        PackedUserOperation memory op = _userOp(
            address(acc), address(0x1234), "", _single(address(target), 0, abi.encodeCall(Target.setValue, (1)))
        );
        op = _signOwner(op, ownerKey);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA24 signature error"));
        EP.handleOps(ops, beneficiary);
    }

    function test_execute_onlyEntryPointOrSelf() public {
        vm.expectRevert();
        acc.execute(bytes32(0), abi.encodePacked(address(target), uint256(0), abi.encodeCall(Target.setValue, (1))));
        vm.prank(EP_ADDR);
        acc.execute(bytes32(0), abi.encodePacked(address(target), uint256(0), abi.encodeCall(Target.setValue, (1))));
        assertEq(target.value(), 1);
    }

    function test_validateUserOp_onlyEntryPoint() public {
        PackedUserOperation memory op;
        op.sender = address(acc);
        vm.expectRevert();
        acc.validateUserOp(op, bytes32(0), 0);
    }

    function test_delegatecall_disabled() public {
        vm.prank(EP_ADDR);
        vm.expectRevert(SmartAccount.DelegateCallDisabled.selector);
        acc.execute(bytes32(uint256(0xff) << 248), abi.encodePacked(address(target), hex""));
    }

    function test_tryMode_collectsFailure() public {
        vm.prank(EP_ADDR);
        acc.execute(
            bytes32(uint256(0x01) << 240),
            abi.encodePacked(address(target), uint256(0), abi.encodeCall(Target.fail, ()))
        );
    }

    function test_executeFromExecutor_onlyInstalled() public {
        vm.expectRevert();
        acc.executeFromExecutor(bytes32(0), abi.encodePacked(address(target), uint256(0), hex""));
    }

    // ---------------------------------------------------------------- modules
    function test_installUninstall_hook_and_fallback() public {
        MockHook h = new MockHook();
        MockFallback f = new MockFallback();
        _ownerCall(acc, address(acc), abi.encodeCall(acc.installModule, (MODULE_TYPE_HOOK, address(h), "")));
        assertTrue(acc.isModuleInstalled(MODULE_TYPE_HOOK, address(h), ""));
        _ownerCall(acc, address(target), abi.encodeCall(Target.setValue, (3)));
        assertGt(h.pre(), 0);
        bytes memory fbInit = abi.encodePacked(MockFallback.hello.selector);
        _ownerCall(acc, address(acc), abi.encodeCall(acc.installModule, (MODULE_TYPE_FALLBACK, address(f), fbInit)));
        // non-static call: the installed hook's preCheck writes state
        (bool ok, bytes memory ret) = address(acc).call(abi.encodeCall(MockFallback.hello, ()));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), 42);
        _ownerCall(acc, address(acc), abi.encodeCall(acc.uninstallModule, (MODULE_TYPE_HOOK, address(h), "")));
        assertFalse(acc.isModuleInstalled(MODULE_TYPE_HOOK, address(h), ""));
    }

    function test_installModule_wrongType_reverts() public {
        vm.prank(EP_ADDR);
        vm.expectRevert();
        acc.installModule(MODULE_TYPE_EXECUTOR, address(ecdsa), "");
    }

    function test_receivesEthAndNfts() public {
        (bool ok,) = address(acc).call{value: 1}("");
        assertTrue(ok);
        NFT nft = new NFT();
        nft.mint(address(acc), 1);
        assertEq(nft.ownerOf(1), address(acc));
    }

    // ---------------------------------------------------------------- ERC-1271
    function test_isValidSignature() public view {
        bytes32 h = keccak256("hello");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, ecdsa.accountMessageDigest(address(acc), h));
        bytes memory sig = abi.encodePacked(address(ecdsa), r, s, v);
        assertEq(acc.isValidSignature(h, sig), bytes4(0x1626ba7e));
        // raw signature over h (no account binding) must fail (ERC-7739-style replay protection)
        (v, r, s) = vm.sign(ownerKey, h);
        assertEq(acc.isValidSignature(h, abi.encodePacked(address(ecdsa), r, s, v)), bytes4(0xffffffff));
        // unknown validator prefix / short sig
        assertEq(acc.isValidSignature(h, abi.encodePacked(address(0x1), r, s, v)), bytes4(0xffffffff));
        assertEq(acc.isValidSignature(h, hex"00"), bytes4(0xffffffff));
    }

    function test_isValidSignature_crossAccountReplay() public {
        SmartAccount acc2 = _createAccount(_initData(owner), bytes32(uint256(1)));
        bytes32 h = keccak256("hello");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, ecdsa.accountMessageDigest(address(acc), h));
        bytes memory sig = abi.encodePacked(address(ecdsa), r, s, v);
        assertEq(acc2.isValidSignature(h, sig), bytes4(0xffffffff));
    }
}
