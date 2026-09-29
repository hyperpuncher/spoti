// Odin port of Paul Lietar's MIT-licensed shannon 0.2 cipher.
// Source: https://crates.io/crates/shannon/0.2.0 ; see LICENSE.
package shannon

N :: 16
KEYP :: 13
INITKONST :: u32(0x6996c53a)

Cipher :: struct {
	r:          [N]u32,
	crc:        [N]u32,
	initial:    [N]u32,
	konst:      u32,
	stream:     u32,
	mac_buffer: u32,
	bits_left:  int,
}

rotate :: proc(w: u32, n: u32) -> u32 {return w << n | w >> (32 - n)}

sbox1 :: proc(input: u32) -> u32 {
	w := input
	w ~= rotate(w, 5) | rotate(w, 7)
	w ~= rotate(w, 19) | rotate(w, 22)
	return w
}

sbox2 :: proc(input: u32) -> u32 {
	w := input
	w ~= rotate(w, 7) | rotate(w, 22)
	w ~= rotate(w, 5) | rotate(w, 19)
	return w
}

cycle :: proc(c: ^Cipher) {
	t := sbox1(c.r[12] ~ c.r[13] ~ c.konst) ~ rotate(c.r[0], 1)
	for i in 1 ..< N {c.r[i - 1] = c.r[i]}
	c.r[N - 1] = t
	t = sbox2(c.r[2] ~ c.r[15])
	c.r[0] ~= t
	c.stream = t ~ c.r[8] ~ c.r[12]
}

diffuse :: proc(c: ^Cipher) {for _ in 0 ..< N {cycle(c)}}

load_key :: proc(c: ^Cipher, key: []u8) {
	for at := 0; at < len(key); at += 4 {
		word: u32
		for i := 0; i < 4 && at + i < len(key); i += 1 {
			word |= u32(key[at + i]) << u32(8 * i)
		}
		c.r[KEYP] ~= word
		cycle(c)
	}
	c.r[KEYP] ~= u32(len(key))
	cycle(c)
	c.crc = c.r
	diffuse(c)
	for i in 0 ..< N {c.r[i] ~= c.crc[i]}
}

new :: proc(key: []u8) -> Cipher {
	c: Cipher
	c.konst = INITKONST
	c.r[0], c.r[1] = 1, 1
	for i in 2 ..< N {c.r[i] = c.r[i - 1] + c.r[i - 2]}
	load_key(&c, key)
	c.konst = c.r[0]
	c.initial = c.r
	return c
}

nonce :: proc(c: ^Cipher, value: u32) {
	c.r = c.initial
	c.konst = INITKONST
	bytes := [4]u8{u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value)}
	load_key(c, bytes[:])
	c.konst = c.r[0]
	c.bits_left = 0
}

crc_word :: proc(c: ^Cipher, word: u32) {
	t := c.crc[0] ~ c.crc[2] ~ c.crc[15] ~ word
	for i in 1 ..< N {c.crc[i - 1] = c.crc[i]}
	c.crc[N - 1] = t
}

mac_word :: proc(c: ^Cipher, word: u32) {
	crc_word(c, word)
	c.r[KEYP] ~= word
}

process_partial :: proc(c: ^Cipher, b: ^u8, decrypt: bool) {
	shift := u32(32 - c.bits_left)
	mask := u8(c.stream >> shift)
	if decrypt {
		b^ ~= mask
		c.mac_buffer ~= u32(b^) << shift
	} else {
		c.mac_buffer ~= u32(b^) << shift
		b^ ~= mask
	}
}

process :: proc(c: ^Cipher, data: []u8, decrypt: bool) {
	at := 0
	if c.bits_left != 0 {
		for c.bits_left > 0 {
			if at >= len(data) {return}
			process_partial(c, &data[at], decrypt)
			at += 1
			c.bits_left -= 8
			mac_word(c, c.mac_buffer)
		}
	}
	for at + 4 <= len(data) {
		cycle(c)
		word :=
			u32(data[at]) |
			u32(data[at + 1]) << 8 |
			u32(data[at + 2]) << 16 |
			u32(data[at + 3]) << 24
		if decrypt {
			word ~= c.stream
			mac_word(c, word)
		} else {
			mac_word(c, word)
			word ~= c.stream
		}
		for i in 0 ..< 4 {data[at + i] = u8(word >> u32(8 * i))}
		at += 4
	}
	if at < len(data) {
		cycle(c)
		c.mac_buffer = 0
		c.bits_left = 32
		for at < len(data) {
			process_partial(c, &data[at], decrypt)
			at += 1
			c.bits_left -= 8
		}
	}
}

encrypt :: proc(c: ^Cipher, data: []u8) {process(c, data, false)}
decrypt :: proc(c: ^Cipher, data: []u8) {process(c, data, true)}

finish :: proc(c: ^Cipher) -> [4]u8 {
	if c.bits_left != 0 {mac_word(c, c.mac_buffer)}
	cycle(c)
	c.r[KEYP] ~= INITKONST ~ (u32(c.bits_left) << 3)
	c.bits_left = 0
	for i in 0 ..< N {c.r[i] ~= c.crc[i]}
	diffuse(c)
	cycle(c)
	return {u8(c.stream), u8(c.stream >> 8), u8(c.stream >> 16), u8(c.stream >> 24)}
}
