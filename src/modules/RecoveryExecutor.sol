// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    IERC7579Module,
    IERC7579Execution,
    MODULE_TYPE_EXECUTOR
} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ECDSAOwnerValidator} from "./ECDSAOwnerValidator.sol";

/// @title RecoveryExecutor
/// @notice ERC-7579 executor: M-of-N guardian social recovery with a timelock (default 48h, 24h..30d).
///         Guardians propose/approve (on-chain or EIP-712 signatures, nonce-bound). Once M approvals are in,
///         `readyAt = now + timelock`; the owner (the account itself) can cancel at any time before execution.
///         Execution calls `account.executeFromExecutor` -> `ECDSAOwnerValidator.rotateOwner(newOwner)`.
///         Guardian-set changes and uninstalling this module are timelocked by the current timelock.
contract RecoveryExecutor is IERC7579Module, EIP712 {
    /// @dev ERC-7579 mode: CALLTYPE_SINGLE (0x00), EXECTYPE_DEFAULT (0x00), no selector/payload.
    bytes32 internal constant _MODE_SINGLE_DEFAULT = bytes32(0);

    uint256 public constant MAX_GUARDIANS = 10;
    uint32 public constant DEFAULT_TIMELOCK = 48 hours;
    uint32 public constant MIN_TIMELOCK = 24 hours;
    uint32 public constant MAX_TIMELOCK = 30 days;
    bytes32 public constant APPROVAL_TYPEHASH =
        keccak256("RecoveryApproval(address account,address newOwner,uint256 nonce)");

    ECDSAOwnerValidator public immutable validator;

    struct Config {
        address[] guardians;
        uint8 threshold;
        uint32 timelock;
    }

    struct Request {
        address newOwner;
        uint8 approvals;
        uint48 readyAt; // 0 while below threshold
    }

    struct PendingConfig {
        address[] guardians;
        uint8 threshold;
        uint32 timelock;
        uint48 executableAt;
    }

    mapping(address account => Config) internal _config;
    mapping(address account => mapping(address guardian => bool)) public isGuardian;
    mapping(address account => uint256) public nonce;
    mapping(address account => Request) internal _request;
    mapping(address account => mapping(uint256 nonce => mapping(address guardian => bool))) public hasApproved;
    mapping(address account => PendingConfig) internal _pendingConfig;
    mapping(address account => uint48) public uninstallAllowedAt;

    event GuardiansSet(address indexed account, address[] guardians, uint8 threshold, uint32 timelock);
    event GuardianUpdateScheduled(address indexed account, uint48 executableAt);
    event GuardianUpdateCancelled(address indexed account);
    event UninstallScheduled(address indexed account, uint48 allowedAt);
    event RecoveryProposed(address indexed account, uint256 indexed nonce, address indexed newOwner, address guardian);
    event RecoveryApproved(address indexed account, uint256 indexed nonce, address indexed guardian);
    event RecoveryQueued(address indexed account, uint256 indexed nonce, uint48 readyAt);
    event RecoveryCancelled(address indexed account, uint256 indexed nonce);
    event RecoveryExecuted(address indexed account, uint256 indexed nonce, address newOwner);

    error NotInstalled();
    error AlreadyInstalled();
    error InvalidConfig();
    error NotGuardian();
    error AlreadyApproved();
    error NoActiveRequest();
    error RequestActive();
    error NotReady();
    error InvalidOwner();
    error InvalidSignature();
    error Timelocked();
    error NothingScheduled();

    constructor(ECDSAOwnerValidator validator_) EIP712("VaultLiteRecovery", "1") {
        validator = validator_;
    }

    // ------------------------------------------------------------------ module config
    /// @param data abi.encode(address[] guardians, uint8 threshold, uint32 timelock); timelock 0 = 48h default
    function onInstall(bytes calldata data) external override {
        if (_config[msg.sender].threshold != 0) revert AlreadyInstalled();
        (address[] memory guardians, uint8 threshold, uint32 timelock) = abi.decode(data, (address[], uint8, uint32));
        _setConfig(msg.sender, guardians, threshold, timelock == 0 ? DEFAULT_TIMELOCK : timelock);
    }

    /// @dev Reverts unless {scheduleUninstall} was called at least `timelock` ago (protects against a key thief
    ///      silently removing recovery). The account's OZ implementation propagates the revert.
    function onUninstall(bytes calldata) external override {
        uint48 at = uninstallAllowedAt[msg.sender];
        if (at == 0 || block.timestamp < at) revert Timelocked();
        Config storage c = _config[msg.sender];
        for (uint256 i; i < c.guardians.length; ++i) {
            isGuardian[msg.sender][c.guardians[i]] = false;
        }
        delete _config[msg.sender];
        delete _request[msg.sender];
        delete _pendingConfig[msg.sender];
        delete uninstallAllowedAt[msg.sender];
        ++nonce[msg.sender];
    }

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    // ------------------------------------------------------------------ owner (account) actions
    function scheduleGuardianUpdate(address[] calldata guardians, uint8 threshold, uint32 timelock) external {
        Config storage c = _requireInstalled(msg.sender);
        _validate(guardians, threshold, timelock);
        uint48 at = uint48(block.timestamp + c.timelock);
        _pendingConfig[msg.sender] =
            PendingConfig({guardians: guardians, threshold: threshold, timelock: timelock, executableAt: at});
        emit GuardianUpdateScheduled(msg.sender, at);
    }

    function cancelGuardianUpdate() external {
        if (_pendingConfig[msg.sender].executableAt == 0) revert NothingScheduled();
        delete _pendingConfig[msg.sender];
        emit GuardianUpdateCancelled(msg.sender);
    }

    /// @notice Anyone can apply a matured guardian update (it was authorized by the owner when scheduled).
    function applyGuardianUpdate(address account) external {
        PendingConfig memory p = _pendingConfig[account];
        if (p.executableAt == 0) revert NothingScheduled();
        if (block.timestamp < p.executableAt) revert Timelocked();
        Config storage c = _config[account];
        for (uint256 i; i < c.guardians.length; ++i) {
            isGuardian[account][c.guardians[i]] = false;
        }
        delete _pendingConfig[account];
        _clearRequest(account); // approvals from the old set must not carry over
        _setConfig(account, p.guardians, p.threshold, p.timelock);
    }

    function scheduleUninstall() external {
        Config storage c = _requireInstalled(msg.sender);
        uint48 at = uint48(block.timestamp + c.timelock);
        uninstallAllowedAt[msg.sender] = at;
        emit UninstallScheduled(msg.sender, at);
    }

    /// @notice Owner cancels an in-flight recovery (proposed or queued). Also cancels a scheduled uninstall.
    function cancelRecovery() external {
        _requireInstalled(msg.sender);
        if (_request[msg.sender].newOwner == address(0)) revert NoActiveRequest();
        _clearRequest(msg.sender);
    }

    // ------------------------------------------------------------------ guardian actions
    function proposeRecovery(address account, address newOwner) external {
        _onlyGuardian(account, msg.sender);
        if (newOwner == address(0) || newOwner == account) revert InvalidOwner();
        Request storage r = _request[account];
        if (r.newOwner != address(0)) revert RequestActive();
        r.newOwner = newOwner;
        emit RecoveryProposed(account, nonce[account], newOwner, msg.sender);
        _approve(account, msg.sender);
    }

    function approveRecovery(address account) external {
        _onlyGuardian(account, msg.sender);
        if (_request[account].newOwner == address(0)) revert NoActiveRequest();
        _approve(account, msg.sender);
    }

    /// @notice Relay a guardian's EIP-712 approval (EOA or ERC-1271 guardian). Bound to account, newOwner, nonce.
    function approveRecoveryWithSig(address account, address guardian, bytes calldata signature) external {
        _onlyGuardian(account, guardian);
        address newOwner = _request[account].newOwner;
        if (newOwner == address(0)) revert NoActiveRequest();
        if (!SignatureChecker.isValidSignatureNow(
                guardian, approvalDigest(account, newOwner, nonce[account]), signature
            )) {
            revert InvalidSignature();
        }
        _approve(account, guardian);
    }

    /// @notice Anyone can execute a queued recovery once the timelock elapsed.
    function executeRecovery(address account) external {
        Request memory r = _request[account];
        if (r.newOwner == address(0)) revert NoActiveRequest();
        if (r.readyAt == 0 || block.timestamp < r.readyAt) revert NotReady();
        uint256 n = nonce[account];
        _clearRequest(account);
        emit RecoveryExecuted(account, n, r.newOwner);
        IERC7579Execution(account)
            .executeFromExecutor(
                _MODE_SINGLE_DEFAULT,
                abi.encodePacked(
                    address(validator), uint256(0), abi.encodeCall(ECDSAOwnerValidator.rotateOwner, (r.newOwner))
                )
            );
    }

    // ------------------------------------------------------------------ views
    function approvalDigest(address account, address newOwner, uint256 nonce_) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(APPROVAL_TYPEHASH, account, newOwner, nonce_)));
    }

    function getConfig(address account) external view returns (Config memory) {
        return _config[account];
    }

    function getRequest(address account) external view returns (Request memory) {
        return _request[account];
    }

    function getPendingConfig(address account) external view returns (PendingConfig memory) {
        return _pendingConfig[account];
    }

    // ------------------------------------------------------------------ internals
    function _approve(address account, address guardian) internal {
        uint256 n = nonce[account];
        if (hasApproved[account][n][guardian]) revert AlreadyApproved();
        hasApproved[account][n][guardian] = true;
        Request storage r = _request[account];
        uint8 approvals = ++r.approvals;
        emit RecoveryApproved(account, n, guardian);
        if (r.readyAt == 0 && approvals >= _config[account].threshold) {
            r.readyAt = uint48(block.timestamp + _config[account].timelock);
            emit RecoveryQueued(account, n, r.readyAt);
        }
    }

    function _clearRequest(address account) internal {
        if (_request[account].newOwner != address(0)) emit RecoveryCancelled(account, nonce[account]);
        delete _request[account];
        delete uninstallAllowedAt[account];
        ++nonce[account];
    }

    function _setConfig(address account, address[] memory guardians, uint8 threshold, uint32 timelock) internal {
        _validate(guardians, threshold, timelock);
        for (uint256 i; i < guardians.length; ++i) {
            if (isGuardian[account][guardians[i]]) revert InvalidConfig(); // duplicate
            isGuardian[account][guardians[i]] = true;
        }
        _config[account] = Config({guardians: guardians, threshold: threshold, timelock: timelock});
        emit GuardiansSet(account, guardians, threshold, timelock);
    }

    function _validate(address[] memory guardians, uint8 threshold, uint32 timelock) internal pure {
        uint256 n = guardians.length;
        if (n == 0 || n > MAX_GUARDIANS) revert InvalidConfig();
        // strict majority (threat T2) and threshold <= N
        if (threshold == 0 || threshold > n || uint256(threshold) * 2 <= n) revert InvalidConfig();
        if (timelock < MIN_TIMELOCK || timelock > MAX_TIMELOCK) revert InvalidConfig();
        for (uint256 i; i < n; ++i) {
            if (guardians[i] == address(0)) revert InvalidConfig();
        }
    }

    function _requireInstalled(address account) internal view returns (Config storage c) {
        c = _config[account];
        if (c.threshold == 0) revert NotInstalled();
    }

    function _onlyGuardian(address account, address guardian) internal view {
        if (!isGuardian[account][guardian]) revert NotGuardian();
    }
}
