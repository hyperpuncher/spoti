package audio

import "core:crypto"
import "core:crypto/aes"

// Spotify's AES-128-CTR audio IV from librespot/audio/src/decrypt.rs.
AUDIO_IV := [16]u8 {
	0x72,
	0xe0,
	0x67,
	0xfb,
	0xdd,
	0xcb,
	0xcf,
	0x77,
	0xeb,
	0xe8,
	0xbc,
	0x64,
	0x3f,
	0x63,
	0x0d,
	0x93,
}

Decryptor :: struct {
	cipher: aes.Context_CTR,
}

init :: proc(key: [16]u8, offset: int = 0) -> Decryptor {
	assert(offset >= 0)
	iv := AUDIO_IV
	carry := u64(offset / 16)
	for i := 15; i >= 0; i -= 1 {
		carry += u64(iv[i])
		iv[i] = u8(carry & 255)
		carry >>= 8
	}
	result: Decryptor
	copy_key := key
	defer crypto.zero_explicit(&copy_key, size_of(copy_key))
	aes.init_ctr(&result.cipher, copy_key[:], iv[:])
	padding: [16]u8
	aes.xor_bytes_ctr(&result.cipher, padding[:offset % 16], padding[:offset % 16])
	crypto.zero_explicit(&padding, size_of(padding))
	return result
}

// Apply to consecutive byte ranges in order. Never rewind or skip bytes
// without resetting/repositioning the AES counter first.
process :: proc(decryptor: ^Decryptor, bytes: []u8) {
	aes.xor_bytes_ctr(&decryptor.cipher, bytes, bytes)
}

reset :: proc(decryptor: ^Decryptor) {
	aes.reset_ctr(&decryptor.cipher)
}
