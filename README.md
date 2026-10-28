# VaultLite Smart Account

Modular ERC-4337 / ERC-7579 smart account for the VaultLite wallet on **Base Sepolia (84532)**, bound to
**EntryPoint v0.7** `0x0000000071727De22E5E9d8BAf0edAc6f37da032`. See `SPEC.md`, `ARCHITECTURE.md`,
`INTEGRATION.md` and `AUDIT_NOTES.md`. **Nothing has been deployed.**

## Contracts (`src/`)
| Contract | Role |
|---|---|
| `SmartAccount` | Thin immutable account on OZ `AccountERC7579Hooked` (v5.7.0). Validator chosen by nonce key, delegatecall mode disabled, receives ETH/ERC-721/ERC-1155, ERC-1271 routed to validators. |
| `AccountFactory` | CREATE2 factory of ERC-1167 clones. `createAccount(initData, salt)` / `getAddress(initData, salt)`; salt = `keccak256(keccak256(initData), salt)`. Idempotent. Owner can stake it in the EntryPoint. |
| `modules/ECDSAOwnerValidator` | Owner EOA (type 1). UserOps: EIP-191 personal_sign over the 32-byte userOpHash, 65-byte `r‖s‖v`. `rotateOwner` callable by the account only. |
| `modules/SessionKeyValidator` | Scoped session keys (type 1): target+selector allowlist, cumulative ETH cap, per-ERC-20 caps, validAfter/validUntil, max uses, revocation. |
| `modules/RecoveryExecutor` | Guardians M-of-N (default 2-of-3 setup in tests), 48h default timelock (24h–30d), owner cancel, EIP-712 guardian sigs, timelocked guardian changes/uninstall. |
| `modules/EscrowExecutor` | Operator-driven, value-free calls to MilestoneEscrow `0xD861…E528`: submit / claimAfterReview / withdraw, and whitelisted+capped approveMilestone. |

Paymaster: none in this repo — the app uses Pimlico sponsorship (ERC-7677), see `INTEGRATION.md`.

## Signing formats (for the app)
* **UserOp nonce**: `key = uint192(uint160(validator)) << 32` (validator address in the top 20 bytes, then 4-byte lane);
  read with `EntryPoint.getNonce(sender, key)`.
* **Owner userOp sig**: `owner.signMessage({ message: { raw: userOpHash } })` → 65 bytes.
* **Session userOp sig**: `sessionId (32 bytes) ‖ sessionKey.signMessage({ raw: userOpHash })`.
* **ERC-1271**: `abi.encodePacked(ECDSA_VALIDATOR, sig)` where `sig` = raw ECDSA over
  `ECDSAOwnerValidator.accountMessageDigest(account, hash)` (EIP-712 `AccountMessage(bytes32 hash)`, domain
  `VaultLiteECDSAValidator`/`1`/chainId/account).
* **Init data**: `abi.encodeCall(SmartAccount.initialize, (ModuleInit[]))`, at least one validator.
* **Escrow operator**: install `SessionKeyValidator` and enable a session for the operator key allowing only
  `MilestoneEscrow.{submitMilestone, claimAfterReview, withdraw}` with `nativeCap = 0`; optionally also add the operator
  to `EscrowExecutor` for keeper-driven calls.

## Build & test
```bash
git submodule update --init --recursive
forge build
forge test                       # unit + fuzz + invariant + Base Sepolia fork tests
forge coverage --no-match-coverage "(test|script)/"
slither . --filter-paths "lib/|test/|script/" --exclude-dependencies
```
Fork tests use `$BASE_SEPOLIA_RPC_URL` or fall back to `https://sepolia.base.org`, pinned to block 51,235,699. Unit tests
etch the real EntryPoint v0.7 + SenderCreator runtime bytecode from `test/fixtures/` (pulled from Base Sepolia), so
they run offline against the genuine EntryPoint.

Results at commit time: 67 tests pass (incl. 5 invariants × 128 runs × depth 64, fuzz 512 runs).
Coverage (src): lines 99.4%, statements 98.4%, branches 96.3%, functions 100%. Slither: 0 high/medium; see AUDIT_NOTES.

## Deploy (NOT run)
`script/Deploy.s.sol` deploys the factory (and implementation) plus all modules, reading `PRIVATE_KEY` from the
environment (see `.env.example`; `.env*` is git-ignored). Dry-run only:
```bash
forge script script/Deploy.s.sol --rpc-url base_sepolia        # simulation, no --broadcast
```
Broadcasting requires explicit approval. After deployment, stake the factory (`addStake`) for bundler acceptance.

## Layout
```
src/            account, factory, modules, interfaces
test/           unit/fuzz tests, invariant/, fork/, utils/, fixtures/ (EntryPoint v0.7 bytecode)
script/         Deploy.s.sol
```
