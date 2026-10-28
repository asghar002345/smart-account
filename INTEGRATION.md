# VaultLite (React Native / Expo) Integration

Stack: `viem` + `permissionless` (latest seen: `permissionless@0.5.2`, GitHub, 2026-10-23;
npm showed 0.5.0 at check time — [releases](https://github.com/pimlicolabs/permissionless.js/releases)).
Since 0.5.0, `ox` is a regular dependency (fixes peer-dep resolution errors); pin viem to a version
compatible with the ox version permissionless pulls in.

## 1. Config
```ts
import { baseSepolia } from "viem/chains";
import { entryPoint07Address } from "viem/account-abstraction";
export const CHAIN = baseSepolia;                    // 84532
export const ENTRYPOINT = { address: entryPoint07Address, version: "0.7" as const };
export const PIMLICO_URL =
  `https://api.pimlico.io/v2/base-sepolia/rpc?apikey=${process.env.EXPO_PUBLIC_PIMLICO_API_KEY}`;
export const ESCROW = "0xD861488f2ba02df4047DDE41EFeCdCEd1FD6E528";
```
URL format per [Pimlico supported chains](https://docs.pimlico.io/guides/supported-chains) (`base-sepolia` or `84532`).
Note: an `EXPO_PUBLIC_` key is shipped in the app bundle. Acceptable for testnet; for production proxy
the bundler/paymaster through a backend or use Pimlico sponsorship policies with domain/app restrictions.

## 2. Owner signer from seed
```ts
import { mnemonicToAccount } from "viem/accounts";
const owner = mnemonicToAccount(mnemonic, { addressIndex: 0 }); // m/44'/60'/0'/0/0
```
RN polyfills typically needed: `react-native-get-random-values` (import first), and a `Buffer`/`TextEncoder`
polyfill depending on Hermes/Expo SDK version — verify against the current Expo SDK.

## 3. Custom account adapter
Since the account is custom (OZ-based), wrap it with viem's `toSmartAccount`:
```ts
import { toSmartAccount, getUserOperationHash } from "viem/account-abstraction";
const account = await toSmartAccount({
  client: publicClient,
  entryPoint: ENTRYPOINT,
  async getAddress() { return predicted /* factory.getAddress(initData, salt) */ },
  async getFactoryArgs() { return { factory: FACTORY, factoryData: encodeCreateAccount(initData, salt) } },
  async encodeCalls(calls) { return calls.length === 1 ? encodeSingle(calls[0]) : encodeBatch(calls) }, // ERC-7579 execute(mode, data)
  async getNonce() { return readEntryPointNonce(sender, keyFor(ECDSA_VALIDATOR)) },
  async getStubSignature() { return STUB_65_BYTES },
  async signUserOperation(op) {
    const hash = getUserOperationHash({ userOperation: op, entryPointAddress: ENTRYPOINT.address, entryPointVersion: "0.7", chainId: CHAIN.id });
    return owner.signMessage({ message: { raw: hash } }); // must match validator (SPEC open decision 4)
  },
  async signMessage({ message }) { /* ERC-1271 wrapped per ERC-7739 */ },
  async signTypedData(td) { /* ERC-7739 */ },
});
```
(Exact `toSmartAccount` field names: verify against the pinned viem version.) If the base becomes Kernel,
replace with `toKernelSmartAccount` from `permissionless/accounts`.

## 4. Clients
```ts
import { createSmartAccountClient } from "permissionless";
import { createPimlicoClient } from "permissionless/clients/pimlico";
const pimlico = createPimlicoClient({ transport: http(PIMLICO_URL), entryPoint: ENTRYPOINT });
export const smart = createSmartAccountClient({
  account, chain: CHAIN, bundlerTransport: http(PIMLICO_URL),
  paymaster: pimlico,                                    // ERC-7677 sponsorship
  userOperation: { estimateFeesPerGas: async () => (await pimlico.getUserOperationGasPrice()).fast },
});
```
Pattern from [Pimlico tutorial](https://github.com/pimlicolabs/tutorials/blob/main/tutorial-2.ts) and
[Pimlico client docs](https://docs.pimlico.io/references/permissionless/reference/clients/pimlicoClient).
`sendUserOperationSync` (permissionless 0.5.1+) can be used to send and await the receipt.

## 5. App flows
| Flow | Calls |
|---|---|
| Onboard | derive owner → predict address → show address (counterfactual); first op deploys |
| Send | `smart.sendTransaction({ calls: [...] })` batch |
| Create+fund escrow | batch `[approve, createEscrow, fund]` (see ARCHITECTURE §5.2 caveat on escrowId) |
| Approve milestone | owner op `approveMilestone`, or off-chain ERC-1271 sig → `approveMilestoneWithSig` relayed |
| Session key | generate key → owner op `enableSession(policy)` → store key in SecureStore → ops use session nonce key |
| Recovery | guardian UI signs EIP-712 approvals; owner device shows pending recovery + cancel button |
| Passkey (later) | `react-native-passkey`-style lib → install PasskeyValidator → WebAuthn signatures |

## 6. Error handling
Surface bundler errors (AAxx codes from EntryPoint: e.g. AA21 prefund, AA23 validation reverted, AA25 nonce),
poll `getUserOperationReceipt`, idempotent resend only when safe.

## 7. Env / secrets
`EXPO_PUBLIC_PIMLICO_API_KEY` (testnet only), `BASE_SEPOLIA_RPC`. Never commit; `.env` in `.gitignore`.
