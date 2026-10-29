# VaultLite Smart Account

An ERC-4337 (EntryPoint **v0.7**) modular smart account in the ERC-7579 style. It comes with a CREATE2 factory, an
ECDSA owner validator, scoped session keys, guardian recovery with a timelock, and an executor for the deployed
MilestoneEscrow. It was built for the VaultLite mobile wallet.

> **Testnet only (Base Sepolia, chain 84532). Not audited.** Do not use with real funds.

## Stack
- Solidity **0.8.36**, EVM cancun, Foundry (forge-std v1.17.0)
- OpenZeppelin Contracts **5.7.0** (`AccountERC7579Hooked`, ECDSA, Clones)
- TypeScript e2e: **viem** 2.57.12 and **permissionless 0.5.2**, with **Pimlico** as bundler and verifying paymaster (sponsored ops)

## Contracts
| Contract | Role |
|---|---|
| `SmartAccount` | Immutable ERC-7579 account bound to EntryPoint v0.7. The validator is chosen by the top 20 bytes of the nonce key. Single and batch execution (delegatecall disabled), hooks and fallbacks, receives ETH, ERC-721 and ERC-1155, and routes ERC-1271 checks to validators. |
| `AccountFactory` | Deploys ERC-1167 clones with CREATE2. `getAddress(initData, salt)` returns the address before deployment, and the salt commits to the init data. Repeat calls are idempotent. The factory is staked in the EntryPoint. |
| `ECDSAOwnerValidator` | One secp256k1 owner per account. UserOps are signed with EIP-191 personal_sign over the raw userOpHash (65-byte r‖s‖v). ERC-1271 uses an account-bound EIP-712 rehash. |
| `SessionKeyValidator` | Session keys with a target and selector allowlist, a cumulative ETH cap, per-ERC-20 caps, validAfter/validUntil, a maximum number of uses, and revocation. |
| `RecoveryExecutor` | M-of-N guardians (strict majority) with a 48 h default timelock (24 h to 30 d). The owner can cancel. Guardians can approve with EIP-712 signatures, and guardian changes and uninstalling are timelocked. |
| `EscrowExecutor` | Lets an operator make zero-value calls to MilestoneEscrow: submit, claimAfterReview and withdraw, plus approveMilestone on whitelisted escrows up to a cap. |

There is no paymaster contract in this repo; sponsorship comes from Pimlico. The full flow and the error codes are in
[`docs/PIMLICO_FLOW.md`](docs/PIMLICO_FLOW.md). The design is in `SPEC.md`, `ARCHITECTURE.md` and `INTEGRATION.md`.

## Deployed addresses (Base Sepolia 84532)
All six contracts are exact matches on Sourcify and verified on Blockscout.

