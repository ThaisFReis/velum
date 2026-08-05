use super::main;
use stellar_confidential_lib::{
    H, commit, derive_spend_r, domain, encrypt_balance, poseidon_with_domain, scalar_mul,
    vk_from_sk,
};

// Fixtures are self-derived with the same lib primitives the circuit
// constrains, so a lib drift surfaces as a failing test.
//
// The HOLDER-side facts (sk-derived) set up the chain state; the AUDITOR-side
// witness set for `main` is exactly what Test A (experiments/clawback-poc)
// showed the auditor recovers: vk from the escrow, (v_s, r_s) from the
// checkpoint, (v_r, r_r) from transfer ciphertexts and zero-blinded deposits.
global SK: Field = 0x1f2e3d4c5b6a79887766554433221100;
global ADDR_F: Field = 0x2b7c1e5a0f3d94682c5e8a1b4d7f0396;
global V_S: Field = 700_000; // spendable balance
global SIGMA_OLD: Field = 0x0102030405060708090a0b0c0d0e0f10; // last owner op
global V_R: Field = 300_000; // receiving balance (transfers + deposits)
global R_R: Field = 0x0b0c0d0e0f101112131415161718191a; // its aggregate blinding
global ALPHA: Field = 250_000; // seized amount (public)
global SIGMA_NEW: Field = 0x1112131415161718191a1b1c1d1e1f20; // seize-event nonce

struct Fixture {
    vk: Field,
    r_s: Field,
    pvk: (Field, Field),
    c_spend: (Field, Field),
    c_receive: (Field, Field),
}

fn fixture() -> Fixture {
    let vk = vk_from_sk(SK, ADDR_F);
    let r_s = derive_spend_r(vk, SIGMA_OLD); // canonical rule: what the chain holds
    let pvk = scalar_mul(vk, H);
    let c_spend = commit(V_S, r_s);
    let c_receive = commit(V_R, R_R);
    Fixture {
        vk,
        r_s,
        pvk: (pvk.x, pvk.y),
        c_spend: (c_spend.x, c_spend.y),
        c_receive: (c_receive.x, c_receive.y),
    }
}

/// Drives `main` with the fixture state and the given seize parameters,
/// deriving the honest post-seizure outputs unless overridden.
fn run_seize(f: Fixture, v_s: Field, v_r: Field, alpha: Field) {
    let remaining = v_s + v_r - alpha;
    let r_new = derive_spend_r(f.vk, SIGMA_NEW);
    let c_new = commit(remaining, r_new);
    let b_new = encrypt_balance(remaining, f.vk, SIGMA_NEW);
    main(
        f.vk, v_s, f.r_s, v_r, R_R, f.pvk.0, f.pvk.1, f.c_spend.0, f.c_spend.1, f.c_receive.0,
        f.c_receive.1, alpha, SIGMA_NEW, c_new.x, c_new.y, b_new,
    );
}

// ---------- the seize succeeds when it should ----------

#[test]
fn accepts_partial_seizure() {
    run_seize(fixture(), V_S, V_R, ALPHA);
}

#[test]
fn accepts_full_seizure() {
    // alpha == v_s + v_r: remaining is zero, still in range.
    run_seize(fixture(), V_S, V_R, V_S + V_R);
}

#[test]
fn accepts_zero_seizure() {
    // Degenerate but well-formed: a "seize" of nothing re-checkpoints the
    // account under sigma_new.
    run_seize(fixture(), V_S, V_R, 0);
}

// ---------- the bound: alpha cannot exceed the balance ----------

#[test(should_fail)]
fn rejects_alpha_above_total() {
    // Z4: remaining wraps below zero and leaves the 127-bit range.
    run_seize(fixture(), V_S, V_R, V_S + V_R + 1);
}

#[test(should_fail)]
fn rejects_alpha_out_of_range() {
    // Z4 on alpha itself: a 128-bit alpha is rejected before the bound.
    let two_127: Field = 0x80000000000000000000000000000000;
    run_seize(fixture(), V_S, V_R, two_127);
}

// ---------- binding: wrong witnesses open nothing ----------

#[test(should_fail)]
fn rejects_wrong_vk() {
    // Z1: a vk that does not match the target's PVK_A. This is the constraint
    // that stops a proof built for one account being applied to another --
    // and, via Z5/Z7, guarantees the holder can still recover afterwards.
    let f = fixture();
    let bad = Fixture {
        vk: f.vk + 1,
        r_s: f.r_s,
        pvk: f.pvk,
        c_spend: f.c_spend,
        c_receive: f.c_receive,
    };
    run_seize(bad, V_S, V_R, ALPHA);
}

