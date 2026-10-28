/**
 * VaultLite smart account e2e (Base Sepolia, EntryPoint v0.7, Pimlico bundler + sponsorship).
 * - PIMLICO_API_KEY is read from process.env only and redacted from all output.
 * - The owner key is generated in memory per run and never persisted.
 * Usage: PIMLICO_API_KEY=... npm run e2e   (writes non-secret results to e2e/results.json)
 */
import { writeFileSync } from "node:fs";
import {
  createPublicClient, http, encodeFunctionData, encodeAbiParameters, encodePacked, concat, pad, toHex,
  hashTypedData, type Address, type Hex,
} from "viem";
import { baseSepolia } from "viem/chains";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import {
  entryPoint07Address, entryPoint07Abi, getUserOperationHash, toSmartAccount,
} from "viem/account-abstraction";
import { createSmartAccountClient } from "permissionless";
import { createPimlicoClient } from "permissionless/clients/pimlico";

const KEY = process.env.PIMLICO_API_KEY;
const OUT = process.argv.includes("--demo") ? "./demo-results.json" : "./results.json";
const EXPLORER = "https://base-sepolia.blockscout.com";
const redact = (s: string) => (KEY ? s.split(KEY).join("***") : s);
if (!KEY) { console.error("PIMLICO_API_KEY not set"); process.exit(1); }

const FACTORY: Address = "0xb5c86d7ec6a86074732e8b697a9f90cd8de0eff0";
const ECDSA_VALIDATOR: Address = "0x45b0db483849bf723fe288751297cddc29e7198b";
const PIMLICO_URL = `https://api.pimlico.io/v2/base-sepolia/rpc?apikey=${KEY}`;
const ENTRYPOINT = { address: entryPoint07Address, version: "0.7" as const };

