use stellar_confidential_lib::{H, commit, scalar_mul, vk_from_sk};

mod tests;

// D-balance disclosure circuit, predicate form `ge`
// -- SELECTIVE_DISCLOSURE.md Section 9.
//
// The account holder proves a property of their CURRENT confidential balance:
// "my spendable balance is at least v_threshold". The proof's mere validity
// asserts the predicate -- no amount, ciphertext, or opening is revealed, and
// there is nothing for a verifier to decrypt.
//
// Upstream specifies this circuit (Section 9, constraints D1/D2/DB3/DB4/D5) but
// ships only `disclose_recipient` and `disclose_sender`. This is the missing
// predicate variant, built to the published spec.
//
// WHY THIS ONE MATTERS FOR REGULATED FUNDS
// ----------------------------------------
// Amount rules cannot be enforced at the token's `Policy` interface: it sees an
// address and nothing else, because balances are Pedersen commitments. Nor can
// the *sender* of a transfer prove anything about the recipient's balance -- it
// cannot open a commitment it has no opening for. The holder can: it retains
// (v_s, r_s) as ordinary wallet state. So the quantitative half of compliance is
// provable exactly where the opening lives, by the party that holds it:
//
//   * "position >= qualified-investor minimum"  (this circuit)
//   * "position <= concentration cap"           (the `le` sibling)
//
// ON-CHAIN VERIFICATION (SELECTIVE_DISCLOSURE.md Sections 5.4 / 14)
// -----------------------------------------------------------------
// Upstream verifies disclosure proofs off-chain and marks the on-chain verifier
// out of scope. The predicate form needs no recipient binding (no U-block), so
// it is the shape an on-chain verifier consumes directly. The Section 5.2
// trust boundary is what makes that sound, and it dictates the contract's job:
// EVERY public input must come from somewhere other than the prover.
//
//   addr_f, PVK_A, C_spend  <- read from the confidential-token contract
//   v_threshold             <- read from the regulatory-profile contract
//   proof                   <- the only thing the prover supplies
//
// Constraints
// -----------
//   D1   vk_A    = Poseidon2(delta_vk, sk_A, addr_f)   Contract-bound viewing
//                                                      key (mirrors T2).
//   D2   PVK_A   = vk_A * H                            Binds the proof to the
//                                                      on-chain account record.
//   DB3  C_spend = v_s * G + r_s * H                   Opening of the current
//                                                      spendable balance. By
//                                                      Pedersen binding no
//                                                      alternative opening
//                                                      exists, so the witnessed
//                                                      v_s IS the balance.
//   D5   v_s in [0, 2^127)                             Range validity: stops a
//                                                      wrapped-negative v_s
//                                                      from satisfying DB4.
//   DB4  v_s >= v_threshold                            The predicate, as a
//                                                      non-negative difference.
//   DB4b v_threshold in [0, 2^127)                     Defensive, beyond spec:
//                                                      a malformed threshold
//                                                      near the field modulus
//                                                      would make DB4 vacuous.
//                                                      Cheap; keeps soundness
//                                                      independent of how
//                                                      carefully the caller
//                                                      populates the profile.
//
// Public inputs (6 fields, in order)
// ----------------------------------
//   Idx  Param        Symbol        Verifier source (Section 5.3)
//   ---  -----        ------        --------------------------------------
//   0    addr_f       addr_f        Recomputed from the token contract
//                                   address (DESIGN.md Section 2.7).
//   1    pvk_a_x      PVK_A.x       `confidential_balance(account)`
//   2    pvk_a_y      PVK_A.y        .viewing_public_key.
//   3    c_spend_x    C_spend.x     `confidential_balance(account)`
//   4    c_spend_y    C_spend.y      .spendable_commitment.
//   5    v_threshold  V_threshold   The regulatory profile.
//
// Freshness: C_spend is a public input read from live chain state, so a proof
// stops verifying the moment the balance moves. An old proof can only be
// replayed against the very state it was made for -- where it is still true.
//
// NOT PRODUCTION READY: built on the confidential-token developer preview,
// whose verifier and circuits are unaudited. Testnet only.
fn main(
    // Private witnesses.
    sk: Field,
    v_s: Field,
    r_s: Field,
    v_r: Field,
    r_r: Field,
    // Public inputs.
    addr_f: pub Field,
    pvk_a_x: pub Field,
    pvk_a_y: pub Field,
    c_spend_x: pub Field,
    c_spend_y: pub Field,
    c_receive_x: pub Field,
    c_receive_y: pub Field,
    v_threshold: pub Field,
) {
    // D1
    let vk = vk_from_sk(sk, addr_f);

    // D2
    let pvk_derived = scalar_mul(vk, H);
    assert(pvk_derived.x == pvk_a_x);
    assert(pvk_derived.y == pvk_a_y);

    // DB3 -- the spendable commitment opens to v_s.
    let c_spend_derived = commit(v_s, r_s);
    assert(c_spend_derived.x == c_spend_x);
    assert(c_spend_derived.y == c_spend_y);

    // DB3b -- the receiving commitment opens to v_r. Beyond SELECTIVE_DISCLOSURE.md
    // section 9, whose verifier flow resolves only PVK_A and C_spend. Without this the
    // predicate is over the SPENDABLE balance rather than the position, which is sound
    // but slack for a floor and outright evadable for a ceiling: a holder parks value
    // in C_receive and proves to be under a cap while holding more than it. The mirror
    // circuit disclose_balance_le, which the spec also names, inherits that hole. The
    // seize circuit already binds both commitments; this matches it.
    let c_receive_derived = commit(v_r, r_r);
    assert(c_receive_derived.x == c_receive_x);
    assert(c_receive_derived.y == c_receive_y);

    // D5 -- must precede DB4: it is what stops a wrapped-negative balance.
    v_s.assert_max_bit_size::<127>();
    v_r.assert_max_bit_size::<127>();

    // DB4b
    v_threshold.assert_max_bit_size::<127>();

    // DB4 -- v_s + v_r >= v_threshold, expressed as a non-negative difference in the
    // same 127-bit idiom the transfer circuit uses for its range validity.
    (v_s + v_r - v_threshold).assert_max_bit_size::<127>();
}