| Contract | Address |
|---|---|
| EntryPoint v0.7 (canonical) | [`0x0000000071727De22E5E9d8BAf0edAc6f37da032`](https://base-sepolia.blockscout.com/address/0x0000000071727De22E5E9d8BAf0edAc6f37da032) |
| AccountFactory | [`0xb5c86d7ec6a86074732e8b697a9f90cd8de0eff0`](https://base-sepolia.blockscout.com/address/0xb5c86d7ec6a86074732e8b697a9f90cd8de0eff0?tab=contract) |
| SmartAccount (implementation) | [`0x997f0ffcf65c272bbee57be2f50bb8712f276799`](https://base-sepolia.blockscout.com/address/0x997f0ffcf65c272bbee57be2f50bb8712f276799?tab=contract) |
| ECDSAOwnerValidator | [`0x45b0db483849bf723fe288751297cddc29e7198b`](https://base-sepolia.blockscout.com/address/0x45b0db483849bf723fe288751297cddc29e7198b?tab=contract) |
| SessionKeyValidator | [`0x93a4993b2047862a32864cef09233fdca718b3a2`](https://base-sepolia.blockscout.com/address/0x93a4993b2047862a32864cef09233fdca718b3a2?tab=contract) |
| RecoveryExecutor | [`0x5a1c201cc401b0b1d0e213d6e99201939688812c`](https://base-sepolia.blockscout.com/address/0x5a1c201cc401b0b1d0e213d6e99201939688812c?tab=contract) |
| EscrowExecutor | [`0x72a87a92c1373ae3c0f9e42c06e1e6c113d17ec6`](https://base-sepolia.blockscout.com/address/0x72a87a92c1373ae3c0f9e42c06e1e6c113d17ec6?tab=contract) |
| MilestoneEscrow (external) | [`0xD861488f2ba02df4047DDE41EFeCdCEd1FD6E528`](https://base-sepolia.blockscout.com/address/0xD861488f2ba02df4047DDE41EFeCdCEd1FD6E528) |

Factory stake: 0.01 ETH with a 1-day unstake delay, [tx](https://base-sepolia.blockscout.com/tx/0xf0a77738006fde302e109f0baa61e7467008cd0d5090484804551a670521d0b0).
The stake is needed because initialising an account writes module storage during validation (ERC-7562 rule STO-022).
Sourcify links follow the pattern `https://repo.sourcify.dev/84532/<address>`.

## Sponsored userOp proof
Pimlico's paymaster (`0x777777777777AeC03fd955926DbF81597e66834C`) sponsored all of these ops, and each account's ETH balance stayed at 0.

| Run | Account | Op 1: deploy + 0-value batch | Op 2: 0-value call |
|---|---|---|---|
| `e2e/results.json` | [`0xf4e3…0aCd`](https://base-sepolia.blockscout.com/address/0xf4e3050C87463386f55EaE70D83Cc86E50350aCd) | [0x9664be37…27b0](https://base-sepolia.blockscout.com/tx/0x9664be37188f97d2d9e03cdd6d303aa397cdaceedc9f17590b676648fd1927b0) | [0x88b65ee5…efee](https://base-sepolia.blockscout.com/tx/0x88b65ee59a0e9ffbf051d1ea88474a8bce7e9e27b9f921959519bb9226ebefee) |
| `e2e/demo-results.json` | [`0x88b0…7aa0`](https://base-sepolia.blockscout.com/address/0x88b07484fCe5B2f42A28199321Dc6c4cBf827aa0) | [0xec6d829b…d978](https://base-sepolia.blockscout.com/tx/0xec6d829bbdf4b419680026f931ca0d08ae107278060c9c99e0732005105ad978) | [0x90208ecc…1d77](https://base-sepolia.blockscout.com/tx/0x90208eccb0c4af9703a488b45f4ef21cfa829336d27af1cf155215bb6cef1d77) |

## Build, test and demo
```bash
git submodule update --init            # forge-std v1.17.0 and openzeppelin-contracts v5.7.0
forge build
forge test                             # unit, fuzz, invariant and Base Sepolia fork tests
forge coverage --no-match-coverage "(test|script)/"
```
The fork tests use `$BASE_SEPOLIA_RPC_URL`, falling back to `https://sepolia.base.org`, pinned to block 51,235,699.
They run a real `handleOps` against the live EntryPoint and MilestoneEscrow. Unit tests run offline against the real
EntryPoint v0.7 bytecode stored in `test/fixtures/`.

Demo: it deploys a fresh account and sends two sponsored ops, then prints explorer links.
```bash
cd e2e && npm ci
export PIMLICO_API_KEY=...             # read from the environment only, never printed (redacted from errors)
npm run demo                           # writes e2e/demo-results.json
```
The owner key is generated in memory for each run and never written to disk.

Deploy script (`script/Deploy.s.sol`): it reads `PRIVATE_KEY` from the environment (see `.env.example`). Without
`--broadcast` it is a dry run.

## Test and coverage results (measured 2026-10-29)
- `forge test`: **67 passed, 0 failed, 0 skipped** across 8 suites. That includes fuzz tests (512 runs), 5 handler-based
  invariants (128 runs × depth 64) and 2 fork tests.
- `forge coverage` on `src/`: lines **99.40%** (334/336), statements **98.37%** (422/429), branches **96.25%** (77/80),
  functions **100%** (76/76). `SessionKeyValidator` is the only file below 100%.
- Slither 0.11.6: no high or medium findings. Two were fixed and 23 low/informational ones are documented
  (`AUDIT_NOTES.md`, `slither-report.txt`).

## Security notes and limitations
(Summarised from [`AUDIT_NOTES.md`](AUDIT_NOTES.md).)
- **Not audited.** This is a self-review only, and the contracts are for testnet only.
- Accounts are **immutable** clones with no upgrade path. Fixing a bug means a new factory and migrating funds.
- Owner-key theft: a thief can cancel recoveries or install another validator. Uninstalling recovery and changing
  guardians are timelocked, and guardians can only rotate the ECDSA owner.
- Uninstalling the last validator locks the account. The contracts don't prevent it, so the UI must.
- Session spend and use counts are updated during validation, so an op that later reverts still counts.
  Token-moving selectors need an explicit per-token cap. Only default exec type with single or batch calls is accepted.
- Session and operator state is wiped on uninstall through a per-account epoch. Session IDs depend on that epoch.
- ERC-1271 uses an ERC-7739-*style* account-bound rehash, not full ERC-7739 nested typed data.
- Fork tests call `handleOps` directly, so they don't exercise bundler (ERC-7562) simulation. The live Pimlico e2e
  runs above do.
- High-s signatures are rejected. Delegatecall execution is disabled.

## Layout
```
src/        SmartAccount, AccountFactory, modules/, interfaces/
test/       unit + fuzz, invariant/, fork/, utils/, fixtures/
script/     Deploy.s.sol
e2e/        viem + permissionless demo (toSmartAccount adapter)
docs/       PIMLICO_FLOW.md, VAULTLITE_PLAN.md
```

## License
MIT. See [LICENSE](LICENSE).
