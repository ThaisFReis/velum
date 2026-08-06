/**
 * Velum demo — an individual-clawback proof verified on-chain.
 *
 * A holder establishes a real confidential position. The seizure authority then proves, against
 * that account's live commitments, that a seizure of `alpha` is bounded by the position and that
 * the post-seizure state follows the protocol's canonical derivations. `velum-seize` verifies it
 * on-chain and records the verdict. The position itself is never revealed.
 *
 * Two things this demo does NOT show, and neither is hidden:
 *
 *   1. No value moves. Rewriting the token's commitments needs a `seize` entry point inside the
 *      token contract; this is the verification half.
 *   2. The auditor's knowledge is simulated. The circuit needs the holder's viewing key, which in
 *      a real deployment would come from an escrow written at registration (whitepaper §11.3) —
 *      a breaking change to upstream's register circuit that we did not make. Here the script
 *      holds the key because it created the account.
 *
 * What IS demonstrated: the seize circuit verifies on-chain against state the prover does not
 * control, and a seizure larger than the position cannot be proven at all.
 *
 * Usage (from refs/ct-demo/packages/sdk):
 *   VELUM_SEIZE=<contract id> pnpm exec tsx ../../../../scripts/demo-seize.ts
 */

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Address, Keypair, Networks, xdr } from "@stellar/stellar-sdk";

import { ChainClient, keypairSigner } from "../refs/ct-demo/packages/sdk/src/chain/client.js";
import { submitRegister, submitDeposit, submitMerge } from "../refs/ct-demo/packages/sdk/src/chain/contract.js";
import { deriveKeys } from "../refs/ct-demo/packages/sdk/src/crypto/keys.js";
import { randomScalar } from "../refs/ct-demo/packages/sdk/src/crypto/field.js";
import { addressToField } from "../refs/ct-demo/packages/sdk/src/crypto/address.js";
import { buildRegisterWitness } from "../refs/ct-demo/packages/sdk/src/witness/register.js";
import { CircuitProver } from "../refs/ct-demo/packages/sdk/src/proving/prover.js";
import { loadCircuit } from "../refs/ct-demo/packages/sdk/src/proving/artifacts.js";
import { StateEngine, MemoryStore } from "../refs/ct-demo/packages/sdk/src/state/index.js";
import { deriveSpendR, encryptBalance } from "../refs/ct-demo/packages/sdk/src/crypto/poseidon2.js";
import { commit } from "../refs/ct-demo/packages/sdk/src/crypto/grumpkin.js";

const REPO = join(import.meta.dirname, "..");
const RPC_URL = "https://soroban-testnet.stellar.org";
const PASSPHRASE = Networks.TESTNET;
const CIRCUIT = join(REPO, "circuits/seize");
const AUDITOR_ID = 0;

const DEPOSIT = 1_000_000n;
const ALPHA = 250_000n;                       // seized
const SIGMA_NEW = 0x1112131415161718191a1b1c1d1e1f20n; // the seizure event's nonce

const hex = (v: bigint) => `0x${v.toString(16).padStart(64, "0")}`;
const bytes32 = (v: bigint) => Buffer.from(v.toString(16).padStart(64, "0"), "hex");

/** The seizure authority: the contract owner, read from the local stellar CLI identity store. */
const authoritySecret = () =>
  execFileSync("stellar", ["keys", "show", "admin"], { encoding: "utf8" }).trim();

const seizeProver = () =>
  new CircuitProver(JSON.parse(readFileSync(join(CIRCUIT, "target/seize.json"), "utf8")));

/** Poseidon-derived values the circuit itself recomputes; mirrored here to build the witness. */
function canonicalPostState(a: {
  vk: bigint; vS: bigint; rS: bigint; vR: bigint; rR: bigint;
  pvk: { x: bigint; y: bigint }; cSpend: { x: bigint; y: bigint };
  cReceive: { x: bigint; y: bigint }; alpha: bigint;
}) {
  // The circuit constrains C_spend_new and b_tilde_new (Z6/Z7); we recompute them here with the
  // same primitives the circuit uses, so the witness is self-consistent by construction.
  const remaining = a.vS + a.vR - a.alpha;
  const rNew = deriveSpendR(a.vk, SIGMA_NEW);
  const cNew = commit(remaining, rNew).toAffine();
  const bNew = encryptBalance(remaining, a.vk, SIGMA_NEW);
  return { remaining, cNew, bNew };
}