#[test(should_fail)]
fn rejects_overstated_spendable() {
    // Z2: claiming a bigger spendable balance than the commitment opens to
    // (an auditor trying to seize more than exists by inflating v_s).
    run_seize(fixture(), V_S + 500_000, V_R, ALPHA);
}

#[test(should_fail)]
fn rejects_overstated_receiving() {
    // Z3: same attack on the receiving side.
    run_seize(fixture(), V_S, V_R + 500_000, ALPHA);
}

#[test(should_fail)]
fn rejects_tampered_new_commitment() {
    // Z6: the authority cannot write a post-seizure commitment that does not
    // match `remaining` under the canonical blinding -- e.g. crediting the
    // holder less than the proof implies.
    let f = fixture();
    let remaining = V_S + V_R - ALPHA;
    let r_new = derive_spend_r(f.vk, SIGMA_NEW);
    let c_bad = commit(remaining - 1, r_new);
    let b_new = encrypt_balance(remaining, f.vk, SIGMA_NEW);
    main(
        f.vk, V_S, f.r_s, V_R, R_R, f.pvk.0, f.pvk.1, f.c_spend.0, f.c_spend.1, f.c_receive.0,
        f.c_receive.1, ALPHA, SIGMA_NEW, c_bad.x, c_bad.y, b_new,
    );
}

#[test(should_fail)]
fn rejects_tampered_new_checkpoint() {
    // Z7: nor a checkpoint that decrypts to a different balance than the
    // commitment holds (desynchronizing the holder's wallet).
    let f = fixture();
    let remaining = V_S + V_R - ALPHA;
    let r_new = derive_spend_r(f.vk, SIGMA_NEW);
    let c_new = commit(remaining, r_new);
    let b_bad = encrypt_balance(remaining - 1, f.vk, SIGMA_NEW);
    main(
        f.vk, V_S, f.r_s, V_R, R_R, f.pvk.0, f.pvk.1, f.c_spend.0, f.c_spend.1, f.c_receive.0,
        f.c_receive.1, ALPHA, SIGMA_NEW, c_new.x, c_new.y, b_bad,
    );
}

// ---------- the holder recovers afterwards ----------

#[test]
fn holder_recovers_post_seizure_state() {
    // After a valid seize, the holder -- with sk only, no out-of-band data --
    // re-derives the blinding, decrypts the checkpoint, and opens the new
    // commitment. This is the Test A round-trip run against this circuit's
    // outputs, closing the loop between enforcement and recovery.
    let f = fixture();
    let remaining = V_S + V_R - ALPHA;
    let r_new = derive_spend_r(f.vk, SIGMA_NEW);
    let c_new = commit(remaining, r_new);
    let b_new = encrypt_balance(remaining, f.vk, SIGMA_NEW);

    // Holder side, from sk and the seize event (sigma_new, b_tilde_new):
    let vk_holder = vk_from_sk(SK, ADDR_F);
    let mask = poseidon_with_domain(domain::ENCRYPTED_BALANCE, [vk_holder, SIGMA_NEW]);
    let v_recovered = b_new - mask;
    let r_recovered = derive_spend_r(vk_holder, SIGMA_NEW);
    let c_recovered = commit(v_recovered, r_recovered);

    assert(v_recovered == remaining);
    assert(c_recovered.x == c_new.x);
    assert(c_recovered.y == c_new.y);
}

#[test]
fn print_prover_fixture() {
    let f = fixture();
    let remaining = V_S + V_R - ALPHA;
    let r_new = derive_spend_r(f.vk, SIGMA_NEW);
    let c_new = commit(remaining, r_new);
    let b_new = encrypt_balance(remaining, f.vk, SIGMA_NEW);
    let (vk, r_s) = (f.vk, f.r_s);
    let (px, py) = f.pvk;
    let (csx, csy) = f.c_spend;
    let (crx, cry) = f.c_receive;
    let (cnx, cny) = (c_new.x, c_new.y);
    println(f"vk = {vk}");
    println(f"r_s = {r_s}");
    println(f"pvk_a_x = {px}");
    println(f"pvk_a_y = {py}");
    println(f"c_spend_x = {csx}");
    println(f"c_spend_y = {csy}");
    println(f"c_receive_x = {crx}");
    println(f"c_receive_y = {cry}");
    println(f"c_spend_new_x = {cnx}");
    println(f"c_spend_new_y = {cny}");
    println(f"b_tilde_new = {b_new}");
}
