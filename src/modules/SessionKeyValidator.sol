// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC7579Validator, MODULE_TYPE_VALIDATOR} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {IERC7579Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/ERC4337Utils.sol";
import {
    ERC7579Utils,
    Mode,
    CallType,
    ExecType,
    ModeSelector,
    ModePayload,
    Execution
} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title SessionKeyValidator
/// @notice ERC-7579 validator for scoped secp256k1 session keys (e.g. the MilestoneEscrow operator key).
///         Policies (all must pass): (target, selector) allowlist checked per call (batches element-wise),
///         cumulative native-value cap, per-ERC-20 caps on transfer/approve/increaseAllowance/transferFrom,
///         validAfter/validUntil returned in validationData, optional max-use count. Owner can revoke any time.
///
///         Signature layout: `sessionId (32) || r||s||v (65)` where the session key signs the userOpHash with
///         EIP-191 personal_sign (same scheme as the owner).
///
///         ERC-7562: every mapping is keyed with the account as the LAST key so all slots touched during
///         validation are account-associated (`keccak(account || ...)`). No dynamic arrays are used.
contract SessionKeyValidator is IERC7579Validator {
    using ERC7579Utils for Mode;

    struct Permission {
        address target;
        bytes4 selector; // bytes4(0) = plain value transfer / empty calldata
    }

    struct TokenCap {
        address token;
        uint128 cap;
    }

    struct SessionConfig {
        address sessionKey;
        uint48 validAfter;
        uint48 validUntil; // 0 = no expiry
        uint32 maxUses; // 0 = unlimited
        uint128 nativeCap; // cumulative wei
        bytes32 salt;
        Permission[] permissions;
        TokenCap[] tokenCaps;
    }

    struct Session {
        address sessionKey;
        uint48 validAfter;
        uint48 validUntil;
        uint32 maxUses;
        uint32 uses;
        uint64 epoch;
        bool revoked;
        uint128 nativeCap;
        uint128 nativeSpent;
    }

    struct TokenUsage {
        bool enabled;
        uint128 cap;
        uint128 spent;
    }

    bytes4 internal constant ERC20_TRANSFER = 0xa9059cbb;
    bytes4 internal constant ERC20_APPROVE = 0x095ea7b3;
    bytes4 internal constant ERC20_INCREASE_ALLOWANCE = 0x39509351;
    bytes4 internal constant ERC20_TRANSFER_FROM = 0x23b872dd;

    // all keyed (..., account) — see contract natspec
    mapping(address account => uint64) public epochOf; // bumped on install/uninstall to wipe sessions
    mapping(address account => bool) public installed;
    mapping(bytes32 sessionId => mapping(address account => Session)) internal _sessions;
    mapping(bytes32 permKey => mapping(address account => bool)) internal _allowed;
    mapping(bytes32 tokenKey => mapping(address account => TokenUsage)) internal _tokens;

    event SessionEnabled(address indexed account, bytes32 indexed sessionId, address indexed sessionKey);
    event SessionRevoked(address indexed account, bytes32 indexed sessionId);

    error NotInstalled();
    error SessionExists();
    error InvalidSession();
    error UnknownSession();

    // ------------------------------------------------------------------ module config
    function onInstall(bytes calldata data) external override {
        installed[msg.sender] = true;
        ++epochOf[msg.sender];
        if (data.length != 0) _enable(msg.sender, abi.decode(data, (SessionConfig)));
    }

    function onUninstall(bytes calldata) external override {
        installed[msg.sender] = false;
        ++epochOf[msg.sender];
    }

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR;
    }

    // ------------------------------------------------------------------ session management (account-only)
    /// @notice Enable a session. msg.sender must be the account (i.e. executed through an owner-validated op).
    function enableSession(SessionConfig calldata cfg) external returns (bytes32 sessionId) {
        if (!installed[msg.sender]) revert NotInstalled();
        return _enable(msg.sender, cfg);
    }

    function revokeSession(bytes32 sessionId) external {
        Session storage s = _sessions[sessionId][msg.sender];
        if (s.sessionKey == address(0)) revert UnknownSession();
        s.revoked = true;
        emit SessionRevoked(msg.sender, sessionId);
    }

    function sessionIdOf(address account, address sessionKey, bytes32 salt) public view returns (bytes32) {
        return keccak256(abi.encode(account, epochOf[account], sessionKey, salt));
    }

    // ------------------------------------------------------------------ views
    function getSession(address account, bytes32 sessionId) external view returns (Session memory) {
        return _sessions[sessionId][account];
    }

    function isAllowed(address account, bytes32 sessionId, address target, bytes4 selector)
        external
        view
        returns (bool)
    {
        return _allowed[_permKey(sessionId, target, selector)][account];
    }

    function tokenUsage(address account, bytes32 sessionId, address token) external view returns (TokenUsage memory) {
        return _tokens[_tokenKey(sessionId, token)][account];
    }

    // ------------------------------------------------------------------ validation
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash)
        external
        override
        returns (uint256)
    {
        address account = msg.sender;
        bytes calldata sig = userOp.signature;
        if (sig.length != 97) return ERC4337Utils.SIG_VALIDATION_FAILED;
        bytes32 sessionId = bytes32(sig[0:32]);
        Session storage s = _sessions[sessionId][account];

        if (
            !installed[account] || s.sessionKey == address(0) || s.revoked || s.epoch != epochOf[account]
                || (s.maxUses != 0 && s.uses >= s.maxUses)
        ) return ERC4337Utils.SIG_VALIDATION_FAILED;

        (address signer,,) = ECDSA.tryRecoverCalldata(MessageHashUtils.toEthSignedMessageHash(userOpHash), sig[32:97]);
        if (signer != s.sessionKey) return ERC4337Utils.SIG_VALIDATION_FAILED;

        if (!_checkCallData(account, sessionId, s, userOp.callData)) return ERC4337Utils.SIG_VALIDATION_FAILED;
        unchecked {
            ++s.uses;
        }
        return ERC4337Utils.packValidationData(true, s.validAfter, s.validUntil);
    }

    /// @dev Session keys cannot produce ERC-1271 signatures.
    function isValidSignatureWithSender(address, bytes32, bytes calldata) external pure override returns (bytes4) {
        return 0xffffffff;
    }

    // ------------------------------------------------------------------ internals
    function _enable(address account, SessionConfig memory cfg) internal returns (bytes32 sessionId) {
        if (cfg.sessionKey == address(0) || (cfg.validUntil != 0 && cfg.validUntil <= cfg.validAfter)) {
            revert InvalidSession();
        }
        sessionId = sessionIdOf(account, cfg.sessionKey, cfg.salt);
        Session storage s = _sessions[sessionId][account];
        if (s.sessionKey != address(0)) revert SessionExists(); // ids are never reused (even after revoke)
        _sessions[sessionId][account] = Session({
            sessionKey: cfg.sessionKey,
            validAfter: cfg.validAfter,
            validUntil: cfg.validUntil,
            maxUses: cfg.maxUses,
            uses: 0,
            epoch: epochOf[account],
            revoked: false,
            nativeCap: cfg.nativeCap,
            nativeSpent: 0
        });
        for (uint256 i; i < cfg.permissions.length; ++i) {
            Permission memory p = cfg.permissions[i];
            // never let a session key reconfigure the account or this module
            if (p.target == account || p.target == address(this) || _isModule(p.target)) revert InvalidSession();
            _allowed[_permKey(sessionId, p.target, p.selector)][account] = true;
        }
        for (uint256 i; i < cfg.tokenCaps.length; ++i) {
            _tokens[_tokenKey(sessionId, cfg.tokenCaps[i].token)][account] =
                TokenUsage({enabled: true, cap: cfg.tokenCaps[i].cap, spent: 0});
        }
        emit SessionEnabled(account, sessionId, cfg.sessionKey);
    }

    function _checkCallData(address account, bytes32 sessionId, Session storage s, bytes calldata callData)
        internal
        returns (bool)
    {
        if (callData.length < 4 || bytes4(callData) != IERC7579Execution.execute.selector) return false;
        (bytes32 rawMode, bytes calldata execData) = _decodeExecute(callData);
        (CallType callType, ExecType execType, ModeSelector sel, ModePayload payload) = Mode.wrap(rawMode).decodeMode();
        if (ExecType.unwrap(execType) != ExecType.unwrap(ERC7579Utils.EXECTYPE_DEFAULT)) return false;
        if (ModeSelector.unwrap(sel) != bytes4(0) || ModePayload.unwrap(payload) != bytes22(0)) return false;

        (bool ok, uint256 value) = _checkExecutions(account, sessionId, callType, execData);
        if (!ok) return false;
        uint256 spent = uint256(s.nativeSpent) + value;
        if (spent > s.nativeCap) return false;
        s.nativeSpent = uint128(spent);
        return true;
    }

    function _checkExecutions(address account, bytes32 sessionId, CallType callType, bytes calldata execData)
        internal
        returns (bool, uint256 value)
    {
        if (CallType.unwrap(callType) == CallType.unwrap(ERC7579Utils.CALLTYPE_SINGLE)) {
            (address target, uint256 v, bytes calldata data) = ERC7579Utils.decodeSingle(execData);
            return (_checkCall(account, sessionId, target, data), v);
        }
        if (CallType.unwrap(callType) == CallType.unwrap(ERC7579Utils.CALLTYPE_BATCH)) {
            Execution[] calldata batch = ERC7579Utils.decodeBatch(execData);
            for (uint256 i; i < batch.length; ++i) {
                if (!_checkCall(account, sessionId, batch[i].target, batch[i].callData)) return (false, 0);
                value += batch[i].value;
            }
            return (true, value);
        }
        return (false, 0);
    }

    function _checkCall(address account, bytes32 sessionId, address target, bytes calldata data)
        internal
        returns (bool)
    {
        bytes4 selector = data.length >= 4 ? bytes4(data[0:4]) : bytes4(0);
        if (data.length > 0 && data.length < 4) return false;
        if (target == account || target == address(this)) return false;
        if (!_allowed[_permKey(sessionId, target, selector)][account]) return false;

        uint256 amount;
        if (selector == ERC20_TRANSFER || selector == ERC20_APPROVE || selector == ERC20_INCREASE_ALLOWANCE) {
            if (data.length < 68) return false;
            amount = uint256(bytes32(data[36:68]));
        } else if (selector == ERC20_TRANSFER_FROM) {
            if (data.length < 100) return false;
            amount = uint256(bytes32(data[68:100]));
        } else {
            return true;
        }
        TokenUsage storage t = _tokens[_tokenKey(sessionId, target)][account];
        if (!t.enabled) return false; // token-moving selectors require an explicit cap (T4)
        uint256 newSpent = uint256(t.spent) + amount;
        if (newSpent > t.cap) return false;
        t.spent = uint128(newSpent);
        return true;
    }

    /// @dev True if `target` reports itself as an ERC-7579 module of any standard type (1..4). Modules trust
    ///      msg.sender == account, so a session allowed to call one (e.g. `ECDSAOwnerValidator.rotateOwner`) could
    ///      take over or reconfigure the account. Only used at enable time (not in validation, so ERC-7562 is unaffected).
    function _isModule(address target) internal view returns (bool) {
        if (target.code.length == 0) return false;
        for (uint256 t = 1; t <= 4; ++t) {
            (bool ok, bytes memory ret) =
                target.staticcall{gas: 30_000}(abi.encodeWithSignature("isModuleType(uint256)", t));
            if (ok && ret.length >= 32 && abi.decode(ret, (bool))) return true;
        }
        return false;
    }

    /// @dev Decodes `execute(bytes32,bytes)` calldata with bounds checks.
    function _decodeExecute(bytes calldata callData) internal pure returns (bytes32 mode, bytes calldata data) {
        mode = bytes32(callData[4:36]);
        uint256 offset = uint256(bytes32(callData[36:68]));
        uint256 start = 4 + offset;
        uint256 len = uint256(bytes32(callData[start:start + 32]));
        data = callData[start + 32:start + 32 + len];
    }

    function _permKey(bytes32 sessionId, address target, bytes4 selector) internal pure returns (bytes32) {
        return keccak256(abi.encode(sessionId, target, selector));
    }

    function _tokenKey(bytes32 sessionId, address token) internal pure returns (bytes32) {
        return keccak256(abi.encode(sessionId, token));
    }
}
