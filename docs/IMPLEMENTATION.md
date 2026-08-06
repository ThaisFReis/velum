# Implementation record

What exists, how it was built, and the evidence that it runs. Every number and hash below was
produced on testnet or on the authors' machine — nothing here is projected.

Last run: **2026-08-05**. Network: **Stellar testnet**.

---

## 1. What is deployed

### Ours

| Contract | Address | Notes |
|---|---|---|
| `velum-attest` | `CBCBSILY5B562Q263W4EDYU7IHBV3SSM3IFWA333MII3OK3QRGNCDXKY` | 37 933 B wasm. Constructor: owner, token, `addr_f`, VK, threshold=500 000. Binds `C_receive` too (finding 7) and `is_attested` takes a freshness window |
| `velum-attest` (v1, superseded) | `CDEDFUYUNNQLU4C7ISKXJ26AIPIR42UJPW7XO72EZFEC3Y6VT6OO7LPK` | 36 937 B. Spendable-only predicate, non-expiring `is_attested` |
| `velum-policy` | `CDJET5BV36RDRNCNCNXJFYWUKPCX4VWXTUY4EGU4W5VUJ3FHLHIYFPKV` | 8 101 B wasm. Delegates to the identity verifier, and fails closed on an issuer-less topic (§6.3). The gated token points here |
| `velum-seize` | `CDVV37Y766VSLNRRIHRXBTUCEN7UJU7QQVROLWYVA6L7FRTKJO3Z2LE5` | 35 636 B wasm. Constructor: owner, token, VK. Verifies the seize circuit against live token state (§2.2) |
| `velum-policy` (v1, superseded) | `CCCQ7Z6FYLCIXHBQDSIUJ46YMS63VDHY3ZM5ISGWGFJ5EXONOWOXQXDK` | 7 808 B. Kept deployed as the control in the A/B below |
| identity-gated token | `CBDT4EKUF66MS7HHDHMLDPDI7TOPZCV7AYYLC53ES7TEB67KAT3BFWV5` | Confidential token deployed through upstream's factory, bound to `velum-policy`, `sac_passthrough: true` |

### Confidential-token stack (upstream code, deployed by us)

| Contract | Address |
|---|---|
| token | `CDO7PJCVNL2H3HVQDMPYBDAWWBE62YXZLZULHCAIYVHBZSP2CNAI4KB7` |
| verifier | `CDYCNTXK2DJA4YSOCKXP4L64T54RCT3FFR4LAT43HU6WF2QJCL4MH4DR` |
| auditor | `CDR2EBDLPI4L7HLXU7I4C2356HP6YNIIMBP5QHTNM4TPQJR6WLZ6ZCJH` |
| allowlist / blocklist | `CAOM4HLC…6DND` / `CB3A3EIU…7TWQR` |
| factory | `CD2SJ43LIYK4LNZE75D66EAB7FGYXJVBMN6HVRAVMLSHHRFP7ENIXXSC` |
| underlying (native SAC) | `CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC` |

`addr_f` of the token: `0x22c4a8e478bce4b5212b0518bface4cf5510db8333293ff99d6046f8a0d51fa8`

### RWA identity stack (upstream code, deployed by us)

| Contract | Address |
|---|---|
| claim-topics-and-issuers | `CB7ODYCJLLCWHMCYSZ6IUT3OQEQ5KEGX2OXNM3I2CIMI3IQ3QOTB226N` |
| claim-issuer | `CBLUFPON4LW4OXPOZP6LYHFPFQJXDW6M5O52ES2TALKWBN4REUX665IA` |
| identity (holder) | `CDLHCYRNG5BKYJMLUGVTIVJBST2BTDYEDMGT3VCYJCK3Q63DZDB3SST7` |
| identity-registry | `CDG2WQ3CSIDHUB5CYHONFSSOQJ3GUUDVLWZUXUU7WEUITO2ZHDJSL25H` |
| identity-verifier | `CBZS626ZJMLC2ILCJCV4RLSLR7MZYBDEV7DNAEY5CZRKUFQQUPVH5M22` |

