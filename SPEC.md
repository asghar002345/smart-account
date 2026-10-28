# VaultLite Smart Account — Specification

Status: draft v0.1 (docs only, nothing deployed) · Date: 2026-10-28 · Author: Hammad Asghar

## 1. Goal
A modular ERC-4337 smart account for the VaultLite React Native/Expo wallet, deployed on
**Base Sepolia (chain 84532)** against **EntryPoint v0.7**, that:
- is owned by one EOA derived from the wallet's seed phrase (the mobile dev's preferred signer);
- can later add a passkey (secp256r1 / RIP-7212) validator as an optional module;
- supports session keys, guardian social recovery with timelock, batched execution, ERC-1271;
- ships an executor module that drives the already-deployed **MilestoneEscrow**
  (`0xD861488f2ba02df4047DDE41EFeCdCEd1FD6E528`, Base Sepolia, Sourcify exact match per
  `/workspace/milestone-escrow/README.md`);
- has a CREATE2 factory with counterfactual addresses;
- uses gas sponsorship (see §8 recommendation).

Non-goals (v1): mainnet deployment, multi-chain address sync, EIP-7702, token paymaster,
cross-chain session keys, formal audit.

## 2. Verified external facts (checked 2026-10-28)
| Fact | Value | Source |
|---|---|---|
| EntryPoint v0.7 address | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | [eth-infinitism v0.7.0 release](https://github.com/eth-infinitism/account-abstraction/releases), [Etherscan](https://etherscan.io/address/0x0000000071727de22E5E9d8BAf0edAc6f37da032) |
| Pimlico supports EP v0.7 bundler + paymaster on Base Sepolia | yes (also v0.6, v0.8; v0.9 bundler only) | [Pimlico supported chains](https://docs.pimlico.io/guides/supported-chains) |
| Pimlico RPC format | `https://api.pimlico.io/v2/{chainId or slug}/rpc?apikey=KEY` (slug `base-sepolia` or `84532`) | same |
| Newer EntryPoints exist | v0.8 `0x4337084d…ff108`, v0.9 `0x433709009B8330FDa32311DF1C2AFA402eD8D009`; Etherscan now encourages v0.9 | [eth-infinitism releases](https://github.com/eth-infinitism/account-abstraction/releases), Etherscan banner |
| permissionless.js latest | `permissionless@0.5.2` on GitHub (2026-10-23); npm page showed 0.5.0 at check time | [GitHub releases](https://github.com/pimlicolabs/permissionless.js/releases), [npm](https://www.npmjs.com/package/permissionless) |
| permissionless 0.5.0 breaking change | `ox` is now a regular dependency; `getOxExports`/`hasOxModule` removed | GitHub releases |
| EP v0.7 constant in viem | `entryPoint07Address` from `viem/account-abstraction` | [Pimlico migration guide](https://docs.pimlico.io/references/permissionless/how-to/migration-guide) |

Items NOT verified this pass (must check before M1, see OPEN DECISIONS): exact current versions of
Safe7579, Kernel v3.x, OpenZeppelin Community Contracts AA modules, Foundry; RIP-7212 precompile
availability/address on Base Sepolia (commonly cited as `0x…0100` since the Fjord upgrade; confirm on-chain).

> Note: EP v0.7 was chosen by requirement. It is older than v0.8/v0.9; v0.8 adds native EIP-7702 support.
> Staying on v0.7 is fine for a testnet portfolio project and is what Pimlico, Safe and Kernel support
> most widely on Base Sepolia today (Pimlico table). Revisit for mainnet.

## 3. Actors
| Actor | Description |
|---|---|
| Owner EOA | secp256k1 key derived from VaultLite seed phrase (BIP-44 `m/44'/60'/0'/0/0` default). Root authority via the ECDSA validator. |
| Passkey (future) | WebAuthn P-256 credential, installed as a second validator module. |
| Session key | Ephemeral secp256k1 key held by the app/dApp; scoped policy. |
| Guardians | N addresses (EOAs or contracts); threshold M-of-N can propose owner rotation. |
| Bundler | Pimlico, Base Sepolia. |
| Paymaster | Pimlico verifying paymaster (recommended) or own `VerifyingPaymaster`. |
| MilestoneEscrow | External contract; authorizes on `msg.sender`, so the account itself is the client/provider. |

## 4. Functional requirements
### 4.1 Account core (ERC-7579)
- `validateUserOp(PackedUserOperation, bytes32, uint256)` (EP v0.7), only callable by EntryPoint.
- Validator selection via the **UserOp nonce key** (upper 192 bits encode validator address), as in Kernel/Safe7579 practice.
- `execute(bytes32 mode, bytes executionCalldata)` supporting call types `single`, `batch`
  (`delegatecall` disabled in v1). Exec type `default` (revert) and `try` (collect results).
- `executeFromExecutor(mode, calldata)` callable only by installed executor modules.
- `installModule / uninstallModule / isModuleInstalled` for types 1 validator, 2 executor, 3 fallback, 4 hook.
- `supportsExecutionMode`, `supportsModule`, `accountId()`.
- ERC-1271 `isValidSignature(hash, sig)`: routes to a validator encoded in the signature prefix;
  uses ERC-7739-style defensive rehashing to prevent cross-account replay of the same owner's signature.
- Receives ETH, ERC-721/1155 (fallback handler).

### 4.2 Owner validator (ECDSA)
- Stores one owner address per account. Valid signature = ECDSA over the userOpHash
  (EIP-191 personal-sign wrapped, matching viem `signMessage({ raw })` behaviour; final choice in INTEGRATION.md).
- `rotateOwner(newOwner)` callable only by the account (i.e. via owner-signed op or recovery module).

### 4.3 Passkey validator (optional, later)
- Stores `(x, y, credentialIdHash)`; verifies WebAuthn assertion. Uses RIP-7212 precompile when present,
  falls back to a Solidity P-256 verifier (e.g. OpenZeppelin `P256` / daimo verifier) otherwise.
- Must be installable/uninstallable without touching the ECDSA validator. Not required for v1.

### 4.4 Session keys (validator module + policies)
Each session: `{ sessionKey, validAfter, validUntil, policies[] }` stored per account, id = hash.
Policies (all must pass):
- **Target allowlist**: set of `(target, selector)` pairs; batch ops checked element-wise.
- **Spend limit**: native ETH value cap per session (cumulative), and per-ERC-20 cap on `transfer`/`approve` amounts.
- **Expiry**: returned in `validationData` (`validUntil/validAfter`) so EntryPoint enforces time.
- **Use count** (optional): max number of UserOps.
- Revocation by owner at any time; enable/disable only by an owner-validated op.
Cumulative spend is updated in validation phase in account-associated storage (ERC-7562 compliant: storage keyed by account address).

### 4.5 Social recovery (executor module)
- Config: guardians (N ≤ 10), threshold M, timelock `T` (default 48h, min 24h, max 30d).
- `proposeRecovery(account, newOwner)` + guardian approvals (on-chain calls or EIP-712 sigs).
- Once M approvals: `readyAt = now + T`. Owner can `cancelRecovery` during the window.
- `executeRecovery` after `readyAt` calls `account.executeFromExecutor` → `ECDSAValidator.rotateOwner`.
- Guardian set changes by owner are themselves timelocked (prevents a thief with the key from removing guardians instantly — they can still cancel recovery; see threat model).
- Nonce per recovery to prevent replay of guardian signatures.

### 4.6 Batched execution
Native via ERC-7579 batch mode. App-level: "approve + createEscrow + fund" in one UserOp.

### 4.7 Escrow executor module
Targets the `IEscrowModule` surface of MilestoneEscrow (createEscrow, fund, submitMilestone,
approveMilestone, claimAfterReview, raiseDispute, withdraw; plus view `withdrawable`).
Two uses:
1. **Direct owner path** – no module needed; the account batch-calls the escrow (escrow authorizes on `msg.sender`).
2. **Automation path** – `EscrowExecutor` lets a configured *operator* (e.g. a session key, keeper,
   or the app backend) call a **restricted** subset on the account's behalf via `executeFromExecutor`:
   - provider side: `submitMilestone`, `claimAfterReview`, `withdraw(token)` — funds always land in the account;
   - client side: `approveMilestone` only for escrows the owner whitelisted, with optional per-escrow cap.
   - never `createEscrow`/`fund`/`raiseDispute` via operator (owner-only).
- Escrow address is immutable in the module (`0xD861…E528` on 84532).
- MilestoneEscrow's `approveMilestoneWithSig` uses `SignatureChecker`, so the account's ERC-1271 lets an
  account-client approve off-chain; signatures are relayable by anyone.

### 4.8 Factory
- `createAccount(bytes initData, bytes32 salt)` → ERC-1967 proxy via CREATE2 (or ERC-1167 clone; decision open).
- `getAddress(initData, salt)` view returns counterfactual address; salt bound to `keccak(initData, userSalt)`
  so the address commits to the initial owner (prevents front-run init with a different owner).
- Idempotent: returns existing account if already deployed (EP v0.7 requires `initCode` to deploy exactly the sender).
- Factory staked in EntryPoint if it reads account-external storage (ERC-7562 rules).

### 4.9 Paymaster (see §8)

## 5. Non-functional
- Solidity 0.8.2x, Foundry, OpenZeppelin Contracts 5.x; Cancun EVM (Base supports it).
- Comply with ERC-7562 validation rules (no banned opcodes, storage access limited to account-associated slots in validation).
- Upgradeability: UUPS via ERC-1967 (owner-only `upgradeToAndCall`), documented; or immutable — open decision.
- Gas target (informational): deploy+first op < 400k gas; single transfer op < 120k.

## 6. Build vs extend (summary; detail in ARCHITECTURE.md §6)
| Option | Pros | Cons |
|---|---|---|
| From scratch | Max learning signal | Highest risk; re-implementing audited code |
| eth-infinitism SimpleAccount | Tiny, canonical | Not modular; would need all 7579 plumbing anyway |
| Kernel v3 (ZeroDev) | Mature 7579, audited, permissionless.js `toKernelSmartAccount` | Complex codebase; ZeroDev-specific conventions |
| Safe7579 (Rhinestone) | Safe security base, 7579 adapter, audited | Two layers (Safe + adapter), higher gas, harder to "own" |
| OZ Community AA (`AccountERC7579`) | Clean building blocks, OZ style, good to extend | Newer; check audit status/version |

**Recommendation:** build the account on **OpenZeppelin's ERC-7579 account building blocks**
(own thin account + factory), and write the **modules yourself** (ECDSA owner, session keys, recovery,
escrow executor). Use Kernel/Safe7579 + Rhinestone modules as reference implementations and as a
differential-test oracle. Rationale: portfolio value comes from the modules and the integration; OZ
removes the riskiest plumbing; staying 7579-standard keeps modules portable to Kernel/Safe7579.
Fallback if OZ AA proves immature: Kernel v3 + custom modules (permissionless.js supports it natively).

## 7. Bundler
Pimlico: `https://api.pimlico.io/v2/base-sepolia/rpc?apikey=${PIMLICO_API_KEY}`.
An API key is required for this project (free tier). Pimlico docs mention a key-less public endpoint
(with limits); not relied upon. Key lives in app config, never in the repo.

## 8. Paymaster recommendation
| | Pimlico verifying paymaster (sponsorship policies) | Own `VerifyingPaymaster` |
|---|---|---|
| Effort | ~0 contracts; dashboard policy | Contract + signer service + EP deposit + stake |
| Ops | Pimlico manages deposit/signing | You fund deposit, run & secure signing key |
| Portfolio signal | Low | Medium–high |
| Risk | Vendor lock, quotas | Key compromise drains deposit |
**Recommendation:** use **Pimlico sponsorship (ERC-7677 via `createPimlicoClient`) for the app**, and
build an own `VerifyingPaymaster` as a **stretch milestone (M6)**, tested in fork tests only, optionally
deployed to testnet behind a feature flag. Keeps the app shippable without running a signing service.

## 9. Threat model
See ARCHITECTURE.md §8.

## 10. Test plan
See ARCHITECTURE.md §9.

## 11. Milestones (estimates for one developer, ideal days)
| # | Scope | Est. |
|---|---|---|
| M0 | Repo scaffold, Foundry, deps pinned, CI, verify open versions | 1 d |
| M1 | Account core (OZ 7579), ECDSA validator, factory, ERC-1271 + unit tests | 4 d |
| M2 | Fork test vs real EntryPoint v0.7 on Base Sepolia fork; Pimlico e2e script (testnet) | 2 d |
| M3 | Session key validator + policies + fuzz/invariant tests | 5 d |
| M4 | Recovery module with timelock + tests | 3 d |
| M5 | Escrow executor + fork tests against deployed MilestoneEscrow | 3 d |
| M6 | (stretch) own VerifyingPaymaster + signer script | 3 d |
| M7 | VaultLite integration (custom account in permissionless/viem), Expo demo flows | 4 d |
| M8 | Slither/Aderyn, gas report, docs, testnet deploy (only after approval) | 2 d |
| M9 | (later) Passkey validator | 4 d |
Total core (M0–M5, M7–M8): ~24 d; with stretch: ~31 d.

## 12. Open decisions (need Hammad)
1. **EntryPoint version**: confirm v0.7 (as required) vs v0.8/v0.9 (newer; Etherscan recommends v0.9; Pimlico has no v0.9 paymaster on Base Sepolia yet).
2. **Base**: OZ 7579 building blocks (recommended) vs Kernel v3 vs Safe7579.
3. **Upgradeable (UUPS)** vs immutable account implementation.
4. **Owner sig format**: raw ECDSA over userOpHash vs EIP-191 wrapped (must match VaultLite signer).
5. **Paymaster**: Pimlico sponsorship only, or also build own (M6)?
6. **Recovery defaults**: guardian count/threshold, timelock length, whether guardians may be email/off-chain services.
7. **Escrow executor operator**: who holds the operator key (session key on device vs backend keeper)?
8. **Session key storage on device**: Expo SecureStore vs in-memory only.
9. **Factory proxy type**: ERC-1967 proxy (upgradeable) vs ERC-1167 clone.
10. **Deployments**: who funds/approves any testnet deploy and Pimlico key provisioning.
