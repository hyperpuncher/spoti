package ap

import "core:crypto/rsa"
import "core:encoding/hex"

// Spotify's 2048-bit access-point signing key from librespot's
// core/src/connection/handshake.rs. A received DH key must pass this check
// before it is used to derive session keys.
SERVER_KEY_HEX ::
	"ace0460bffc230aff46bfec3bfbf863da191c6cc336c93a14fb3b01612acac6a" +
	"f180e7f614d9429dbe2e346643e362d2327a1a0d923baedd1402b18155056104" +
	"d52c96a44c1ecc024ad4b20c001f17edc22fc43521c8f0cbaed2add72b0f9db3" +
	"c5321a2afe59f35a0dac68f1fa621efb2c8d0cb7392d9247e3d7351a6dbd24c2" +
	"ae255b88ffab73298a0bcccd0c58673189e8bd3480784a5fc96b899d956bfc86" +
	"d74f33a6781796c9c32d0d32a5abcd0527e2f710a39613c42f99c027bfed049c" +
	"3c275804b6b219f9c12f02e94863eca1b642a09d4825f8b39dd0e86af9484da1" +
	"c2ba863042ea9db3086c190e48b39d66eb0006a25aeea11b13873cd719e655bd"

verify_server_signature :: proc(challenge: Challenge) -> bool {
	if len(challenge.public_key) == 0 || len(challenge.signature) != 256 {
		return false
	}
	key_text: string = SERVER_KEY_HEX
	modulus, ok := hex.decode(transmute([]u8)key_text)
	if !ok {return false}
	defer delete(modulus)
	public_key: rsa.Public_Key
	if !rsa.public_key_set_bytes(&public_key, modulus, []u8{1, 0, 1}) {
		return false
	}
	// The protocol uses PKCS#1 v1.5 with SHA-1. Do not replace with a
	// stronger hash here without a corresponding protocol change.
	return rsa.verify_pkcs1(&public_key, .Insecure_SHA1, challenge.public_key, challenge.signature)
}
