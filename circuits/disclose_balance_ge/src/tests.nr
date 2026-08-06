use super::main;
use stellar_confidential_lib::{H, commit, scalar_mul, vk_from_sk};

// Fixtures are self-derived: each test computes the public inputs from the
// private witnesses with the same lib primitives the circuit uses, so a drift
// in the lib surfaces as a failing test rather than a stale constant.
global SK: Field = 0x1f2e3d4c5b6a79887766554433221100;
global ADDR_F: Field = 0x2b7c1e5a0f3d94682c5e8a1b4d7f0396;
global V_S: Field = 1_000_000; // holder's spendable balance
global R_S: Field = 0x0a1b2c3d4e5f60718293a4b5c6d7e8f9;
global R_R: Field = 0x0f1e2d3c4b5a69788796a5b4c3d2e1f0;

/// Drives `main` with a self-consistent fixture over the whole position.
fn run_split(v_s: Field, r_s: Field, v_r: Field, r_r: Field, v_threshold: Field) {
    let vk = vk_from_sk(SK, ADDR_F);
    let pvk = scalar_mul(vk, H);
    let c_spend = commit(v_s, r_s);
    let c_receive = commit(v_r, r_r);
    main(
        SK, v_s, r_s, v_r, r_r, ADDR_F, pvk.x, pvk.y,
        c_spend.x, c_spend.y, c_receive.x, c_receive.y, v_threshold,
    );
}

/// The common case: nothing pending on the receiving side.
fn run(v_s: Field, r_s: Field, v_threshold: Field) {
    run_split(v_s, r_s, 0, R_R, v_threshold);
}

// ---------- the predicate holds ----------

#[test]
fn accepts_balance_above_threshold() {
    // 1_000_000 >= 500_000: a qualified-investor floor, comfortably cleared.
    run(V_S, R_S, 500_000);
}

#[test]
fn accepts_balance_exactly_at_threshold() {
    // Boundary: v_s - v_threshold == 0 is a valid non-negative difference.
    run(V_S, R_S, V_S);
}

#[test]
fn accepts_zero_threshold() {
    // A profile with no floor degenerates to "prove you opened the commitment".
    run(V_S, R_S, 0);
}

// ---------- the predicate fails ----------

#[test(should_fail)]
fn rejects_balance_below_threshold() {
    // DB4: 1_000_000 < 1_000_001, so the difference wraps and leaves the
    // 127-bit range. The verifier learns only that the proof is invalid --
    // never how far below the floor the holder actually is.
    run(V_S, R_S, V_S + 1);
}

#[test(should_fail)]
fn rejects_balance_far_below_threshold() {
    run(1, R_S, 500_000);
}

// ---------- binding: the proof cannot be moved or forged ----------

#[test(should_fail)]
fn rejects_wrong_commitment_opening() {
    // DB3: claiming a larger balance than the commitment opens to. The holder
    // knows (v_s, r_s) for 1_000_000; asserting 9_000_000 breaks the opening.
    let vk = vk_from_sk(SK, ADDR_F);
    let pvk = scalar_mul(vk, H);
    let c_spend = commit(V_S, R_S); // commitment to the REAL balance
    let cr = commit(0, R_R);
    main(SK, 9_000_000, R_S, 0, R_R, ADDR_F, pvk.x, pvk.y, c_spend.x, c_spend.y, cr.x, cr.y, 5_000_000);
}

#[test(should_fail)]
fn rejects_wrong_secret_key() {
    // D1/D2: another account's key cannot satisfy this account's PVK_A, so a
    // proof cannot be produced on someone else's behalf.
    let vk = vk_from_sk(SK, ADDR_F);
    let pvk = scalar_mul(vk, H);
    let c_spend = commit(V_S, R_S);
    let cr = commit(0, R_R);
    main(SK + 1, V_S, R_S, 0, R_R, ADDR_F, pvk.x, pvk.y, c_spend.x, c_spend.y, cr.x, cr.y, 500_000);
}

#[test(should_fail)]
fn rejects_proof_replayed_on_another_token() {
    // D1: vk is contract-bound via addr_f, so a proof made for one confidential
    // token does not verify against another.
    let vk = vk_from_sk(SK, ADDR_F);
    let pvk = scalar_mul(vk, H);
    let c_spend = commit(V_S, R_S);
    let cr = commit(0, R_R);
    main(SK, V_S, R_S, 0, R_R, ADDR_F + 1, pvk.x, pvk.y, c_spend.x, c_spend.y, cr.x, cr.y, 500_000);
}

#[test(should_fail)]
fn rejects_stale_commitment() {
    // Freshness: the balance moved, so C_spend read from the chain no longer
    // matches the opening the holder is proving against.
    let vk = vk_from_sk(SK, ADDR_F);
    let pvk = scalar_mul(vk, H);
    let c_stale = commit(V_S + 1, R_S); // chain now holds a different commitment
    let cr = commit(0, R_R);
    main(SK, V_S, R_S, 0, R_R, ADDR_F, pvk.x, pvk.y, c_stale.x, c_stale.y, cr.x, cr.y, 500_000);
}

// ---------- soundness of the defensive constraint ----------

#[test(should_fail)]
fn rejects_malformed_threshold_near_field_modulus() {
    // DB4b: without the threshold range check, a threshold just below the field
    // modulus would make (v_s - v_threshold) wrap into a small positive value
    // and satisfy DB4 vacuously. This is the attack that constraint closes.
    run(V_S, R_S, -1);
}

#[test]
fn print_fixture_public_inputs() {
    let vk = vk_from_sk(SK, ADDR_F);
    let pvk = scalar_mul(vk, H);
    let c = commit(V_S, R_S);
    let cr = commit(0, R_R);
    let (px, py, cx, cy) = (pvk.x, pvk.y, c.x, c.y);
    let (rx, ry) = (cr.x, cr.y);
    println(f"c_receive_x = {rx}");
    println(f"c_receive_y = {ry}");
    println(f"pvk_a_x = {px}");
    println(f"pvk_a_y = {py}");
    println(f"c_spend_x = {cx}");
    println(f"c_spend_y = {cy}");
}

// ---------- the scope of the claim, made executable ----------

#[test]
fn accepts_a_position_split_across_spendable_and_receiving() {
    // 400_000 spendable + 200_000 received but not yet rolled over is a position of
    // 600_000, and it clears 500_000. Binding only C_spend -- which is what
    // SELECTIVE_DISCLOSURE.md section 9 resolves -- would refuse this holder, and would
    // let the mirrored ceiling variant be evaded by parking value in C_receive. DB3b
    // closes both.
    run_split(400_000, R_S, 200_000, R_R, 500_000);
}

#[test(should_fail)]
fn rejects_a_position_still_short_once_both_sides_are_counted() {
    // The sum is what is bounded: 300_000 + 100_000 < 500_000.
    run_split(300_000, R_S, 100_000, R_R, 500_000);
}

#[test(should_fail)]
fn rejects_an_unopenable_receiving_balance() {
    // DB3b is a real opening, not a declaration: a holder cannot inflate the position
    // by claiming a v_r whose commitment they cannot produce.
    let vk = vk_from_sk(SK, ADDR_F);
    let pvk = scalar_mul(vk, H);
    let c_spend = commit(400_000, R_S);
    let c_receive = commit(200_000, R_R);
    main(
        SK, 400_000, R_S, 900_000, R_R, ADDR_F, pvk.x, pvk.y,
        c_spend.x, c_spend.y, c_receive.x, c_receive.y, 500_000,
    );
}
