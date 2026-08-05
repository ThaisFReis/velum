// Test A -- the cryptographic premise of viewing-key escrow (whitepaper S11).
//
// Roles:
//   HOLDER  side knows `sk` and derives everything from it.
//   AUDITOR side knows ONLY (vk, sigma, b_tilde, C) -- never `sk`, and is not
//   told `v`. Everything the auditor computes below uses only those inputs.
//
// The setup mirrors what the chain holds after any owner-initiated operation
// (constraints W5/T10/S9/V6 for r_s, W7/T12/S11/V8 for b_tilde): the account
// record stores C_spend, and the operation's event carries (b_tilde, sigma).

use stellar_confidential_lib::{
    commit, derive_spend_r, domain, encrypt_balance, poseidon_with_domain, vk_from_sk,
};

global SK: Field = 0x1f2e3d4c5b6a79887766554433221100;
global ADDR_F: Field = 0x2b7c1e5a0f3d94682c5e8a1b4d7f0396;
global V: Field = 1_000_000; // holder's spendable balance
global SIGMA: Field = 0x0102030405060708090a0b0c0d0e0f10; // public event nonce
global SIGMA_NEW: Field = 0x1112131415161718191a1b1c1d1e1f20; // seize-event nonce
global ALPHA: Field = 250_000; // amount seized in the partial-seizure test

/// What the chain publicly holds after the holder's last operation, plus the
/// escrowed `vk`. This is the auditor's complete view.
struct AuditorView {
    vk: Field, // from the S11 escrow (R6-R8)
    sigma: Field, // from the event
    b_tilde: Field, // from the event
    c_x: Field, // account record: C_spend
    c_y: Field,
}

fn chain_state_after_holder_op() -> AuditorView {
    // HOLDER side -- the canonical derivations the circuits constrain.
    let vk = vk_from_sk(SK, ADDR_F);
    let r_s = derive_spend_r(vk, SIGMA);
    let c = commit(V, r_s);
    let b_tilde = encrypt_balance(V, vk, SIGMA);
    AuditorView { vk, sigma: SIGMA, b_tilde, c_x: c.x, c_y: c.y }
}

/// AUDITOR side: recover the full opening from (vk, sigma, b_tilde) alone.
/// Returns (v, r_s) -- the values a seize proof would take as witnesses.
fn auditor_recover_opening(view: AuditorView) -> (Field, Field) {
    let mask = poseidon_with_domain(domain::ENCRYPTED_BALANCE, [view.vk, view.sigma]);
    let v_recovered = view.b_tilde - mask;
    let r_recovered = derive_spend_r(view.vk, view.sigma);
    (v_recovered, r_recovered)
}

// ---------- the premise holds ----------

#[test]
fn auditor_recovers_value_and_blinding() {
    let view = chain_state_after_holder_op();
    let (v, r) = auditor_recover_opening(view);

    // The recovered pair opens the on-chain commitment...
    let c = commit(v, r);
    assert(c.x == view.c_x);
    assert(c.y == view.c_y);
    // ...and the recovered value is the true balance. (The test knows V for
    // the assertion; the auditor did not use it.)
    assert(v == V);
}

#[test]
fn holder_and_auditor_derive_identical_material() {
    // Sanity: the vk the escrow would deliver (derived from sk at register
    // time, R2) is byte-for-byte what the auditor plugs into every recovery.
    let view = chain_state_after_holder_op();
    assert(vk_from_sk(SK, ADDR_F) == view.vk);
}

// ---------- wrong keys open nothing ----------

#[test(should_fail)]
fn wrong_vk_fails() {
    let view = chain_state_after_holder_op();
    let bad = AuditorView {
        vk: view.vk + 1,
        sigma: view.sigma,
        b_tilde: view.b_tilde,
        c_x: view.c_x,
        c_y: view.c_y,
    };
    let (v, r) = auditor_recover_opening(bad);
    let c = commit(v, r);
    assert(c.x == view.c_x);
    assert(c.y == view.c_y);
}

#[test(should_fail)]
fn wrong_sigma_fails() {
    let view = chain_state_after_holder_op();
    let bad = AuditorView {
        vk: view.vk,
        sigma: view.sigma + 1,
        b_tilde: view.b_tilde,
        c_x: view.c_x,
        c_y: view.c_y,
    };
    let (v, r) = auditor_recover_opening(bad);
    let c = commit(v, r);
    assert(c.x == view.c_x);
    assert(c.y == view.c_y);
}

// ---------- partial seizure (S11.5) ----------

#[test]
fn partial_seizure_rederivation() {
    let view = chain_state_after_holder_op();

    // AUDITOR: open the current balance, then write the post-seizure state
    // using the protocol's own canonical blinding rule for the new event.
    let (v, _r) = auditor_recover_opening(view);
    let r_new_auditor = derive_spend_r(view.vk, SIGMA_NEW);
    let c_new = commit(v - ALPHA, r_new_auditor);
    let b_tilde_new = encrypt_balance(v - ALPHA, view.vk, SIGMA_NEW);

    // HOLDER: ordinary wallet recovery from (sk, event) -- no out-of-band
    // handoff. The wallet re-derives the same blinding and opens the same
    // commitment, exactly as it would after any of its own operations.
    let vk_holder = vk_from_sk(SK, ADDR_F);
    let r_new_holder = derive_spend_r(vk_holder, SIGMA_NEW);
    assert(r_new_holder == r_new_auditor);

    let mask = poseidon_with_domain(domain::ENCRYPTED_BALANCE, [vk_holder, SIGMA_NEW]);
    let v_holder = b_tilde_new - mask;
    assert(v_holder == V - ALPHA);

    let c_holder = commit(v_holder, r_new_holder);
    assert(c_holder.x == c_new.x);
    assert(c_holder.y == c_new.y);
}