Claim topic 1 (KYC) registered; the claim issuer is trusted for it; an Ed25519 signing key is
authorised; the holder's identity contract carries a signed KYC claim; and the holder is
registered in the identity registry with a Brazilian residence profile
(tx `da8c0a6c…376e`, events `IdentityStored` + `country_data_added`). That last call needed the
XDR-JSON payload in §6, finding 4 — the format documented upstream cannot work.

---

## 2. The headline result: a position proved on-chain

`scripts/demo-attest.ts` runs the whole path against testnet, on real state:

```
[1/4] holder
  GCCYQYZNQZBV66J4IJG2CLNZNH4Z2PGGPFM3HYDBG5IDI6Y2GIDZI34G

[2/4] register + deposit + merge
  position established. On the explorer this balance is a commitment:
    C_spend.x = 0x1c37cfd2395d01244935ca8eef123da331b2a55b4b86f600b43262373b50e429

[3/4] prove position >= threshold, then verify ON-CHAIN
  proof: 14592 B in 2.68s
  ✅ attested on-chain — tx f6c02c…13da
     https://stellar.expert/explorer/testnet/tx/f6c02ceb6dde8abe6b1a1b0ccd4c8bc265098c5c7564d78520870031241213da
  is_attested(max_age=1000 ledgers) = true
  is_attested(max_age=0)         = true  ← same record, stricter window
     the contract learned the position clears 500000 — and nothing else.

[4/4] the same holder claiming a threshold above their position
  ✅ refused: the witness cannot be built, so no proof exists to submit.
     A false claim fails before verification, not at it.
```

**Attestation transaction:**
`f8ff2951ad2277d4337b590842762a60ee46b8936d9c9014f5154a0918c13267`

What that transaction proves: a Soroban contract read the holder's commitment and viewing key
from the token, read the threshold from its own profile, verified an UltraHonk proof, and
recorded that the position clears 500 000 — **without the amount appearing anywhere**, the
verifier included.

The negative case matters as much. Asked to prove a threshold above the real position, the
prover cannot build a witness: the failure happens before a proof exists, so there is nothing
to submit and nothing for the verifier to reject.

### Public inputs the contract reassembles

256 bytes, eight field elements, in circuit order:

| # | Field | Source at verification time |
|---|---|---|
| 0 | `22c4a8e4…1fa8` | `addr_f`, pinned at construction |
| 1–2 | `PVK_A.x` / `.y` | read from the token |
| 3–4 | `C_spend.x` / `.y` | read from the token |
| 5–6 | `C_receive.x` / `.y` | read from the token — **not** in upstream's §9 flow; see §6, finding 7 |
| 7 | `…0007a120` | threshold (500 000), the contract's own profile |

The prover supplies only the proof. A caller substituting its own commitment would verify
against a blob the contract never assembles.

---

## 2.1 Identity gating: the same question, two answers

`velum-policy` is deployed against the identity verifier and answers the token's authorization
question for two wallets. Alice carries a KYC claim issued by an approved certifier; Bob carries
nothing.

```
=== is_authorized(ALICE — KYC claim registered):
true

=== is_authorized(BOB — no identity):
CBZS626Z… - Failure - Log: {"vec":[{"string":"VM call trapped with HostError"},
                                   {"symbol":"verify_identity"},{"error":{"contract":321}}]}
false
```

Error 321 is `IdentityNotFound`, raised by the RWA verifier. The log line is the evidence that
the adapter does its job: the RWA side signals failure by **panicking**, the token's `Policy`
expects a **boolean**, and a panic crossing a cross-contract call would abort the whole
transaction instead of letting the token reject the operation cleanly. `velum-policy` calls
through the generated client's `try_` variant and folds the trap into `false`.

The distinction that matters for a regulated fund: Bob is not refused because he is absent from
a list. He is refused because he carries no valid claim from an approved issuer — and the same
registry answers for the public asset and the confidential wrapper.

### Through the token, not just the interface

