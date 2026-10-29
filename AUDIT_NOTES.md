# Audit notes (self-review, not a formal audit)

Tooling: Slither 0.11.6 (`slither . --filter-paths "lib/|test/|script/" --exclude-dependencies`), full output in
`slither-report.txt`. Compiler solc 0.8.36, EVM cancun, OpenZeppelin Contracts v5.7.0, forge-std v1.17.0.

## Slither findings

Initial run: 25 results. Fixed 2, documented 23. No high-severity results. Note: Slither classifies `incorrect-equality`
and `unused-return` as **medium**; both were triaged as false positives (below). After the `feat/hardening` changes the
run reports 29 results (table updated).

| Detector | Count | Status | Notes |
|---|---|---|---|
| reentrancy-events (`RecoveryExecutor.executeRecovery`) | 1 | **Fixed** | Event now emitted before the external `executeFromExecutor` call. State was already cleared before the call (CEI). |
| uninitialized-local (`SmartAccount.initialize.hasValidator`) | 1 | **Fixed** | Explicitly initialised to `false`. |
| incorrect-equality (medium) | 7 | Accepted (false positive) | `== 0` checks are sentinels (empty config / unset timestamp / array length), not balance equalities. |
| timestamp | 10 | Accepted | Recovery timelocks are intentionally time-based (hours/days granularity; a few seconds of proposer skew is irrelevant). Several flagged lines don't even use `block.timestamp` (slither taints the whole struct). No timestamp use in any **validation-phase** code (ERC-7562 bans `TIMESTAMP` there); session expiry is returned in `validationData` and enforced by the EntryPoint. |
| unused-return (medium) | 8 | Accepted | `cloneDeterministic` address is pre-computed via `predictDeterministicAddress`; `functionCall` reverts on failure; `decodeMode`/`tryRecover` tuple parts intentionally ignored (a failed recovery yields `address(0)` which never equals a non-zero owner/session key); `executeFromExecutor` return data unused (default exec type reverts on failure). |
| calls-loop / low-level-calls / return-bomb (`SessionKeyValidator._isModule`) | 2 / 1 / 1 | Accepted | Enable-time `isModuleType(1..4)` probe of each permission target: `staticcall`, 30k gas cap per probe, never in the validation phase. |

Forge lint (`forge build`) additionally reports style notes (missing events for internal maps written inside
`enableSession` — covered by the `SessionEnabled` event; unsafe-typecast on `bytes4(initData)` after a length check).

## Design notes / residual risks

1. **Owner-key theft (T1)** – a thief with the owner key can cancel recovery, install another validator, or schedule
   uninstall of `RecoveryExecutor`. Mitigations: uninstalling `RecoveryExecutor` and changing guardians are timelocked
   by the current recovery timelock; executing/cancelling a recovery wipes a scheduled uninstall. A guardian-veto mode or
   passkey second factor is future work. Guardians can only rotate the ECDSA owner, not remove extra validators.
2. **Uninstalling the last validator** bricks the account (OZ does not prevent it). Front-ends must never send that op.
3. **Session spend accounting** is updated in the validation phase (as required by SPEC §4.4). If execution later
   reverts, the spend/use still counts (conservative). Token-moving selectors (`transfer`, `approve`,
   `increaseAllowance`, `transferFrom`) are rejected unless an explicit per-token cap exists for that target (T4).
   Only `execute` with exec type `default` and call type single/batch is accepted; mode selector/payload must be zero.
   Session permissions may not target the account itself or the session module.
4. **Session/escrow-operator state on uninstall** – module storage cannot be iterated, so `SessionKeyValidator` and
   `EscrowExecutor` use a per-account epoch: uninstall bumps the epoch and invalidates all old sessions/operators.
   Session ids include the epoch, which is set at install time; compute them with `sessionIdOf` *after* install
   (or predict `epoch + 1` for counterfactual accounts).
5. **ERC-7562** – all validation-phase storage is keyed with the account as the last mapping key (account-associated
   slots); no arrays or external calls in validation. Because account initialisation writes module storage during
   deployment, **the factory must be staked** in the EntryPoint (STO-022) before bundlers accept initCode ops;
   `AccountFactory.addStake/unlockStake/withdrawStake` (owner-only) are provided. Fork tests call `handleOps`
   directly, so bundler simulation rules are **not** exercised by tests — validate with Pimlico before release.
