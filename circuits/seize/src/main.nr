use stellar_confidential_lib::{H, commit, derive_spend_r, encrypt_balance, scalar_mul};

mod tests;

// Seize circuit -- Velum whitepaper Section 11 (Test B).
//
// Individual clawback under confidentiality: the AUDITOR (not the holder)
// proves it knows the openings of the target account's spendable and
// receiving commitments, that the seized amount `alpha` does not exceed the
// total, and that the post-seizure state is written under the protocol's own
// canonical derivations -- so the holder's ordinary wallet recovery keeps
// working afterwards, with no out-of-band handoff.
//
// Upstream's COMPLIANCE.md Section 5 sketches this flow but leaves the
// treatment of the spendable blinding `r_s` explicitly open. Test A
// (`experiments/clawback-poc`) verified the premise that closes it: with the
// escrowed viewing key `vk` and public event nonces, the auditor recovers
// every witness this circuit takes. This circuit is the enforcement half.
//
// Intended contract flow (design, not implemented): freeze target ->
// auditor builds this proof off-chain -> contract verifies with
// (PVK_A, C_spend, C_receive) read from the frozen account record, `alpha`
// and `sigma_new` chosen by the seize authority -> contract sets
// C_spend := C_spend_new, zeroes C_receive, transfers `alpha` of the
// underlying SEP-41 to the issuer, emits (b_tilde_new, sigma_new).
// The freeze is what pins the account state between proof construction and
// submission (upstream's own anti-replay argument).
//
// Constraints
// -----------
//   Z1  PVK_A       = vk * H                       Binds the witnessed vk to
//                                                  the TARGET account's
//                                                  on-chain viewing key: a
//                                                  proof cannot be built for
//                                                  one account and applied to
//                                                  another, and a wrong vk
//                                                  (Z5/Z7) would strand the
//                                                  holder after seizure.
//   Z2  C_spend     = v_s * G + r_s * H            Opening of the spendable
//                                                  commitment. Pedersen
//                                                  binding => the witnessed
//                                                  v_s IS the balance.
//   Z3  C_receive   = v_r * G + r_r * H            Opening of the receiving
//                                                  commitment (transfers via
//                                                  the auditor channel;
//                                                  deposits have zero
//                                                  blinding -- see Test A).
//   Z4  v_s, v_r, alpha, remaining in [0, 2^127)   Range validity in the
//                                                  family's idiom; the bound
//                                                  is SEP-41's non-negative
//                                                  i128 range. `remaining`
//                                                  in-range enforces
//                                                  alpha <= v_s + v_r.
//   Z5  r_new       = derive_spend_r(vk, sigma_new)  Canonical post-seizure
//                                                  blinding (W5/T10/S9/V6
//                                                  rule) -- what the wallet
//                                                  itself would derive.
//   Z6  C_spend_new = remaining * G + r_new * H    Post-seizure spendable
//                                                  commitment.
//   Z7  b_tilde_new = encrypt_balance(remaining,   Post-seizure checkpoint,
//                       vk, sigma_new)             decryptable by the holder
//                                                  (and auditor) with vk.
//
// Public inputs (10 fields, in order)
// -----------------------------------
//   Idx  Param            Source at verification time
//   ---  -----            ---------------------------------------------
//   0-1  pvk_a_x/y        target's `viewing_public_key` (account record)
//   2-3  c_spend_x/y      target's `spendable_balance` (account record)
//   4-5  c_receive_x/y    target's `receiving_balance` (account record)
//   6    alpha            seize authority's amount (the point: it is PUBLIC)
//   7    sigma_new        seize-event nonce, chosen by the contract/authority
//   8-9  c_spend_new_x/y  prover-supplied new commitment, checked by Z6
//   10   b_tilde_new      prover-supplied new checkpoint, checked by Z7
//
// Private witnesses: vk, v_s, r_s, v_r, r_r -- all auditor-recoverable
// (Test A) from the vk escrow plus public events.
//
// NOT PRODUCTION READY: research artifact on unaudited developer-preview
// primitives. Testnet only.
fn main(
    // Private witnesses.
    vk: Field,
    v_s: Field,
    r_s: Field,
    v_r: Field,
    r_r: Field,
    // Public inputs.
    pvk_a_x: pub Field,
    pvk_a_y: pub Field,
    c_spend_x: pub Field,
    c_spend_y: pub Field,
    c_receive_x: pub Field,
    c_receive_y: pub Field,
    alpha: pub Field,
    sigma_new: pub Field,
    c_spend_new_x: pub Field,
    c_spend_new_y: pub Field,
    b_tilde_new: pub Field,
) {
    // Z1
    let pvk_derived = scalar_mul(vk, H);
    assert(pvk_derived.x == pvk_a_x);
    assert(pvk_derived.y == pvk_a_y);

    // Z2
    let c_spend_derived = commit(v_s, r_s);
    assert(c_spend_derived.x == c_spend_x);
    assert(c_spend_derived.y == c_spend_y);

    // Z3
    let c_receive_derived = commit(v_r, r_r);
    assert(c_receive_derived.x == c_receive_x);
    assert(c_receive_derived.y == c_receive_y);

    // Z4 -- ranges first, then the bound as a non-negative difference.
    v_s.assert_max_bit_size::<127>();
    v_r.assert_max_bit_size::<127>();
    alpha.assert_max_bit_size::<127>();
    let remaining = v_s + v_r - alpha;
    remaining.assert_max_bit_size::<127>();

    // Z5
    let r_new = derive_spend_r(vk, sigma_new);

    // Z6
    let c_new_derived = commit(remaining, r_new);
    assert(c_new_derived.x == c_spend_new_x);
    assert(c_new_derived.y == c_spend_new_y);

    // Z7
    let b_new_derived = encrypt_balance(remaining, vk, sigma_new);
    assert(b_new_derived == b_tilde_new);
}
