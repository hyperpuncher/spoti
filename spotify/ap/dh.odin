package ap

import "core:crypto"
import big "core:math/big"

// Same 768-bit group as librespot/core/src/diffie_hellman.rs (RFC 2409 group 1).
DH_PRIME_HEX ::
	"ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020" +
	"bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe" +
	"1356d6d51c245e485b576625e7ec6f44c42e9a63a3620ffffffffffffffff"

DH_PRIVATE_SIZE :: 95

new_private_key :: proc() -> [DH_PRIVATE_SIZE]u8 {
	private: [DH_PRIVATE_SIZE]u8
	crypto.rand_bytes(private[:])
	return private
}

// The secret exponent is interpreted as little-endian, matching librespot.
// Returned bytes are a minimally encoded, big-endian integer; caller owns them.
dh_power :: proc(private: []u8, peer_key: []u8) -> (result: []u8, ok: bool) {
	if len(private) != DH_PRIVATE_SIZE || len(peer_key) == 0 || len(peer_key) > 96 {
		return nil, false
	}
	prime, base, exponent, value, lower, upper :=
		big.Int{}, big.Int{}, big.Int{}, big.Int{}, big.Int{}, big.Int{}
	defer big.destroy(&prime, &base, &exponent, &value, &lower, &upper)
	if big.int_atoi(&prime, DH_PRIME_HEX, 16) != .None ||
	   big.int_from_bytes_big(&base, peer_key) != .None ||
	   big.int_from_bytes_little(&exponent, private) != .None ||
	   big.set(&lower, 1) != .None ||
	   big.sub(&upper, &prime, &lower) != .None {
		return nil, false
	}
	min_cmp, err := big.compare(&base, &lower)
	if err != .None || min_cmp <= 0 {return nil, false}
	private_cmp: int
	private_cmp, err = big.compare(&exponent, &lower)
	if err != .None || private_cmp <= 0 {return nil, false}
	max_cmp: int
	max_cmp, err = big.compare(&base, &upper)
	if err != .None || max_cmp >= 0 {return nil, false}
	// Odin's bigint modular exponentiation; no new math implementation.
	if big.internal_powmod(&value, &base, &exponent, &prime) != .None {
		return nil, false
	}
	size: int
	size, err = big.int_to_bytes_size(&value)
	if err != .None || size == 0 || size > 96 {return nil, false}
	result = make([]u8, size)
	if big.int_to_bytes_big(&value, result) != .None {
		delete(result)
		return nil, false
	}
	return result, true
}

public_key :: proc(private: []u8) -> (public: []u8, ok: bool) {
	return dh_power(private, []u8{2})
}

// Verify the AP signature before calling this with a received peer key.
shared_secret :: proc(private, server_public_key: []u8) -> (secret: []u8, ok: bool) {
	return dh_power(private, server_public_key)
}
