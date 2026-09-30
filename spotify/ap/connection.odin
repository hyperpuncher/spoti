package ap

import "core:crypto"
import "core:net"
import "core:sync"
import "core:time"

Handshake_Error :: enum {
	None,
	Transport,
	Bad_Frame,
	Rejected,
	Bad_Signature,
	Invalid_Key,
}

read_full :: proc(socket: net.TCP_Socket, data: []u8, cancel: ^bool = nil) -> bool {
	read := 0
	started := time.tick_now()
	for read < len(data) {
		if (cancel != nil && sync.atomic_load(cancel)) ||
		   time.tick_since(started) >= 8 * time.Second {return false}
		n, err := net.recv_tcp(socket, data[read:])
		if err == .Timeout || err == .Would_Block || err == .Interrupted {continue}
		if err != nil || n == 0 {return false}
		read += n
	}
	return true
}

send_full :: proc(socket: net.TCP_Socket, data: []u8) -> bool {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(socket, data[sent:])
		if err != nil || n == 0 {return false}
		sent += n
	}
	return true
}

// Perform the credential-free AP handshake on a connected socket. Verify the
// signature before computing any shared key, and wipe ephemeral secrets.
handshake :: proc(socket: net.TCP_Socket, cancel: ^bool = nil) -> (Session_Keys, Handshake_Error) {
	private := new_private_key()
	defer crypto.zero_explicit(&private, size_of(private))
	public, ok := public_key(private[:])
	if !ok {return {}, .Invalid_Key}
	defer delete(public)
	nonce: [16]u8
	crypto.rand_bytes(nonce[:])
	defer crypto.zero_explicit(&nonce, size_of(nonce))

	message := client_hello(public, nonce[:], 8, 124200290) // Linux x86-64
	defer delete(message)
	hello := frame_plaintext(message[:], true)
	defer delete(hello)
	if hello == nil {return {}, .Bad_Frame}
	if !send_full(socket, hello[:]) {return {}, .Transport}

	header: [4]u8
	if !read_full(socket, header[:], cancel) {return {}, .Transport}
	size := u32(header[0]) << 24 | u32(header[1]) << 16 | u32(header[2]) << 8 | u32(header[3])
	if size < 4 || size > MAX_FRAME_SIZE {return {}, .Bad_Frame}
	reply := make([]u8, int(size))
	defer delete(reply)
	copy(reply[:4], header[:])
	if !read_full(socket, reply[4:], cancel) {return {}, .Transport}
	payload, _, status := parse_plaintext(reply, false)
	if status != .Complete {return {}, .Bad_Frame}
	challenge, kind := parse_response(payload)
	if kind != .Challenge {return {}, .Rejected}
	if !verify_server_signature(challenge) {return {}, .Bad_Signature}

	secret, shared := shared_secret(private[:], challenge.public_key)
	if !shared {return {}, .Invalid_Key}
	defer {
		crypto.zero_explicit(raw_data(secret), len(secret))
		delete(secret)
	}
	transcript := make([dynamic]u8)
	defer delete(transcript)
	append(&transcript, ..hello[:])
	append(&transcript, ..reply)
	keys, derived := derive_keys(secret, transcript[:])
	if !derived {return {}, .Invalid_Key}
	response := client_response(keys.challenge[:])
	defer delete(response)
	frame := frame_plaintext(response[:], false)
	defer delete(frame)
	if frame == nil || !send_full(socket, frame[:]) {
		crypto.zero_explicit(&keys, size_of(keys))
		return {}, .Transport
	}
	return keys, .None
}

// Authenticated packet reader. Never return a command or payload unless its
// Shannon MAC verifies. Callers must delete the returned allocation.
read_packet :: proc(
	socket: net.TCP_Socket,
	cipher: ^Packet_Cipher,
	cancel: ^bool = nil,
) -> (
	command: u8,
	payload: []u8,
	ok: bool,
) {
	header: [3]u8
	if !read_full(socket, header[:], cancel) {return 0, nil, false}
	cmd, length, valid := open_header(cipher, header)
	if !valid {return 0, nil, false}
	body := make([]u8, length + 4)
	if !read_full(socket, body, cancel) {delete(body); return 0, nil, false}
	if !open_payload(cipher, body[:length], body[length:]) {
		crypto.zero_explicit(raw_data(body), len(body))
		delete(body)
		return 0, nil, false
	}
	// Copy the plaintext to a right-sized allocation (body also held the MAC).
	plaintext := make([]u8, length)
	copy(plaintext, body[:length])
	crypto.zero_explicit(raw_data(body), len(body))
	delete(body)
	return cmd, plaintext, true
}