`scripts/demo-gate.ts` has both wallets attempt the same operation — `register` — on the
identity-gated token above:

```
token (policy-gated) = CBDT4EKUF66MS7HHDHMLDPDI7TOPZCV7AYYLC53ES7TEB67KAT3BFWV5

[velum-alice] KYC claim from an approved issuer
  ✅ accepted — tx d9a1a33cdadebd9f440c958a5557e29c7e030ad411e84335cb0307da1ab78fd7

[velum-bob] no identity registered
  ⛔ refused by policy — Error(Contract, #3602)
```

`3602` is `NotAuthorizedByPolicy`. Note what it is not: Bob produced a **valid zero-knowledge
proof** for the register circuit, and it never mattered. Identity is checked before the proof is
considered, so cryptographic correctness cannot buy entry to a regulated asset.

The token was created through upstream's own factory (`deploy_compliant_token`) with our policy
address; the deployment event records `policy = CCCQ7Z6F…OXQXDK, sac_passthrough: true`. Nothing
upstream was modified to make this work.

### Three distinct outcomes, all on the gated token

The same probe, three states of the world:

| Wallet / state | Result |
|---|---|
| Alice — KYC claim, not frozen | accepted (`register` tx `d9a1a33c…8fd7`; on repeat runs, a policy-gated deposit) |
| Alice — **frozen by the issuer** | `#3601 AccountFrozen` |
| Bob — no identity | `#3602 NotAuthorizedByPolicy` |

Freeze was exercised end to end: `freeze(velum-alice)` emitted `Frozen`, `is_frozen` returned
`true`, her next gated operation failed with 3601 — distinguishable from a policy refusal — and
`unfreeze` restored her. The issuer control and the identity gate are independent and both work.

### A demo bug worth recording

The first version of `demo-gate.ts` was not idempotent, and worse, it misattributed the failure.
On a second run Alice fails with `#3500 AccountAlreadyRegistered`, and the script's catch-all
labelled every failure "refused by policy" — so a judge running it twice would have seen our own
gate appear to reject an authorized wallet. Fixed: the script probes with `register` when the
account is new and with a policy-gated `deposit` when it is not, and it names the actual error
code in every branch.

## 2.2 A seizure proved on-chain, bounded by a position nobody can read

The clawback design note (whitepaper §11) was, until this run, a premise plus a circuit that
verified locally. `velum-seize` moves the verification on-chain: it reads the target's live
`PVK_A`, `C_spend` and `C_receive` cross-contract from the token, assembles the 11 public field
elements (352 B) in the circuit's order, and verifies the UltraHonk proof.

```
[1/3] a holder with a real position
  GAH2Q6MEHRUI7S6WXBUORQJQFXJQ75FFX37LLXVR7DHWMAWUHFB2PG3W
  position is a commitment on-chain; the amount is not readable

[2/3] the authority proves a seizure of 250000 is bounded by that position
  proof: 14592 B in 2.06s
  ✅ seizure proven on-chain — tx 282a2947b2998b2b2de56c9727d0a151d8aa0a9f8e55d10014e915309be8c4cd
     the ledger records the amount seized. It never records the position.

[3/3] the same authority claiming more than the position holds
  ✅ refused: Z4 bounds alpha by the position, so the witness cannot be built.
```

The holder deposited 1 000 000 and the authority proved a seizure of 250 000. Nothing on the
ledger states the position — only that a seizure of that size fits inside it. The over-large
attempt fails where every unprovable claim in this project fails: at witness construction, before
a proof exists.

`verify_seizure` is owner-gated, unlike `attest_position`. A position attestation is
self-authenticating and harmless to relay; a seizure is an assertion *about* someone, so the gate
records who made it. The demo therefore signs with the contract owner, not the holder.

### What this does not show, stated before anyone asks

1. **No value moves.** Rewriting the token's commitments requires a `seize` entry point inside the
   token contract. We did not fork it. What ran here is the verification half — the half that was
   in doubt.
