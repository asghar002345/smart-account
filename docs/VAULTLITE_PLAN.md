# Plan: smart account in VaultLite (`feat/smart-account`)

Plan only — no code is changed in the VaultLite repo by this document. Testnet only (Base Sepolia 84532).

## Current state (checked read-only, 2026-10-28)
`/workspace/vaultlite` already has a local `feat/smart-account` branch (3 commits by "VaultLite Dev", latest `0cf239e`)
with `src/modules/smartAccount/` (`config.ts` with the deployed addresses, `encoding.ts`, `read.ts`, `types.ts`,
`VaultLiteSmartAccountProvider.ts`), a bundler-proxy design (no Pimlico key in the app), tests, and a Settings screen
showing "bundler not configured". The steps below build on that branch rather than restarting it; coordinate with
the VaultLite agent so only one owner commits to the branch.

## Steps
1. **Module layout** — keep everything under `src/modules/smartAccount/`:
   `config.ts` (addresses, EntryPoint, proxy URL), `abis.ts`, `encoding.ts` (initData, ERC-7579 single/batch, nonce key),
   `account.ts` (new: `toSmartAccount` adapter), `client.ts` (new: smart-account + Pimlico clients via the proxy),
   `sessions.ts` (new: session keys), `recovery.ts` (new), `escrow.ts` (new: escrow call builders), `read.ts`,
   `types.ts`, `index.ts`, and `__tests__/`. UI stays in `app/` and `components/`.
2. **`toSmartAccount` adapter** — port `e2e/e2e.ts` from the smart-account repo: `getAddress` = `factory.getAddress`,
   `getFactoryArgs` = `createAccount(initData, 0x0)`, `encodeCalls` (single/batch), `getNonce` with key
   `validator << 32`, 65-byte stub signature, `signUserOperation`, and `signTypedData` using the ERC-1271
   `AccountMessage` wrapper (`ECDSA validator ‖ sig`). Either wrap or replace `VaultLiteSmartAccountProvider` so there is
   one code path; pin viem/permissionless versions (permissionless 0.5.x).
3. **Owner** — derive with `mnemonicToAccount(mnemonic, { addressIndex: 0 })` (path `m/44'/60'/0'/0/0`, existing
   `crypto/derive.ts`) and sign with `owner.signMessage({ message: { raw: userOpHash } })`. Never persist the private
   key outside the existing encrypted vault; unlock with biometrics per op (or per session window).
4. **Clients** — `createSmartAccountClient` with `bundlerTransport` and `paymaster` pointing at the bundler proxy
   (`EXPO_PUBLIC_BUNDLER_PROXY_URL/api/bundler/84532`); the proxy holds `PIMLICO_API_KEY` and enforces method/chain
   allowlists, rate limits and the sponsorship policy. Gas price from `pimlico_getUserOperationGasPrice` (fast).
5. **Onboarding & status** — show the counterfactual address before deployment; first send deploys it. Check that the
   app-computed address equals `factory.getAddress` (test vector + live read).
6. **Session keys** — generate a secp256k1 key on device, store it in `expo-secure-store`
   (`requireAuthentication`, `WHEN_UNLOCKED_THIS_DEVICE_ONLY`), enable it with an owner-signed op
   `SessionKeyValidator.enableSession` (targets/selectors, ETH cap, token caps, `validUntil`, `maxUses`), compute the
   id with `sessionIdOf` after install, and send ops with the session nonce key and `sessionId ‖ sig`. Revoke from
   Settings; short expiry by default; delete the key on revoke/expiry.
7. **Escrow flows** — reuse `src/modules/escrow`:
   client: one batched op `[createEscrow, fund]` (predict `escrowId` from `nextEscrowId`, or split into 2 ops if a race
   is detected), `approveMilestone` (owner op) or off-chain ERC-1271 `approveMilestoneWithSig` (relayable);
   provider: `submitMilestone` / `claimAfterReview` / `withdraw` with the scoped operator session key;
   optional keeper path via `EscrowExecutor` (whitelisted escrows + cap). Show AA-error copy from `PIMLICO_FLOW.md`.
8. **Recovery UI** — Settings → Recovery: show guardians (2-of-3), threshold and 48 h timelock; guardian approval via
   EIP-712 signatures (share link/QR); a pending-recovery banner with countdown and a **Cancel** button (owner op
   `cancelRecovery`); guardian changes and uninstall show their timelock.
9. **Testing** — unit (Jest): encoding, address derivation vs factory, signature vectors vs the Solidity tests, session
   id, error mapping; integration: mocked bundler-proxy JSON-RPC; testnet e2e via the proxy on Base Sepolia (deploy,
   batch, session op, escrow create→fund→submit→approve→withdraw); manual QA on real iOS + Android devices
   (SecureStore, biometrics, backgrounding mid-op). Keep the existing Jest suite and `tsc` green.
10. **Release gates** — feature flag (Base Sepolia only), no `EXPO_PUBLIC_` Pimlico key, review by Hammad before any
    push/PR, independent security review before mainnet.

## Risks
| Risk | Mitigation |
|---|---|
| Two agents committing to `feat/smart-account` | Single owner for the branch; rebase/merge only with Hammad's approval. |
| Pimlico key leaking via the app bundle | Proxy only; scan the bundle in CI. |
| Address mismatch (initData/salt drift) | Shared test vectors; assert `getAddress` before first send. |
| Owner key exposure (signing in JS) | Existing encrypted vault + biometrics; keep keys in memory only briefly. |
| Session key theft | SecureStore device-only, short expiry, caps, revocation. |
| Lost owner key / theft race with recovery | Guardian onboarding UX, cancel banner, push notification on recovery proposal (later). |
| Sponsorship quota / policy rejections (AA33) | Clear error copy; fallback "pay with ETH" path (later). |
| Escrow id race in batch | Read `nextEscrowId` just before signing; split ops on failure. |
| ERC-7562 changes / bundler rejections | Factory stays staked; run demo regularly. |
| Testnet only | Not audited; no mainnet without review. |