const factoryAbi = [
  { type: "function", name: "createAccount", stateMutability: "nonpayable",
    inputs: [{ name: "initData", type: "bytes" }, { name: "salt", type: "bytes32" }], outputs: [{ type: "address" }] },
  { type: "function", name: "getAddress", stateMutability: "view",
    inputs: [{ name: "initData", type: "bytes" }, { name: "salt", type: "bytes32" }], outputs: [{ type: "address" }] },
] as const;
const accountAbi = [
  { type: "function", name: "initialize", stateMutability: "nonpayable",
    inputs: [{ name: "modules", type: "tuple[]", components: [
      { name: "moduleTypeId", type: "uint256" }, { name: "module", type: "address" }, { name: "initData", type: "bytes" }] }],
    outputs: [] },
  { type: "function", name: "execute", stateMutability: "payable",
    inputs: [{ name: "mode", type: "bytes32" }, { name: "executionCalldata", type: "bytes" }], outputs: [] },
] as const;
const validatorAbi = [
  { type: "function", name: "ownerOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "address" }] },
] as const;

const MODE_SINGLE = pad("0x00", { size: 32, dir: "right" });
const MODE_BATCH = pad("0x01", { size: 32, dir: "right" });
// validator address in the top 20 bytes of the 192-bit nonce key, 4-byte lane = 0
const NONCE_KEY = BigInt(ECDSA_VALIDATOR) << 32n;
// well-formed 65-byte stub (recovers to a random address -> SIG_VALIDATION_FAILED, never reverts)
const STUB_SIG: Hex = concat([
  "0xfffffffffffffffffffffffffffffff0000000000000000000000000000000007aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "0x1c",
]);

async function main() {
  const publicClient = createPublicClient({ chain: baseSepolia, transport: http("https://sepolia.base.org") });
  const owner = privateKeyToAccount(generatePrivateKey()); // ephemeral, memory only

  const initData = encodeFunctionData({
    abi: accountAbi, functionName: "initialize",
    args: [[{ moduleTypeId: 1n, module: ECDSA_VALIDATOR, initData: encodeAbiParameters([{ type: "address" }], [owner.address]) }]],
  });
  const salt = pad("0x00", { size: 32 });
  const address = await publicClient.readContract({ address: FACTORY, abi: factoryAbi, functionName: "getAddress", args: [initData, salt] });

  const account = await toSmartAccount({
    client: publicClient,
    entryPoint: { ...ENTRYPOINT, abi: entryPoint07Abi },
    async getAddress() { return address; },
    async getFactoryArgs() {
      return { factory: FACTORY, factoryData: encodeFunctionData({ abi: factoryAbi, functionName: "createAccount", args: [initData, salt] }) };
    },
    async encodeCalls(calls) {
      if (calls.length === 1) {
        const c = calls[0];
        return encodeFunctionData({ abi: accountAbi, functionName: "execute",
          args: [MODE_SINGLE, encodePacked(["address", "uint256", "bytes"], [c.to, c.value ?? 0n, c.data ?? "0x"])] });
      }
      const batch = encodeAbiParameters(
        [{ type: "tuple[]", components: [{ name: "target", type: "address" }, { name: "value", type: "uint256" }, { name: "callData", type: "bytes" }] }],
        [calls.map((c) => ({ target: c.to, value: c.value ?? 0n, callData: c.data ?? "0x" }))],
      );
      return encodeFunctionData({ abi: accountAbi, functionName: "execute", args: [MODE_BATCH, batch] });
    },
    async getNonce() {
      return publicClient.readContract({ address: entryPoint07Address, abi: entryPoint07Abi, functionName: "getNonce", args: [address, NONCE_KEY] });
    },
    async getStubSignature() { return STUB_SIG; },
    async signUserOperation(op) {
      const hash = getUserOperationHash({
        userOperation: { ...op, sender: address, signature: "0x" } as any,
        entryPointAddress: entryPoint07Address, entryPointVersion: "0.7", chainId: baseSepolia.id,
      });
      return owner.signMessage({ message: { raw: hash } }); // EIP-191 personal_sign over 32 raw bytes
    },
    // ERC-1271: owner signs AccountMessage(bytes32 hash) bound to this account, prefixed with the validator
    async signMessage() { throw new Error("signMessage not used in e2e"); },
    async signTypedData(td) {
      const inner = hashTypedData(td as any);
      const digest = hashTypedData({
        domain: { name: "VaultLiteECDSAValidator", version: "1", chainId: baseSepolia.id, verifyingContract: address },
        types: { AccountMessage: [{ name: "hash", type: "bytes32" }] }, primaryType: "AccountMessage", message: { hash: inner },
      });
      return concat([ECDSA_VALIDATOR, await owner.sign({ hash: digest })]);
    },
  });

  const pimlico = createPimlicoClient({ transport: http(PIMLICO_URL), entryPoint: ENTRYPOINT });
  const smart = createSmartAccountClient({
    account, chain: baseSepolia, bundlerTransport: http(PIMLICO_URL), paymaster: pimlico,
    userOperation: { estimateFeesPerGas: async () => (await pimlico.getUserOperationGasPrice()).fast },
  });

  console.log("account (counterfactual):", address);
  const results: any = { chainId: baseSepolia.id, entryPoint: entryPoint07Address, factory: FACTORY, validator: ECDSA_VALIDATOR, account: address, owner: owner.address, ops: [] };

  // op 1: deploy via initCode + 0-value batch
  const h1 = await smart.sendUserOperation({ calls: [
    { to: owner.address, value: 0n, data: "0x" },
    { to: ECDSA_VALIDATOR, value: 0n, data: encodeFunctionData({ abi: validatorAbi, functionName: "ownerOf", args: [address] }) },
  ] });
  const r1 = await smart.waitForUserOperationReceipt({ hash: h1 });
  console.log("op1 userOp", h1, "success", r1.success);
  console.log("  tx:", `${EXPLORER}/tx/${r1.receipt.transactionHash}`);
  console.log("  userOp:", `https://jiffyscan.xyz/userOpHash/${h1}?network=base-sepolia`);
  results.ops.push({ kind: "deploy + 0-value batch", userOpHash: h1, txHash: r1.receipt.transactionHash, success: r1.success, paymaster: r1.paymaster });

  // op 2: 0-value single call on the deployed account
  const h2 = await smart.sendUserOperation({ calls: [{ to: owner.address, value: 0n, data: "0x" }] });
  const r2 = await smart.waitForUserOperationReceipt({ hash: h2 });
  console.log("op2 userOp", h2, "success", r2.success);
  console.log("  tx:", `${EXPLORER}/tx/${r2.receipt.transactionHash}`);
  console.log("  account:", `${EXPLORER}/address/${address}`);
  results.ops.push({ kind: "0-value single call", userOpHash: h2, txHash: r2.receipt.transactionHash, success: r2.success, paymaster: r2.paymaster });

  const onchainOwner = await publicClient.readContract({ address: ECDSA_VALIDATOR, abi: validatorAbi, functionName: "ownerOf", args: [address] });
  const balance = await publicClient.getBalance({ address });
  results.onchainOwnerMatches = onchainOwner.toLowerCase() === owner.address.toLowerCase();
  results.accountBalanceWei = balance.toString();
  results.timestamp = new Date().toISOString();
  writeFileSync(new URL(OUT, import.meta.url), JSON.stringify(results, null, 2) + "\n");
  console.log("owner matches:", results.onchainOwnerMatches, "account balance (wei):", balance.toString());
  if (!r1.success || !r2.success) process.exit(1);
}

main().catch((e) => { console.error(redact(String(e?.stack ?? e))); process.exit(1); });