2. **The escrow is simulated.** The circuit takes the holder's `vk` as a private witness. For an
   authority to hold it *without the holder's cooperation* — the entire point of a clawback —
   registration must escrow it (whitepaper §11.3), a breaking change to upstream's register circuit
   that we did not make. Here the script holds `vk` because it created the account.

So the claim is bounded to exactly this: **the seize circuit verifies on-chain against state the
prover does not control, and an over-large seizure cannot be proven.** Not that a
non-cooperating holder can be seized from today. `contracts/velum-seize/src/lib.rs` says the same
thing in its module docs, so the caveat cannot be lost by reading the code instead of this file.

---

## 2.3 Nine adversarial probes against the deployed verifiers

`scripts/stress.ts`, run against the live contracts with two real confidential positions
(1 000 000 and 600 000). The demos show the happy path; this shows the system refusing. Each probe
states what an attacker would gain, because a refusal only matters when the alternative was
damaging.

| # | Probe | What it would buy an attacker | Result |
|---|---|---|---|
| S1 | H1's proof, for H1 | (baseline) | ✅ accepted |
| S2 | **H1's proof submitted for H2's account** | certifying a stranger | ✅ refused `#2` |
| S3 | **the proof replayed after the balance moved** | a stale claim standing as current | ✅ refused `#2` |
| S4 | a proof truncated by 32 bytes | evidence the proof is not read | ✅ refused `#2` |
| S5 | **a stranger submitting a VALID seizure proof** | making anyone an authority | ✅ refused |
| S6 | **the same valid proof under `amount = 1`** | decoupling alpha from the proof | ✅ refused `#1` |
| S7 | `b_tilde_new = 0xff…ff`, outside the field | unchecked public inputs | ✅ refused `#2` |
| S8 | a negative seizure amount | — | ✅ refused `#4` |
| S9 | seizing the whole position (`remaining = 0`) | (boundary) | ✅ accepted |

**9/9 behaved as designed.**

S2 is the one that mattered most: `attest_position` is deliberately permissionless, so anyone may
relay anyone's proof. That is only safe because D1/D2 bind the proof to the account's own viewing
key and the contract reads `PVK_A` and `C_spend` from the token, live. The refusal confirms the
argument in practice rather than on paper.

S3 settles freshness. Depositing 1 unit and re-merging changes `C_spend`; the earlier proof was
then refused. Because the contract reads the current commitment, a proof is only valid against the
state it was made against — freshness is a consequence of where the inputs come from, not a policy
someone must remember to apply.

S5 needed a second, separate test to be conclusive. It failed on-chain, but that alone does not
distinguish "stopped by the owner gate" from "failed for some other reason", and probing it
directly through the CLI is masked by `#3501` (account not registered in the token), which traps
before the gate. The gate was proven where the same macro is not masked — `set_threshold`, which
reads no token state: the non-owner was refused with *"Missing signing key for account
GAEZBHTK…KZQY"*, the `admin` address. `#[only_owner]` demands the owner's signature.

S6 is what makes a seizure mean anything. A valid proof for 250 000, resubmitted declaring
`amount = 1`, is rejected: `alpha` is a public input, so changing it invalidates the proof. The
authority does not get to pick the number after proving.

---

## 3. Circuits

| Package | Tests | Cost | Proof |
|---|---|---|---|
| `circuits/disclose_balance_ge` | 14 ✅ | 43 → **67** ACIR opcodes (DB3b) | 14 592 B · 8 public inputs · 2.68 s (bb.js, in-process) |
| `circuits/seize` | 12 ✅ | 93 ACIR opcodes | 14 592 B · 0.33 s (CLI) / 2.06 s (bb.js) · **verified on-chain** (§2.2) |
| `experiments/clawback-poc` | 9 ✅ | — | premise verification, no circuit |
| `experiments/circuit-cap-poc` | 34 ✅ | 133 → 137 opcodes (+3 %) | patch against upstream's transfer circuit |

**69 tests, all passing.**