6. **ERC-1271** – implemented as an ERC-7739-*style* defensive rehash, not full ERC-7739 nested
   `TypedDataSign`/`PersonalSign`: the owner signs the EIP-712 digest of `AccountMessage(bytes32 hash)` under domain
   `{name:"VaultLiteECDSAValidator", version:"1", chainId, verifyingContract: account}`. This prevents cross-account
   replay (tested) but wallets display an opaque `hash` rather than the nested typed data. Signature format:
   `validator address (20 bytes) || r || s || v`.
7. **EscrowExecutor** – the escrow address is immutable, every call has value 0, and only provider-side selectors plus
   whitelisted/capped `approveMilestone` are reachable (I5 invariant). Operators are trusted not to grief by
   submitting milestones early (harmless) or approving whitelisted milestones (bounded by cap).
8. **Immutable accounts** – ERC-1167 clones, no upgrade path. Bugs require deploying a new factory and migrating funds.
9. **High-s signatures** – rejected by OZ `ECDSA` (fuzz-tested).
10. **Hooks** – a hook's `preCheck` runs on fallback calls; installing a state-changing hook makes view calls through
    fallback handlers revert under `STATICCALL` (expected OZ behaviour).

## Hardening pass (branch `feat/hardening`, 2026-10-29)

Scope: session-key limits (expiry, target/selector allowlist, native/token caps), recovery timelock/cancel edge cases,
reentrancy, and module install/uninstall edge cases. New tests are in `test/Hardening.t.sol` (18 tests, including 1 fuzz).

**Bug fixed: session key could take over the account through another module.** `_enable` rejected permissions that
target the account or the session module, but not other ERC-7579 modules. Modules authorise by `msg.sender == account`.
So an owner who allowlisted e.g. `(ECDSAOwnerValidator, rotateOwner)`, or any `RecoveryExecutor`/`EscrowExecutor`
function, gave the session key the power to rotate the owner or reconfigure recovery. Fix: `_enable` now staticcalls
`isModuleType(t)` for t = 1..4 on each permission target and reverts `InvalidSession` if any returns true
(test `test_session_cannotTargetModules`). Residual risk: a contract that does not implement `isModuleType` but trusts
`msg.sender == account` is not detected. Session permissions should only name trusted dapp contracts.

**Gap fixed: no way to cancel a scheduled uninstall of `RecoveryExecutor`.** Before, `uninstallAllowedAt` could only be
cleared as a side effect of an active recovery request. Added `cancelUninstall()` (account-only, emits
`UninstallCancelled`) with test `test_recovery_cancelUninstall`. This is an API addition.

Edge cases now covered by tests (no bug found): cumulative native cap across ops; batch value summed against the cap;
`transferFrom` amount counted against the token cap; value on a selector call counted; old sessions invalid after
uninstall + reinstall of the validator (epoch); revoked session ids cannot be reused; enabling requires install;
recovery cannot execute twice; an EIP-712 approval signed for an old nonce is rejected after cancel; owner can cancel
after `readyAt` but before execution; reinstalling `RecoveryExecutor` after uninstall starts from clean state; a call
target re-entering `execute` / `executeFromExecutor` reverts (only EntryPoint/self and installed executors are allowed);
double-install and uninstalling a missing module revert; calling a module's `onUninstall` directly only affects the
caller's own state.

Other changes: GitHub Actions CI (`.github/workflows/ci.yml`: `forge fmt --check`, `forge build`, offline tests, fork
tests only when the `BASE_SEPOLIA_RPC_URL` secret is set, gitleaks); `.gas-snapshot` (fork tests excluded).
Not done: Halmos symbolic tests (Halmos is not installed in this environment). The existing 5 invariants are unchanged.

**Deployment note:** the Base Sepolia contracts listed in the README were deployed and verified from the earlier source
(`main` at `3eedaa7`). They do **not** include these fixes. A redeploy would be needed for the deployed system to match.