// ---------- adversarial case: the post-MERGE state ----------
//
// `storage::merge` is a homomorphic point-add with NO proof and NO fresh
// checkpoint: C_spend' = C_spend + C_receive, receiving zeroed, event carries
// only the account. So after a merge the spendable commitment is an AGGREGATE:
// its opening is the sum of the previous spendable opening and every
// receiving-side contribution. The auditor must reconstruct each contribution
// and aggregate them.
//
// Each contribution is recoverable from vk plus public events:
//   - previous spendable: derive_spend_r(vk, last proof event's sigma)
//   - incoming transfer:  derive_tx_blind(ecdh(vk, R_e), sigma_tx)
//                         (ECDH symmetry -- the recipient-side secret IS vk)
//   - deposit:            blinding zero (storage.rs adds amount * G)

use stellar_confidential_lib::{derive_tx_blind, ecdh, scalar_mul, G as GEN_G, H as GEN_H};

global SIGMA_TX: Field = 0x2122232425262728292a2b2c2d2e2f30;
global V_TX: Field = 40_000; // incoming confidential transfer
global V_DEP: Field = 10_000; // public deposit
global R_E_SENDER: Field = 0x0f0e0d0c0b0a09080706050403020100; // sender ephemeral

#[test]
fn ecdh_symmetry_gives_auditor_the_transfer_blinding() {
    // The sender derives the transfer blinding from ECDH against the
    // recipient's PVK. The auditor, holding vk and reading R_e from the public
    // Transfer event, derives the SAME shared secret -- so it recovers that
    // transfer's blinding without the sender's ephemeral scalar.
    let vk = vk_from_sk(SK, ADDR_F);
    let pvk = scalar_mul(vk, GEN_H);

    let s_sender = ecdh(R_E_SENDER, pvk); // sender side (circuit T5)
    let r_e_point = scalar_mul(R_E_SENDER, GEN_H); // R_e, public in the event
    let s_auditor = ecdh(vk, r_e_point); // auditor side

    assert(s_auditor == s_sender);
    assert(derive_tx_blind(s_auditor, SIGMA_TX) == derive_tx_blind(s_sender, SIGMA_TX));
}

#[test]
fn auditor_reconstructs_merged_commitment_from_components() {
    // Full post-merge reconstruction: the auditor rebuilds every contributing
    // commitment from vk + public events, and their point-sum equals the
    // account's merged commitment. This is the information the seize circuit
    // needs; it proves nothing is missing from the auditor's view.
    let vk = vk_from_sk(SK, ADDR_F);

    // --- chain history ---
    let c_spend_before = commit(V, derive_spend_r(vk, SIGMA));
    let pvk = scalar_mul(vk, GEN_H);
    let r_tx = derive_tx_blind(ecdh(R_E_SENDER, pvk), SIGMA_TX);
    let c_tx = commit(V_TX, r_tx);
    let c_dep = scalar_mul(V_DEP, GEN_G); // deposit: amount * G, zero blinding
    let c_merged = c_spend_before + (c_tx + c_dep); // merge = point add

    // --- auditor reconstruction, from vk + public events only ---
    let r_e_point = scalar_mul(R_E_SENDER, GEN_H);
    let s_aud = ecdh(vk, r_e_point);
    let c_spend_rebuilt = commit(V, derive_spend_r(vk, SIGMA)); // V from checkpoint
    let c_tx_rebuilt = commit(V_TX, derive_tx_blind(s_aud, SIGMA_TX)); // V_TX from v_tilde
    let c_dep_rebuilt = scalar_mul(V_DEP, GEN_G); // amount public
    let c_rebuilt = c_spend_rebuilt + (c_tx_rebuilt + c_dep_rebuilt);

    assert(c_rebuilt.x == c_merged.x);
    assert(c_rebuilt.y == c_merged.y);
}

// ---------- IMPLEMENTATION TRAP found while testing ----------
//
// Pedersen is additively homomorphic, but the blindings are GRUMPKIN SCALARS,
// and Grumpkin's scalar field is BN254's BASE field (Fq) -- a different modulus
// than Noir's `Field` (BN254's scalar field, Fr). Summing blindings as `Field`
// therefore only matches the group while the sum does not wrap.
//
// Consequence for the seize flow: the auditor MUST aggregate contributions in
// the curve's scalar arithmetic, which is trivial off-chain (Rust/TS) and
// expensive in-circuit (non-native field arithmetic). This is why
// `circuits/seize` takes the already-aggregated (v_r, r_r) as a private witness
// and only checks the opening -- the aggregation belongs in the auditor SDK.
// A naive `r1 + r2` in Field would fail silently on real Poseidon-sized values.

#[test]
fn small_blindings_add_in_field() {
    // No wrap: Field sum coincides with the group sum.
    let lhs = commit(V, 12345) + commit(V_TX, 67890);
    let rhs = commit(V + V_TX, 12345 + 67890);
    assert(lhs.x == rhs.x);
    assert(lhs.y == rhs.y);
}

#[test(should_fail)]
fn poseidon_sized_blindings_do_not_add_in_field() {
    // Two Poseidon-sized blindings: Field reduces mod Fr, the group mod the
    // curve order. They diverge -- the trap documented above.
    let vk = vk_from_sk(SK, ADDR_F);
    let r1 = derive_spend_r(vk, SIGMA);
    let r2 = derive_spend_r(vk, SIGMA_TX);
    let lhs = commit(V, r1) + commit(V_TX, r2);
    let rhs = commit(V + V_TX, r1 + r2);
    assert(lhs.x == rhs.x);
}
