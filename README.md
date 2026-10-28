# VaultLite Smart Account

Modular ERC-4337 / ERC-7579 smart account for the VaultLite wallet on **Base Sepolia (84532)**, bound to
**EntryPoint v0.7** `0x0000000071727De22E5E9d8BAf0edAc6f37da032`. See `SPEC.md`, `ARCHITECTURE.md`,
`INTEGRATION.md` and `AUDIT_NOTES.md`. Deployed to Base Sepolia, see [Deployments](#deployments--base-sepolia-84532).

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

## Deployments — Base Sepolia (84532)

Deployed 2026-10-28 by `0x4f5D696b46F4946404A30869E28e8DaB04272DD6` (also the factory owner), compiled with solc 0.8.36. Every contract is an exact match on Sourcify and fully verified on Blockscout.

| Contract | Address | Deploy tx | Verification |
|---|---|---|---|
| AccountFactory | `0xb5c86d7ec6a86074732e8b697a9f90cd8de0eff0` | [0x1b4a7282…](https://base-sepolia.blockscout.com/tx/0x1b4a72823b3d02cab290f10c43b74b1f3ded552dabf84a5ac368eed12937b064) | [Blockscout](https://base-sepolia.blockscout.com/address/0xb5c86d7ec6a86074732e8b697a9f90cd8de0eff0?tab=contract) · [Sourcify](https://repo.sourcify.dev/84532/0xb5c86d7ec6a86074732e8b697a9f90cd8de0eff0) |
| SmartAccount (implementation, created by factory) | `0x997f0ffcf65c272bbee57be2f50bb8712f276799` | [0x1b4a7282…](https://base-sepolia.blockscout.com/tx/0x1b4a72823b3d02cab290f10c43b74b1f3ded552dabf84a5ac368eed12937b064) | [Blockscout](https://base-sepolia.blockscout.com/address/0x997f0ffcf65c272bbee57be2f50bb8712f276799?tab=contract) · [Sourcify](https://repo.sourcify.dev/84532/0x997f0ffcf65c272bbee57be2f50bb8712f276799) |
| ECDSAOwnerValidator | `0x45b0db483849bf723fe288751297cddc29e7198b` | [0x04239027…](https://base-sepolia.blockscout.com/tx/0x042390276bd1683cae4af6ba9537e4bd80b5a1c0b82d87f3ff25a2e42c56ac3d) | [Blockscout](https://base-sepolia.blockscout.com/address/0x45b0db483849bf723fe288751297cddc29e7198b?tab=contract) · [Sourcify](https://repo.sourcify.dev/84532/0x45b0db483849bf723fe288751297cddc29e7198b) |
| SessionKeyValidator | `0x93a4993b2047862a32864cef09233fdca718b3a2` | [0xb85d1da6…](https://base-sepolia.blockscout.com/tx/0xb85d1da63fb5746cfaeb1ed5e08f61a0337556e8769714e6a88d1f104823121f) | [Blockscout](https://base-sepolia.blockscout.com/address/0x93a4993b2047862a32864cef09233fdca718b3a2?tab=contract) · [Sourcify](https://repo.sourcify.dev/84532/0x93a4993b2047862a32864cef09233fdca718b3a2) |
| RecoveryExecutor | `0x5a1c201cc401b0b1d0e213d6e99201939688812c` | [0xe9bacc88…](https://base-sepolia.blockscout.com/tx/0xe9bacc88e0f3acae1f543fb08b512fde82acfb3735d595501ef847bca62c2b01) | [Blockscout](https://base-sepolia.blockscout.com/address/0x5a1c201cc401b0b1d0e213d6e99201939688812c?tab=contract) · [Sourcify](https://repo.sourcify.dev/84532/0x5a1c201cc401b0b1d0e213d6e99201939688812c) |
| EscrowExecutor | `0x72a87a92c1373ae3c0f9e42c06e1e6c113d17ec6` | [0x89a0a203…](https://base-sepolia.blockscout.com/tx/0x89a0a20333a8ce8551ad8c5db86efbdad71e9371e1861285e771424f7b89ccb9) | [Blockscout](https://base-sepolia.blockscout.com/address/0x72a87a92c1373ae3c0f9e42c06e1e6c113d17ec6?tab=contract) · [Sourcify](https://repo.sourcify.dev/84532/0x72a87a92c1373ae3c0f9e42c06e1e6c113d17ec6) |

Factory stake in EntryPoint v0.7 (`0x0000000071727De22E5E9d8BAf0edAc6f37da032`): 0.01 ETH with a 1-day (86,400 s) unstake delay. Tx: [0xf0a77738…](https://base-sepolia.blockscout.com/tx/0xf0a77738006fde302e109f0baa61e7467008cd0d5090484804551a670521d0b0).
EscrowExecutor is bound to the MilestoneEscrow at `0xD861488f2ba02df4047DDE41EFeCdCEd1FD6E528`.

### E2E: sponsored userOps through Pimlico (2026-10-28)
`e2e/e2e.ts` (viem 2.57.12, permissionless 0.5.2, custom `toSmartAccount` adapter) generates an ephemeral owner in memory and sends two userOps through EntryPoint v0.7, both sponsored by the Pimlico paymaster `0x777777777777AeC03fd955926DbF81597e66834C`. The account's ETH balance stayed at 0.

- Account: [`0xf4e3050C87463386f55EaE70D83Cc86E50350aCd`](https://base-sepolia.blockscout.com/address/0xf4e3050C87463386f55EaE70D83Cc86E50350aCd)
- Op 1 (deploys the account via initCode, then a 0-value batch): userOp `0x0b2cc70ea54f0a5ed2d90eb32dd8d8eb800f951261479a22e74a741d5cbb1f80`, tx [`0x9664be37…`](https://base-sepolia.blockscout.com/tx/0x9664be37188f97d2d9e03cdd6d303aa397cdaceedc9f17590b676648fd1927b0)
- Op 2 (0-value single call): userOp `0x41ce32c95c72ef4a71b3ff4dbe63e8f9e8fad70b3477a6aea6ed29cee364e144`, tx [`0x88b65ee5…`](https://base-sepolia.blockscout.com/tx/0x88b65ee59a0e9ffbf051d1ea88474a8bce7e9e27b9f921959519bb9226ebefee)

Run it with `cd e2e && npm ci && PIMLICO_API_KEY=... npm run e2e`. The key is read from the environment only and is redacted from error output. Results are written to `e2e/results.json`.

## Deploy
`script/Deploy.s.sol` deploys the factory (and implementation) plus all modules, reading `PRIVATE_KEY` from the
environment (see `.env.example`; `.env*` is git-ignored). Dry-run only:
```bash
forge script script/Deploy.s.sol --rpc-url base_sepolia        # simulation, no --broadcast
```
Broadcasting needs explicit approval (the testnet deployment above was approved). After deployment, stake the factory (`addStake`) for bundler acceptance.

## Layout
```
src/            account, factory, modules, interfaces
test/           unit/fuzz tests, invariant/, fork/, utils/, fixtures/ (EntryPoint v0.7 bytecode)
script/         Deploy.s.sol
```
