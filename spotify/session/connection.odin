package session

import ap "../ap"
import "base:runtime"
import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:net"
import "core:sync"
import linux "core:sys/linux"
import "core:thread"
import "core:time"

Keep_Alive :: enum {
	Ping,
	Pong,
	Ack,
}

// All socket I/O and cipher nonces are serialized by connection_mutex.
// No credentials are retained here. Reconnection uses the current grant.
AP_Connection :: struct {
	socket:            net.TCP_Socket,
	sender, receiver:  ap.Packet_Cipher,
	connected, broken: bool,
	sequence:          u32,
	keep_alive:        Keep_Alive,
	deadline:          time.Tick,
}
connection: AP_Connection
connection_mutex: sync.Mutex
connection_worker: ^thread.Thread
connection_stop: bool

cancelled :: proc(cancel: ^bool) -> bool {
	return cancel != nil && sync.atomic_load(cancel)
}

lock_connection :: proc(cancel: ^bool) -> bool {
	for !sync.try_lock(&connection_mutex) {
		if cancelled(cancel) {return false}
		time.sleep(10 * time.Millisecond)
	}
	if cancelled(cancel) {sync.unlock(&connection_mutex); return false}
	return true
}

close_connection :: proc(c: ^AP_Connection) {
	if c.connected {net.close(c.socket)}
	crypto.zero_explicit(c, size_of(c^))
}

clear_connection :: proc() {
	// Called only after the playback and library workers have joined.
	sync.atomic_store(&connection_stop, true)
	if connection_worker != nil {
		thread.join(connection_worker)
		thread.destroy(connection_worker)
		connection_worker = nil
	}
	sync.mutex_guard(&connection_mutex)
	close_connection(&connection)
}

send_connection_packet :: proc(c: ^AP_Connection, command: u8, payload: []u8) -> bool {
	wire := ap.seal_packet(&c.sender, command, payload)
	defer {crypto.zero_explicit(raw_data(wire), len(wire)); delete(wire)}
	if wire == nil || !ap.send_full(c.socket, wire[:]) {c.broken = true; return false}
	return true
}

// Spotify's ping cycle delays the pong by 60 seconds, then expects an ack.
service_keep_alive :: proc(c: ^AP_Connection) -> bool {
	if time.tick_diff(time.tick_now(), c.deadline) > 0 {return true}
	if c.keep_alive != .Pong {c.broken = true; return false}
	if !send_connection_packet(c, 0x49, []u8{0, 0, 0, 0}) {return false}
	c.keep_alive = .Ack
	c.deadline = time.tick_add(time.tick_now(), 20 * time.Second)
	return true
}

handle_keep_alive :: proc(c: ^AP_Connection, command: u8) -> bool {
	switch command {
	case 0x04:
		c.keep_alive = .Pong
		c.deadline = time.tick_add(time.tick_now(), 60 * time.Second)
		return true
	case 0x4a:
		if c.keep_alive == .Ack {
			c.keep_alive = .Ping
			c.deadline = time.tick_add(time.tick_now(), 80 * time.Second)
		}
		return true
	}
	return false
}

poll_connection :: proc(c: ^AP_Connection, stop: ^bool) {
	if !c.connected {return}
	if service_keep_alive(c) {
		fds := [1]linux.Poll_Fd{{fd = linux.Fd(c.socket), events = {.IN}}}
		ready, err := linux.poll(fds[:], 0)
		if err != .NONE {c.broken = true}
		if ready > 0 {
			command, payload, ok := ap.read_packet(c.socket, &c.receiver, stop)
			defer {crypto.zero_explicit(raw_data(payload), len(payload)); delete(payload)}
			if !ok {c.broken = true} else {_ = handle_keep_alive(c, command)}
		}
	}
	if c.broken {close_connection(c)}
}

connection_idle :: proc(_: rawptr) {
	for !cancelled(&connection_stop) {
		if sync.try_lock(&connection_mutex) {
			defer sync.unlock(&connection_mutex)
			poll_connection(&connection, &connection_stop)
		}
		time.sleep(100 * time.Millisecond)
	}
}

start_connection_worker :: proc() -> bool {
	if connection_worker != nil {return true}
	// This thread can outlive the allocator scope of the request that starts it.
	context = runtime.default_context()
	sync.atomic_store(&connection_stop, false)
	connection_worker = thread.create_and_start_with_data(nil, connection_idle)
	return connection_worker != nil
}

connect_connection :: proc(c: ^AP_Connection, access: string, cancel: ^bool) -> bool {
	socket, status := ap.connect(cancel)
	if status !=
	   .Connected {fmt.eprintln("could not connect to Spotify access point:", status); return false}
	ok := false
	defer if !ok {net.close(socket)}
	// Short reads resume up to the eight-second deadline, checking cancellation
	// between waits during handshake, login and subsequent requests.
	_ = net.set_option(socket, .Receive_Timeout, 200 * time.Millisecond)
	_ = net.set_option(socket, .Send_Timeout, 8 * time.Second)
	keys, err := ap.handshake(socket, cancel)
	if err != .None {fmt.eprintln("AP handshake failed:", err); return false}
	defer crypto.zero_explicit(&keys, size_of(keys))
	c.sender, c.receiver = ap.packet_cipher(keys.send[:]), ap.packet_cipher(keys.receive[:])
	defer if !ok {crypto.zero_explicit(c, size_of(c^))}
	device_bytes: [20]u8
	crypto.rand_bytes(device_bytes[:])
	device_id := hex.encode(device_bytes[:])
	crypto.zero_explicit(&device_bytes, size_of(device_bytes))
	defer delete(device_id)
	body := ap.client_login_token(access, string(device_id))
	defer {crypto.zero_explicit(raw_data(body), len(body)); delete(body)}
	c.socket = socket
	if cancelled(cancel) || !send_connection_packet(c, 0xab, body[:]) {return false}
	command, response, received := ap.read_packet(socket, &c.receiver, cancel)
	defer {crypto.zero_explicit(raw_data(response), len(response)); delete(response)}
	if !received {fmt.eprintln("AP login response missing or invalid MAC"); return false}
	_, failure, kind := ap.parse_login_reply(command, response)
	if kind != .Welcome {fmt.eprintln("AP login refused or invalid:", failure); return false}
	c.connected, c.broken = true, false
	c.keep_alive = .Ping
	c.deadline = time.tick_add(time.tick_now(), 20 * time.Second)
	ok = true
	fmt.println("Playback connection authenticated.")
	return true
}

read_connection_reply :: proc(c: ^AP_Connection, cancel: ^bool) -> (u8, []u8, bool) {
	for _ in 0 ..< 64 {
		if cancelled(cancel) || !service_keep_alive(c) {return 0, nil, false}
		command, payload, ok := ap.read_packet(c.socket, &c.receiver, cancel)
		if !ok {c.broken = true; return 0, nil, false}
		if !handle_keep_alive(c, command) {return command, payload, true}
		crypto.zero_explicit(raw_data(payload), len(payload))
		delete(payload)
	}
	c.broken = true
	return 0, nil, false
}
