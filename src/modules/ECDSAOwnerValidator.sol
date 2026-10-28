// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    IERC7579Validator,
    IERC7579Module,
    MODULE_TYPE_VALIDATOR
} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/ERC4337Utils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title ECDSAOwnerValidator
/// @notice ERC-7579 validator: one secp256k1 owner per account.
///         * UserOps: 65-byte r||s||v (v = 27/28) over EIP-191 `personal_sign` of the 32 raw userOpHash bytes,
///           i.e. `ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(userOpHash), sig)` — matches viem
///           `signMessage({ message: { raw: userOpHash } })`.
///         * ERC-1271: defensive rehash binding the hash to the account (ERC-7739-style, see AUDIT_NOTES):
///           the owner signs the EIP-712 digest of `AccountMessage(bytes32 hash)` under the domain
///           `{name: "VaultLiteECDSAValidator", version: "1", chainId, verifyingContract: account}`.
///         High-s / malformed signatures are rejected by OZ ECDSA.
contract ECDSAOwnerValidator is IERC7579Validator {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("VaultLiteECDSAValidator");
    bytes32 private constant VERSION_HASH = keccak256("1");
    bytes32 public constant ACCOUNT_MESSAGE_TYPEHASH = keccak256("AccountMessage(bytes32 hash)");

    mapping(address account => address) public ownerOf;

    event OwnerSet(address indexed account, address indexed owner);

    error InvalidOwner();
    error NotInstalled();
    error AlreadyInstalled();

    // ------------------------------------------------------------------ module config
    function onInstall(bytes calldata data) external override {
        if (ownerOf[msg.sender] != address(0)) revert AlreadyInstalled();
        address owner = abi.decode(data, (address));
        _setOwner(msg.sender, owner);
    }

    function onUninstall(bytes calldata) external override {
        delete ownerOf[msg.sender];
        emit OwnerSet(msg.sender, address(0));
    }

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR;
    }

    /// @notice Rotate the owner. Callable only by the account itself (owner-signed op or recovery executor).
    function rotateOwner(address newOwner) external {
        if (ownerOf[msg.sender] == address(0)) revert NotInstalled();
        _setOwner(msg.sender, newOwner);
    }

    // ------------------------------------------------------------------ validation
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash)
        external
        view
        override
        returns (uint256)
    {
        address owner = ownerOf[msg.sender];
        bool ok = owner != address(0)
            && _recover(MessageHashUtils.toEthSignedMessageHash(userOpHash), userOp.signature) == owner;
        return ok ? ERC4337Utils.SIG_VALIDATION_SUCCESS : ERC4337Utils.SIG_VALIDATION_FAILED;
    }

    function isValidSignatureWithSender(address, bytes32 hash, bytes calldata signature)
        external
        view
        override
        returns (bytes4)
    {
        address owner = ownerOf[msg.sender];
        if (owner != address(0) && _recover(accountMessageDigest(msg.sender, hash), signature) == owner) {
            return 0x1626ba7e;
        }
        return 0xffffffff;
    }

    /// @notice Digest the owner must sign (raw ECDSA / eth_signTypedData) for ERC-1271 on `account`.
    function accountMessageDigest(address account, bytes32 hash) public view returns (bytes32) {
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, account));
        return MessageHashUtils.toTypedDataHash(domain, keccak256(abi.encode(ACCOUNT_MESSAGE_TYPEHASH, hash)));
    }

    // ------------------------------------------------------------------ internals
    function _setOwner(address account, address owner) internal {
        if (owner == address(0) || owner == account) revert InvalidOwner();
        ownerOf[account] = owner;
        emit OwnerSet(account, owner);
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address signer) {
        if (sig.length != 65) return address(0);
        (signer,,) = ECDSA.tryRecoverCalldata(digest, sig);
    }
}