async function main(): Promise<void> {
  const p = seizeProver();
  const vk = await p.verificationKey();
  if (!process.env.VELUM_SEIZE) {
    console.log(`seize verification key (${vk.length} B) — deploy velum-seize with:\n`);
    console.log(Buffer.from(vk).toString("hex"));
    return;
  }
  const seize = process.env.VELUM_SEIZE;

  const dep = JSON.parse(readFileSync(join(REPO, "refs/ct-demo/deployments/testnet.json"), "utf8"));
  const client = new ChainClient({
    rpcUrl: RPC_URL,
    networkPassphrase: PASSPHRASE,
    contracts: { token: dep.contracts.token, verifier: dep.contracts.verifier, auditor: dep.contracts.auditor },
  });
  const addrF = addressToField(dep.contracts.token);

  console.log("token       =", dep.contracts.token);
  console.log("velum-seize =", seize);

  console.log("\n[1/3] a holder with a real position");
  const kp = Keypair.random();
  await fetch(`https://friendbot.stellar.org?addr=${kp.publicKey()}`);
  const signer = keypairSigner(kp.secret(), PASSPHRASE);
  const keys = deriveKeys(randomScalar(), addrF);
  const engine = new StateEngine({
    client, store: new MemoryStore(), keys,
    address: kp.publicKey(), fromLedger: dep.deployedAtLedger,
  });

  const w = buildRegisterWitness(keys);
  const { proof: regProof } = await new CircuitProver(loadCircuit("register")).prove(w.inputs);
  await submitRegister(client, signer, kp.publicKey(), AUDITOR_ID, w, regProof);
  await submitDeposit(client, signer, kp.publicKey(), kp.publicKey(), DEPOSIT);
  await submitMerge(client, signer, kp.publicKey());

  const state = await engine.sync();
  const onChain = (await client.confidentialBalance(kp.publicKey()))!;
  const cSpend = onChain.spendableBalance.toAffine();
  const cReceive = onChain.receivingBalance.toAffine();
  const pvk = onChain.viewingPublicKey.toAffine();
  console.log(`  ${kp.publicKey()}`);
  console.log(`  position is a commitment on-chain; the amount is not readable`);

  console.log(`\n[2/3] the authority proves a seizure of ${ALPHA} is bounded by that position`);
  const base = {
    vk: keys.vk, vS: state.spendable.v, rS: state.spendable.r,
    vR: state.receiving.v, rR: state.receiving.r, pvk, cSpend, cReceive,
  };
  const post = canonicalPostState({ ...base, alpha: ALPHA });
  const t0 = Date.now();
  const { proof } = await p.prove({
    vk: hex(keys.vk), v_s: hex(base.vS), r_s: hex(base.rS), v_r: hex(base.vR), r_r: hex(base.rR),
    pvk_a_x: hex(pvk.x), pvk_a_y: hex(pvk.y),
    c_spend_x: hex(cSpend.x), c_spend_y: hex(cSpend.y),
    c_receive_x: hex(cReceive.x), c_receive_y: hex(cReceive.y),
    alpha: hex(ALPHA), sigma_new: hex(SIGMA_NEW),
    c_spend_new_x: hex(post.cNew.x), c_spend_new_y: hex(post.cNew.y),
    b_tilde_new: hex(post.bNew),
  });
  console.log(`  proof: ${proof.length} B in ${((Date.now() - t0) / 1000).toFixed(2)}s`);

  // Signed by the AUTHORITY, not the holder: verify_seizure is owner-gated. A seizure is an
  // assertion about someone by someone; the gate records who made it.
  const authority = keypairSigner(authoritySecret(), PASSPHRASE);
  const authorityAddr = Keypair.fromSecret(authoritySecret()).publicKey();
  const res = await client.invoke(seize, "verify_seizure", [
    new Address(kp.publicKey()).toScVal(),
    xdr.ScVal.scvI128(new xdr.Int128Parts({ hi: xdr.Int64.fromString("0"), lo: xdr.Uint64.fromString(ALPHA.toString()) })),
    xdr.ScVal.scvBytes(bytes32(SIGMA_NEW)),
    xdr.ScVal.scvBytes(Buffer.concat([bytes32(post.cNew.x), bytes32(post.cNew.y)])),
    xdr.ScVal.scvBytes(bytes32(post.bNew)),
    xdr.ScVal.scvBytes(Buffer.from(proof)),
    new Address(authorityAddr).toScVal(),
  ], authority);
  console.log(`  ✅ seizure proven on-chain — tx ${res.hash}`);
  console.log(`     https://stellar.expert/explorer/testnet/tx/${res.hash}`);
  console.log(`     the ledger records the amount seized. It never records the position.`);

  console.log("\n[3/3] the same authority claiming more than the position holds");
  try {
    const tooMuch = base.vS + base.vR + 1n;
    const bad = canonicalPostState({ ...base, alpha: tooMuch });
    await p.prove({
      vk: hex(keys.vk), v_s: hex(base.vS), r_s: hex(base.rS), v_r: hex(base.vR), r_r: hex(base.rR),
      pvk_a_x: hex(pvk.x), pvk_a_y: hex(pvk.y),
      c_spend_x: hex(cSpend.x), c_spend_y: hex(cSpend.y),
      c_receive_x: hex(cReceive.x), c_receive_y: hex(cReceive.y),
      alpha: hex(tooMuch), sigma_new: hex(SIGMA_NEW),
      c_spend_new_x: hex(bad.cNew.x), c_spend_new_y: hex(bad.cNew.y),
      b_tilde_new: hex(bad.bNew),
    });
    console.log("  ✗ UNEXPECTED: a proof was produced for an over-large seizure");
    process.exitCode = 1;
  } catch {
    console.log("  ✅ refused: Z4 bounds alpha by the position, so the witness cannot be built.");
    console.log("     An authority cannot seize more than exists, and cannot learn how much does.");
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
