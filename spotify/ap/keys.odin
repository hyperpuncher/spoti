package ap

import "core:crypto"
import "core:crypto/hmac"

Session_Keys :: struct {
	challenge: [20]u8,
	send:      [32]u8,
	receive:   [32]u8,
}

// transcript is the exact wire bytes of ClientHello followed by APResponse,
// including both framing lengths. Only call after authenticating the AP's
// signature and computing the DH shared secret.
derive_keys :: proc(shared_secret, transcript: []u8) -> (keys: Session_Keys, ok: bool) {
	if len(shared_secret) == 0 || len(transcript) == 0 {return {}, false}
	material: [100]u8
	defer crypto.zero_explicit(&material, size_of(material))
	for i in 0 ..< 5 {
		mac: hmac.Context
		hmac.init(&mac, .Insecure_SHA1, shared_secret)
		hmac.update(&mac, transcript)
		hmac.update(&mac, []u8{u8(i + 1)})
		hmac.final(&mac, material[i * 20:(i + 1) * 20])
	}
	mac: hmac.Context
	hmac.init(&mac, .Insecure_SHA1, material[:20])
	hmac.update(&mac, transcript)
	hmac.final(&mac, keys.challenge[:])
	copy(keys.send[:], material[20:52])
	copy(keys.receive[:], material[52:84])
	return keys, true
}
