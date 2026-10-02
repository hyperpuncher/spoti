package ap

import "core:encoding/hex"
import "core:slice"
import "core:testing"

@(test)
modular_dh_matches_independent_vector :: proc(t: ^testing.T) {
	alice: [DH_PRIVATE_SIZE]u8
	alice[0], alice[1] = 2, 1 // private exponent 258 (little endian)
	bob: [DH_PRIVATE_SIZE]u8
	bob[0], bob[1] = 3, 1 // private exponent 259
	alice_public, ok := public_key(alice[:])
	defer delete(alice_public)
	testing.expect(t, ok)
	bob_public, bob_ok := public_key(bob[:])
	defer delete(bob_public)
	testing.expect(t, bob_ok)
	alice_secret, alice_secret_ok := shared_secret(alice[:], bob_public)
	defer delete(alice_secret)
	testing.expect(t, alice_secret_ok)
	bob_secret, bob_secret_ok := shared_secret(bob[:], alice_public)
	defer delete(bob_secret)
	testing.expect(t, bob_secret_ok && slice.equal(alice_secret, bob_secret))

	// Expected modular exponentiation from independent JavaScript BigInt.
	public_hex: string = "040000000000000000000000000000000000000000000000000000000000000000"
	secret_hex: string = "a541ed6b273ead663d5bac35c4e34bd07e7ab98e33dabbf11fb443ae02ae595a147d90b65beef0f1fc4264a43dc2716569b0e092d9c05627400099e7493863838a5a7e70ee22527a425db024c8a2e86684241844d353bccba84da2bd1eadbf67"
	want_public, _ := hex.decode(transmute([]u8)public_hex)
	defer delete(want_public)
	want_secret, _ := hex.decode(transmute([]u8)secret_hex)
	defer delete(want_secret)
	testing.expect(t, slice.equal(alice_public, want_public))
	testing.expect(t, slice.equal(alice_secret, want_secret))
}

@(test)
dh_rejects_invalid_peer_keys :: proc(t: ^testing.T) {
	private: [DH_PRIVATE_SIZE]u8
	private[0] = 2
	_, ok := shared_secret(private[:], []u8{0})
	testing.expect(t, !ok)
	_, ok = shared_secret(private[:], []u8{1})
	testing.expect(t, !ok)
	large: [96]u8
	for &byte in large[:] {byte = 0xff}
	_, ok = shared_secret(private[:], large[:])
	testing.expect(t, !ok)
	_, ok = shared_secret([]u8{1}, []u8{2})
	testing.expect(t, !ok)
	zero: [DH_PRIVATE_SIZE]u8
	_, ok = public_key(zero[:])
	testing.expect(t, !ok)
}
