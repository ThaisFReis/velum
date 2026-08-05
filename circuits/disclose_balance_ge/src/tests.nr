use super::main;
use stellar_confidential_lib::{H, commit, scalar_mul, vk_from_sk};

// Fixtures are self-derived: each test computes the public inputs from the
// private witnesses with the same lib primitives the circuit uses, so a drift
// in the lib surfaces as a failing test rather than a stale constant.
global SK: Field = 0x1f2e3d4c5b6a79887766554433221100;
global ADDR_F: Field = 0x2b7c1e5a0f3d94682c5e8a1b4d7f0396;
global V_S: Field = 1_000_000; // holder's spendable balance
global R_S: Field = 0x0a1b2c3d4e5f60718293a4b5c6d7e8f9;

/// Drives `main` with a self-consistent fixture and the given threshold.
fn run(v_s: Field, r_s: Field, v_threshold: Field) {
    let vk = vk_from_sk(SK, ADDR_F);
    let pvk = scalar_mul(vk, H);
    let c_spend = commit(v_s, r_s);
    main(SK, v_s, r_s, ADDR_F, pvk.x, pvk.y, c_spend.x, c_spend.y, v_threshold);
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
    main(SK, 9_000_000, R_S, ADDR_F, pvk.x, pvk.y, c_spend.x, c_spend.y, 5_000_000);
}

#[test(should_fail)]
fn rejects_wrong_secret_key() {
    // D1/D2: another account's key cannot satisfy this account's PVK_A, so a
    // proof cannot be produced on someone else's behalf.
    let vk = vk_from_sk(SK, ADDR_F);
    let pvk = scalar_mul(vk, H);
    let c_spend = commit(V_S, R_S);
    main(SK + 1, V_S, R_S, ADDR_F, pvk.x, pvk.y, c_spend.x, c_spend.y, 500_000);
}

#[test(should_fail)]
fn rejects_proof_replayed_on_another_token() {
    // D1: vk is contract-bound via addr_f, so a proof made for one confidential
    // token does not verify against another.
    let vk = vk_from_sk(SK, ADDR_F);
    let pvk = scalar_mul(vk, H);
    let c_spend = commit(V_S, R_S);
    main(SK, V_S, R_S, ADDR_F + 1, pvk.x, pvk.y, c_spend.x, c_spend.y, 500_000);
}

#[test(should_fail)]
fn rejects_stale_commitment() {
    // Freshness: the balance moved, so C_spend read from the chain no longer
    // matches the opening the holder is proving against.
    let vk = vk_from_sk(SK, ADDR_F);
    let pvk = scalar_mul(vk, H);
    let c_stale = commit(V_S + 1, R_S); // chain now holds a different commitment
    main(SK, V_S, R_S, ADDR_F, pvk.x, pvk.y, c_stale.x, c_stale.y, 500_000);
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
    let (px, py, cx, cy) = (pvk.x, pvk.y, c.x, c.y);
    println(f"pvk_a_x = {px}");
    println(f"pvk_a_y = {py}");
    println(f"c_spend_x = {cx}");
    println(f"c_spend_y = {cy}");
}
