# Audit notes (self-review, not a formal audit)

Tooling: Slither 0.11.6 (`slither . --filter-paths "lib/|test/|script/" --exclude-dependencies`), full output in
`slither-report.txt`. Compiler solc 0.8.36, EVM cancun, OpenZeppelin Contracts v5.7.0, forge-std v1.17.0.

## Slither findings

Initial run: 25 results. Fixed 2, documented 23 (all low/informational, no high/medium).

| Detector | Count | Status | Notes |
|---|---|---|---|
| reentrancy-events (`RecoveryExecutor.executeRecovery`) | 1 | **Fixed** | Event now emitted before the external `executeFromExecutor` call. State was already cleared before the call (CEI). |
| uninitialized-local (`SmartAccount.initialize.hasValidator`) | 1 | **Fixed** | Explicitly initialised to `false`. |
| incorrect-equality | 6 | Accepted (false positive) | `== 0` checks are sentinels (empty config / unset timestamp / array length), not balance equalities. |
| timestamp | 9 | Accepted | Recovery timelocks are intentionally time-based (hours/days granularity; a few seconds of proposer skew is irrelevant). Several flagged lines don't even use `block.timestamp` (slither taints the whole struct). No timestamp use in any **validation-phase** code (ERC-7562 bans `TIMESTAMP` there); session expiry is returned in `validationData` and enforced by the EntryPoint. |
| unused-return | 8 | Accepted | `cloneDeterministic` address is pre-computed via `predictDeterministicAddress`; `functionCall` reverts on failure; `decodeMode`/`tryRecover` tuple parts intentionally ignored (a failed recovery yields `address(0)` which never equals a non-zero owner/session key); `executeFromExecutor` return data unused (default exec type reverts on failure). |

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
