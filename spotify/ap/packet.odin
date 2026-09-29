package ap

import shannon "../shannon"
import "core:crypto"

// Both directions start at nonce zero with independent Shannon keys.
Packet_Cipher :: struct {
	cipher: shannon.Cipher,
	nonce:  u32,
}

packet_cipher :: proc(key: []u8) -> Packet_Cipher {
	return {cipher = shannon.new(key)}
}

// Encrypted AP packets use [command:1, payload_length:2 BE, payload, MAC:4].
seal_packet :: proc(sender: ^Packet_Cipher, command: u8, payload: []u8) -> [dynamic]u8 {
	if len(payload) > 65535 || sender.nonce == max(u32) {return nil}
	packet := make([dynamic]u8, 0, 3 + len(payload) + 4)
	append(&packet, command, u8(len(payload) >> 8), u8(len(payload)))
	append(&packet, ..payload)
	shannon.nonce(&sender.cipher, sender.nonce)
	shannon.encrypt(&sender.cipher, packet[:])
	mac := shannon.finish(&sender.cipher)
	append(&packet, ..mac[:])
	sender.nonce += 1
	return packet
}

// For a TCP stream: read and decrypt exactly three bytes, then read size + 4
// more bytes. Never trust the payload before open_payload verifies its MAC.
open_header :: proc(
	receiver: ^Packet_Cipher,
	encrypted_header: [3]u8,
) -> (
	command: u8,
	size: int,
	ok: bool,
) {
	if receiver.nonce == max(u32) {return 0, 0, false}
	header := encrypted_header
	shannon.nonce(&receiver.cipher, receiver.nonce)
	shannon.decrypt(&receiver.cipher, header[:])
	return header[0], int(header[1]) << 8 | int(header[2]), true
}

open_payload :: proc(receiver: ^Packet_Cipher, encrypted_payload: []u8, mac: []u8) -> bool {
	if len(mac) != 4 {return false}
	shannon.decrypt(&receiver.cipher, encrypted_payload)
	actual := shannon.finish(&receiver.cipher)
	receiver.nonce += 1
	if crypto.compare_constant_time(actual[:], mac) != 1 {
		crypto.zero_explicit(raw_data(encrypted_payload), len(encrypted_payload))
		return false
	}
	return true
}