The 34 in `circuit-cap-poc` are not a package — they are two patches against upstream's transfer
circuit. Re-applied and re-run in this review: 34 pass and `nargo info` reports 137 ACIR opcodes,
exactly the published figures (133 → 137, +3 %). Reproduction is in
`experiments/circuit-cap-poc/README.md`.

`disclose_balance_ge` implements `SELECTIVE_DISCLOSURE.md` §9 (constraints D1, D2, DB3, D5, DB4),
plus two constraints beyond the spec: DB4b range-checks the threshold, so a malformed public input
cannot make the predicate vacuous; and DB3b opens `C_receive` and bounds `v_s + v_r`, so the
predicate is about the position rather than the spendable balance (§6, finding 7).

`seize` (Z1–Z7) answers upstream's open question on individual clawback: it opens both
commitments, bounds `alpha <= v_s + v_r`, and writes the post-seizure state under the protocol's
canonical derivations, so the holder's wallet keeps working afterwards.

---

## 4. Contracts

**`velum-policy`** — implements the confidential token's `Policy` trait by delegating to the RWA
`IdentityVerifier`. The two interfaces disagree on failure signalling: RWA panics, the token
expects a boolean. The call goes through the generated client's `try_` variant, folding the error
into `false`; a panic crossing a cross-contract call would abort the transaction instead of
letting the token reject cleanly.

**`velum-attest`** — verifies `disclose_balance_ge` proofs on-chain and records
`Attestation { threshold, attested_at_ledger }`. It runs its own single-entry VK registry, because
upstream's `CircuitType` enum is closed and carries no disclosure variant. `addr_f` is pinned at
construction: the token keeps it in instance storage and `address_to_field` is `pub(crate)`, so a
third-party verifier can neither read nor recompute it (§6, finding 1). It is still not
prover-supplied, so the trust boundary holds.

No authorization is required to submit an attestation: D1/D2 bind the proof to the account's own
viewing key, so relaying a valid proof only records a fact that account could have recorded itself.

**`velum-seize`** — verifies the seize circuit (Z1–Z7) against the token's live account record and
stores `SeizeVerdict { amount, sigma_new, verified_at_ledger }`. Like `velum-attest` it runs a
one-entry VK registry of its own, for the same reason: `CircuitType` is upstream's closed enum for
the token's own circuits and has no seize variant, so the variant name is just a storage slot.

There is no `addr_f` among its public inputs and none is needed. `PVK_A = vk · H` with
`vk = Poseidon2(δ_vk, sk, addr_f)` is already contract-bound, so a proof built against one token's
account cannot verify against another's. The three state inputs are read from the token rather than
supplied by the prover, which is what makes the verdict mean anything: the authority chooses
`alpha` and `sigma_new`, and the chain supplies everything it could otherwise lie about.

---

## 5. Three failures worth recording

Both cost real time and neither is in any documentation.

### 5.1 The verification key had the wrong shape (error 3403)

The first attestation attempt failed with `Error(Contract, #3403)` —
`InvalidVerificationKey`. A VK produced by `bb write_vk` measured **1764 bytes**; every VK
committed in the demo measures **1760**.

Generating a VK for upstream's own `register` circuit with our toolchain and diffing byte by byte
located the difference exactly: **4 bytes inserted at offset 32**, holding the public-input count
(`00000005` for register, `00000006` for ours). `ours[:32] + ours[36:]` reproduces the committed
artifact exactly.

### 5.2 …and stripping those bytes was the wrong fix (error 2)

With the trimmed VK the contract stopped rejecting the key and started rejecting the proof
(`ProofRejected`). Verifying the trimmed VK locally explained why:

```
Reason : Not enough public inputs to extract pairing points
```

The real difference was never the byte layout. The on-chain verifier consumes **keccak-transcript**
proofs; the `bb` CLI defaults to a different transcript. Same circuit, same bb version, artifacts
that parse and then fail.

The fix removed the CLI from the path entirely: `scripts/demo-attest.ts` drives our circuit through
the SDK's `CircuitProver`, the same prover the token uses, and takes the VK from
`prover.verificationKey()`. Both are keccak by construction. **Consequence for anyone building on
this: derive the VK from the same prover that will generate the proofs, never from the CLI.**

