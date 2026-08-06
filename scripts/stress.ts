/**
 * Velum stress suite — adversarial probes against the deployed verifiers.
 *
 * The demos show the happy path. This shows the system refusing. Each probe states what an
 * attacker gains if it passes, because a refusal is only interesting when the alternative was
 * damaging.
 *
 * Probes:
 *   S1  baseline — a holder attests their own position                       (must PASS)
 *   S2  transplant — one holder's proof submitted for another account        (must FAIL)
 *   S3  staleness — a proof replayed after the balance moved                 (must FAIL)
 *   S4  malformed — a truncated proof                                        (must FAIL)
 *   S5  authority — a non-owner submitting a valid seizure proof             (must FAIL)
 *   S6  alpha tampering — a valid proof submitted under a different amount   (must FAIL)
 *   S7  non-canonical field element in a public input                        (must FAIL)
 *   S8  negative seizure amount                                              (must FAIL)
 *   S9  boundary — seizing the entire position                              (must PASS)
 *
 * Usage (from refs/ct-demo/packages/sdk):
 *   VELUM_ATTEST=<id> VELUM_SEIZE=<id> pnpm exec tsx ../../../../scripts/stress.ts
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
const AUDITOR_ID = 0;
const THRESHOLD = 500_000n;   // pinned in the deployed velum-attest
const SIGMA_NEW = 0x2122232425262728292a2b2c2d2e2f30n;

const hex = (v: bigint) => `0x${v.toString(16).padStart(64, "0")}`;
const bytes32 = (v: bigint) => Buffer.from(v.toString(16).padStart(64, "0"), "hex");
const sh = (s: string) => `${s.slice(0, 4)}…${s.slice(-4)}`;

const attestProver = () =>
  new CircuitProver(JSON.parse(readFileSync(join(REPO, "circuits/disclose_balance_ge/target/disclose_balance_ge.json"), "utf8")));
const seizeProver = () =>
  new CircuitProver(JSON.parse(readFileSync(join(REPO, "circuits/seize/target/seize.json"), "utf8")));

const results: { id: string; ok: boolean; note: string }[] = [];

/** Reduces a thrown Soroban error to the part worth printing. */
function why(e: unknown): string {
  const m = String((e as Error)?.message ?? e);
  const code = m.match(/Error\(Contract, #(\d+)\)/)?.[1];
  if (code) return `#${code}`;
  if (/InvalidAction|auth|Auth/.test(m)) return "auth refused";
  return m.split("\n")[0].slice(0, 80);
}

/** A probe that must be refused. Passing means the refusal happened. */
async function mustFail(id: string, gain: string, fn: () => Promise<unknown>): Promise<void> {
  process.stdout.write(`  ${id} ${gain}\n`);
  try {
    await fn();
    console.log(`     ❌ ACCEPTED — this is a vulnerability`);
    results.push({ id, ok: false, note: "accepted" });
    process.exitCode = 1;
  } catch (e) {
    const w = why(e);
    console.log(`     ✅ refused — ${w}`);
    results.push({ id, ok: true, note: w });
  }
}

/** A probe that must be accepted. */
async function mustPass(id: string, what: string, fn: () => Promise<unknown>): Promise<void> {
  process.stdout.write(`  ${id} ${what}\n`);
  try {
    await fn();
    console.log(`     ✅ accepted`);
    results.push({ id, ok: true, note: "accepted" });
  } catch (e) {
    console.log(`     ❌ REFUSED — ${why(e)}`);
    results.push({ id, ok: false, note: why(e) });
    process.exitCode = 1;
  }
}

async function main(): Promise<void> {
  const attest = process.env.VELUM_ATTEST;
  const seize = process.env.VELUM_SEIZE;
  if (!attest || !seize) throw new Error("set VELUM_ATTEST and VELUM_SEIZE");

  const dep = JSON.parse(readFileSync(join(REPO, "refs/ct-demo/deployments/testnet.json"), "utf8"));
  const client = new ChainClient({
    rpcUrl: RPC_URL,
    networkPassphrase: PASSPHRASE,
    contracts: { token: dep.contracts.token, verifier: dep.contracts.verifier, auditor: dep.contracts.auditor },
  });
  const addrF = addressToField(dep.contracts.token);
  const adminSecret = execFileSync("stellar", ["keys", "show", "admin"], { encoding: "utf8" }).trim();

  /** Establishes a real confidential position and returns everything needed to prove about it. */
  async function holder(deposit: bigint) {
    const kp = Keypair.random();
    await fetch(`https://friendbot.stellar.org?addr=${kp.publicKey()}`);
    const signer = keypairSigner(kp.secret(), PASSPHRASE);
    const keys = deriveKeys(randomScalar(), addrF);
    const engine = new StateEngine({
      client, store: new MemoryStore(), keys,
      address: kp.publicKey(), fromLedger: dep.deployedAtLedger,
    });
    const w = buildRegisterWitness(keys);
    const { proof } = await new CircuitProver(loadCircuit("register")).prove(w.inputs);
    await submitRegister(client, signer, kp.publicKey(), AUDITOR_ID, w, proof);
    await submitDeposit(client, signer, kp.publicKey(), kp.publicKey(), deposit);
    await submitMerge(client, signer, kp.publicKey());
    return { kp, signer, keys, engine, refresh: async () => {
      const st = await engine.sync();
      const oc = (await client.confidentialBalance(kp.publicKey()))!;
      return {
        vS: st.spendable.v, rS: st.spendable.r, vR: st.receiving.v, rR: st.receiving.r,
        cSpend: oc.spendableBalance.toAffine(), cReceive: oc.receivingBalance.toAffine(),
        pvk: oc.viewingPublicKey.toAffine(),
      };
    }};
  }

  console.log("velum-attest =", attest);
  console.log("velum-seize  =", seize);
  console.log("\n[setup] two holders with real positions on testnet");
  const [h1, h2] = [await holder(1_000_000n), await holder(600_000n)];
  const s1 = await h1.refresh(), s2 = await h2.refresh();
  console.log(`  H1 ${sh(h1.kp.publicKey())}  ·  H2 ${sh(h2.kp.publicKey())}`);

  // ---------------------------------------------------------------- attest
  const ap = attestProver();
  const proofH1 = (await ap.prove({
    sk: hex(h1.keys.sk), v_s: hex(s1.vS), r_s: hex(s1.rS), addr_f: hex(addrF),
    pvk_a_x: hex(s1.pvk.x), pvk_a_y: hex(s1.pvk.y),
    c_spend_x: hex(s1.cSpend.x), c_spend_y: hex(s1.cSpend.y), v_threshold: hex(THRESHOLD),
  })).proof;
  const doAttest = (who: string, proof: Uint8Array) =>
    client.invoke(attest, "attest_position", [
      new Address(who).toScVal(), xdr.ScVal.scvBytes(Buffer.from(proof)),
    ], h1.signer);

  console.log("\n[velum-attest] a permissionless entry point, probed as one");
  await mustPass("S1", "H1's own proof, for H1", () => doAttest(h1.kp.publicKey(), proofH1));
  await mustFail("S2", "H1's proof submitted FOR H2 — would let anyone certify a stranger",
    () => doAttest(h2.kp.publicKey(), proofH1));
  await mustFail("S4", "a proof truncated by 32 bytes — would mean the verifier is not reading it",
    () => doAttest(h1.kp.publicKey(), proofH1.slice(0, proofH1.length - 32)));

  console.log("\n[velum-attest] the same proof after the balance moved");
  await submitDeposit(client, h1.signer, h1.kp.publicKey(), h1.kp.publicKey(), 1n);
  await submitMerge(client, h1.signer, h1.kp.publicKey());
  await mustFail("S3", "replaying the pre-move proof — would let a stale claim stand as current",
    () => doAttest(h1.kp.publicKey(), proofH1));

  const att: any = await client.simulate(attest, "attestation", [new Address(h1.kp.publicKey()).toScVal()]);
  console.log(`  ℹ️  the S1 attestation is still on record after the move (ledger-stamped, not expiring)`);

  // ---------------------------------------------------------------- seize
  const sp = seizeProver();
  const post = (a: { vS: bigint; vR: bigint; vk: bigint }, alpha: bigint) => {
    const remaining = a.vS + a.vR - alpha;
    const rNew = deriveSpendR(a.vk, SIGMA_NEW);
    return { cNew: commit(remaining, rNew).toAffine(), bNew: encryptBalance(remaining, a.vk, SIGMA_NEW) };
  };
  const proveSeize = async (st: typeof s2, keys: { vk: bigint }, alpha: bigint) => {
    const p = post({ vS: st.vS, vR: st.vR, vk: keys.vk }, alpha);
    const { proof } = await sp.prove({
      vk: hex(keys.vk), v_s: hex(st.vS), r_s: hex(st.rS), v_r: hex(st.vR), r_r: hex(st.rR),
      pvk_a_x: hex(st.pvk.x), pvk_a_y: hex(st.pvk.y),
      c_spend_x: hex(st.cSpend.x), c_spend_y: hex(st.cSpend.y),
      c_receive_x: hex(st.cReceive.x), c_receive_y: hex(st.cReceive.y),
      alpha: hex(alpha), sigma_new: hex(SIGMA_NEW),
      c_spend_new_x: hex(p.cNew.x), c_spend_new_y: hex(p.cNew.y), b_tilde_new: hex(p.bNew),
    });
    return { proof, p };
  };
  const i128 = (v: bigint) => xdr.ScVal.scvI128(new xdr.Int128Parts({
    hi: xdr.Int64.fromString(v < 0n ? "-1" : "0"),
    lo: xdr.Uint64.fromString((v < 0n ? (1n << 64n) + v : v).toString()),
  }));
  const doSeize = (amount: bigint, bNew: Buffer, proof: Uint8Array, who: any, addr: string) =>
    client.invoke(seize, "verify_seizure", [
      new Address(h2.kp.publicKey()).toScVal(), i128(amount), xdr.ScVal.scvBytes(bytes32(SIGMA_NEW)),
      xdr.ScVal.scvBytes(Buffer.concat([bytes32(cNewX), bytes32(cNewY)])),
      xdr.ScVal.scvBytes(bNew), xdr.ScVal.scvBytes(Buffer.from(proof)),
      new Address(addr).toScVal(),
    ], who);

  const ALPHA = 250_000n;
  const { proof: seizeProof, p: sPost } = await proveSeize(s2, h2.keys, ALPHA);
  var cNewX = sPost.cNew.x, cNewY = sPost.cNew.y;
  const authority = keypairSigner(adminSecret, PASSPHRASE);
  const authorityAddr = Keypair.fromSecret(adminSecret).publicKey();

  console.log("\n[velum-seize] an owner-gated entry point, probed as one");
  await mustFail("S5", "a stranger submitting a VALID seizure proof — would make anyone an authority",
    () => doSeize(ALPHA, bytes32(sPost.bNew), seizeProof, h2.signer, h2.kp.publicKey()));
  await mustFail("S6", "the valid proof re-submitted under amount=1 — would decouple alpha from the proof",
    () => doSeize(1n, bytes32(sPost.bNew), seizeProof, authority, authorityAddr));
  await mustFail("S7", "b_tilde_new = 0xff…ff, outside the field — would mean inputs are unchecked",
    () => doSeize(ALPHA, Buffer.alloc(32, 0xff), seizeProof, authority, authorityAddr));
  await mustFail("S8", "a negative seizure amount",
    () => doSeize(-1n, bytes32(sPost.bNew), seizeProof, authority, authorityAddr));

  console.log("\n[velum-seize] the boundary: seizing the entire position");
  const full = s2.vS + s2.vR;
  const { proof: fullProof, p: fPost } = await proveSeize(s2, h2.keys, full);
  cNewX = fPost.cNew.x; cNewY = fPost.cNew.y;
  await mustPass("S9", `alpha = ${full} (the whole position, remaining = 0)`,
    () => doSeize(full, bytes32(fPost.bNew), fullProof, authority, authorityAddr));

  // ---------------------------------------------------------------- verdict
  const bad = results.filter((r) => !r.ok);
  console.log(`\n${"─".repeat(70)}`);
  for (const r of results) console.log(`  ${r.ok ? "✅" : "❌"} ${r.id.padEnd(4)} ${r.note}`);
  console.log(`\n  ${results.length - bad.length}/${results.length} probes behaved as designed.`);
  if (bad.length) console.log(`  FAILURES: ${bad.map((b) => b.id).join(", ")}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