---

### 5.3 The demos printed everything and then hung

After `main()` returned, the process stayed alive. The scripts finish their output and simply never
exit: `@aztec/bb.js` leaves worker handles open, so Node's event loop still has work and the run
looks stalled at the exact moment it is actually done. It cost a wasted round of the stress suite,
because a chained `demo && stress` never reached the second command.

Fixed by exiting explicitly — but *after* stdout drains, which is the part worth writing down. A
bare `process.exit()` at the end truncates the tail of a piped or redirected run, and the verification
key these scripts print is 3 520 hex characters, so the truncation would be silent and the resulting
deploy would fail later with an opaque proof error:

```ts
main()
  .catch((e) => { console.error(e); process.exitCode = 1; })
  .finally(() => process.stdout.write("", () => process.exit(process.exitCode ?? 0)));
```

Applied to all four scripts. A separate self-inflicted one from the same episode, for anyone
debugging a hung run: `pkill -f "demo-attest.ts"` matches the shell whose own command line contains
that string, so it kills itself. Use `pkill -f "demo-[a]ttest"`.

## 6. Findings reported upstream

Five, all with reproduction.

1. **`addr_f` is not readable by third parties.** It lives in the token's instance storage and
   `address_to_field` is `pub(crate)`. §5.3 of the disclosure spec lists it as "recomputed from the
   token contract address", which no third-party contract can do. A public `address_as_field()`
   accessor would fix it.
2. **A documented command that cannot run.** `examples/rwa/sign-claim` sits in the workspace
   `exclude` set while declaring `authors.workspace = true`; the README's `cargo run
   --manifest-path` fails with *"failed to find a workspace root"*.
3. **`--optimize=false` is incompatible with stellar-cli ≥ 25.2**, which treats `--optimize` as a
   boolean flag. The demo's deploy script fails at the first contract.
4. **`examples/rwa/README.md` documents an impossible `initial_profiles` format.** The parameter is
   `Vec<Val>` — type-erased in the contract spec — so the CLI requires raw XDR-JSON. The README's
   human-readable form is a two-key map and collides with `ScVal`'s externally-tagged serde,
   producing *"invalid value: map, expected map with a single key"*. Working payload:
   ```json
   [{"map":[{"key":{"symbol":"country"},"val":{"vec":[{"symbol":"Individual"},
   {"vec":[{"symbol":"Residence"},{"u32":76}]}]}},{"key":{"symbol":"metadata"},"val":"void"}]}]
   ```
5. **`identity-registry` hardcodes `IdentityType::Individual`** in `add_identity`, so a
   `CountryRelation::Organization` profile is stored as a natural person.
6. **A required claim topic with no trusted issuer is silently ignored.** `verify_identity`
   iterates `(topic, issuers)` pairs; a topic whose issuer list is empty never enters the inner
   loop, so it never raises. An operator who registers a topic to tighten the rules — and forgets
   the issuer — gets **silent non-enforcement**, with no error and no event to notice. Verified
   both ways on testnet: topic 2 registered alone left an unqualified holder authorized; the same
   topic with the issuer trusted for it flipped that holder to refused.

---

7. **`SELECTIVE_DISCLOSURE.md` §9 resolves only `PVK_A` and `C_spend`, which makes the specified
   `disclose_balance_le` evadable.** A confidential account carries value in two commitments, and
   `C_receive` — where incoming transfers sit until the holder rolls them over — is not among the
   state §9's verifier flow reads. For the `ge` shape the omission is sound but slack: spendable ≤
   position, so the predicate can only under-claim (a holder with 400 000 spendable and 200 000
   unmerged holds 600 000 and cannot prove clearing 500 000). For the `le` shape, named in the same
   sentence as though it were a mirror image, the same omission is load-bearing: a concentration
   ceiling is the natural rule to build from it, and a holder can park value in `C_receive` and
   prove compliance while exceeding the cap. Closed here by DB3b, binding both commitments and
   bounding their sum — which `circuits/seize` already had to do. Cost: 43 → 67 ACIR opcodes,
   proving 2.06 s → 2.68 s.

## 6.1 Regulatory profile

`profiles/cvm175.json` expresses the jurisdiction as configuration. Audited against what is
actually enforced, which turned up an overclaim of our own: the minimum position was marked
`enforced`. It is not — it is **attestable**. A holder proves it and a contract records it, but
nothing compels the holder to attest and no operation is blocked for its absence; a consumer
decides what to require. Enforcing it inside a transfer needs the rule in the circuit
(`experiments/circuit-cap-poc`). The field now reads `enforced: false, attestable: true`, and
every claim carries `verified_on_testnet` where we exercised it.

## 6.2 Seals, and one we had not earned

Every claim in the profile now carries `verified_on_testnet` only where we exercised it. Two
corrections came out of the audit:

- **`sac_passthrough` lost its seal.** It is configured — the deployment event records it — but
  its effect cannot be exercised here: the underlying is the native XLM SAC, which has no admin
  and whose `authorized()` is always `true`, so no issuer can deauthorize anyone. Testing the
  cascade needs an underlying with a real issuer. We had marked it verified on the strength of the
  configuration event, which is exactly the mistake this section exists to prevent.
- **Claim topic 2 earned one.** Not because it is active — it is not — but because we proved the
  switch works, in both directions, and restored the state afterwards.

## 6.3 The silent-non-enforcement footgun, and our fix

Finding 6 above is not just a report: `velum-policy` now defends against it. Before delegating,
the adapter reads the topic/issuer map and returns `false` if any registered topic has no issuer.
A deployment in that state is not permissive, it is **unconfigured**, and a compliance gate that
cannot tell the difference should reject.

Demonstrated A/B against the same chain state — topic 2 registered, no issuer bound to it:

| Policy | `is_authorized(alice)` | Meaning |
|---|---|---|
| v1, `CCCQ7Z6F…QXDK` | `true` | the topic is silently unenforced; the holder passes a check that never ran |
| v2, `CDJET5BV…FPKV` | `false` | refuses, because the registry cannot answer what it claims to enforce |

With the registry correctly configured, both return `true` — the guard costs nothing in the
healthy case. State was restored after the test, and the gated token now points at v2
(`ComplianceConfigChanged`); `demo-gate.ts` reproduces unchanged.

**The cost:** two extra cross-contract reads per authorization, on every gated operation. For a
gate whose failure mode is silent under-enforcement, that is the right side to err on. A
deployment that wants the cheaper path can move the check to configuration time — at the price of
going stale when the registry changes.

## 6.4 Wall-clock cost of the demos

Measured end to end on testnet, because it changes how the demo can be presented:

| Script | Real time | Where it goes |
|---|---|---|
| `demo-attest.ts` | **3 m 39 s** | transaction confirmation — register, deposit, merge, attest |
| `demo-gate.ts` | **1 m 55 s** cold | same. A warm run is ~7 s: Alice is already registered, so it takes the deposit path |
| `demo-seize.ts` | not separately timed | dominated by the same register → deposit → merge sequence |
| the proof itself | **2.06 s** | the fast part |

Proving is not the bottleneck; testnet confirmation is. A three-minute video cannot run both live,
so `docs/VIDEO-SCRIPT.md` records each separately and speeds up the waiting visibly rather than
cutting it — the honest edit, not the flattering one.

## 6.5 Two architectural findings from the review, and their fixes

Neither was a defect in what was deployed. Both were fixed the same day; `velum-attest` was
redeployed and the nine probes re-run against the new contract, 9/9.

**`disclose_balance_ge` proved over the *spendable* balance, not the position.** Its public inputs
were `addr_f`, `PVK_A`, `C_spend` and the threshold — no `C_receive`. Investigating that turned the
finding inside out: the omission is not ours, it is what `SELECTIVE_DISCLOSURE.md` §9 specifies its
verifier flow to resolve. For a **floor** it is sound and merely slack (spendable ≤ position, so
the predicate can only under-claim; a holder with 400 000 spendable and 200 000 unmerged holds
600 000 and could not prove clearing 500 000). For the **ceiling** variant the same spec names in
the same sentence, it is a hole: park value in `C_receive`, prove compliance, exceed the cap.
Promoted to upstream **finding 7** and closed here by DB3b — open `C_receive`, bound `v_s + v_r`,
which is what `circuits/seize` already did. Cost: 43 → 67 ACIR opcodes, proving 2.06 s → 2.68 s,
public inputs 6 → 8 (192 → 256 bytes).

**Attestations did not expire.** S3 proves the *proof* cannot be replayed once the balance moves —
that half was already sound, and it is structural, since verification reads the live commitment.
The weak half was the record: `is_attested(account)` answered `true` forever. `is_attested` now
takes `max_age_ledgers` and there is deliberately no argument-free form, so the easiest call to
write is no longer the one that ignores staleness. The window is a parameter rather than contract
state because how long an attestation stays meaningful is a jurisdictional question, and
`profiles/*.json` is where this project keeps those. `u32::MAX` means "ever attested", which a
caller must now say out loud.

Demonstrated on the same record, after the balance moved:

```
ℹ️  the S1 record survives the move, but the window is the caller's:
     is_attested(max_age=1000) = true   is_attested(max_age=0) = false
```

Full review: `docs/REVISAO-ARQUITETURA-2026-08-06.md`.

## 6.6 The presentation PDFs went stale, and were rebuilt

Worth recording because it is the failure mode of any artifact that is generated once and then
diverges. The deck and one-page were built on 2026-08-05, before `velum-seize`, before finding 7
and before `velum-attest` was redeployed. By 2026-08-06 the deck claimed **66 tests** (69) and
**five upstream findings** (seven), and both described the clawback work as a circuit that was
built rather than one verified on-chain. None of it was reachable by grepping the Markdown, because
the numbers live in the HTML the PDFs are rendered from.

Rebuilt from source and re-checked by extracting the text back out of the finished PDFs: no
occurrence of `66 test` or `five upstream` survives, layout intact (deck 10 pages, one-page 1).
The whitepaper PDF is regenerated the same way whenever `docs/WHITEPAPER.md` changes.

The README had the same drift in miniature: its headline transaction still pointed at a proof
verified by `velum-attest` **v1**, a contract no longer in the address table. A judge following the
link would land somewhere the submission does not list. Repointed to `f6c02ceb…1213da`, the run
against the deployed contract.

## 7. Toolchain

`nargo 1.0.0-beta.11` · `bb 0.87.0` (CLI, for local circuit work only) · `@aztec/bb.js 0.87.0`
(the prover that matters — keccak transcript) · `stellar-cli 25.2.0` · Rust + `wasm32v1-none` ·
soroban-sdk `=26.1.0` · OpenZeppelin `stellar-contracts` rev `539968f`.

Noir rejects non-ASCII source, comments included.

Reproduction steps: `circuits/README.md` for the circuits, and for the on-chain demo:

```bash
cd refs/ct-demo/packages/sdk
VELUM_ATTEST=<contract-id> pnpm exec tsx ../../../../scripts/demo-attest.ts
VELUM_SEIZE=<contract-id>  pnpm exec tsx ../../../../scripts/demo-seize.ts

VELUM_ATTEST=<id> VELUM_SEIZE=<id> pnpm exec tsx ../../../../scripts/stress.ts   # the 9 probes
```

Run either without its variable to print the verification key needed to deploy that contract.
**Derive the key from the same prover that will generate the proofs** — see §5.2.

---

## 8. What is not done

- The clawback migration (register-circuit escrow, new VK, re-registration) is designed and
  priced in the whitepaper §11.6, not built. The seize circuit verifies on-chain (§2.2), but no
  value moves and the escrow is simulated with a test account's keys.
- Aggregates across accounts — concentration by tranche, subordination ratio — remain open.

Testnet only. The UltraHonk verifier is developer preview and unaudited.
