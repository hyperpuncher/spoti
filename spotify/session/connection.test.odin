package session

import ap "../ap"
import "core:crypto"
import "core:fmt"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Real loopback TCP and Shannon packets; only the remote Spotify AP is replaced.
test_connection :: proc(t: ^testing.T) -> (AP_Connection, net.TCP_Socket, bool) {
	listener, err := net.listen_tcp({net.IP4_Loopback, 0})
	if !testing.expect(t, err == nil) {return {}, 0, false}
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if !testing.expect(t, endpoint_err == nil) {return {}, 0, false}
	client, dial_err := net.dial_tcp(endpoint)
	if !testing.expect(t, dial_err == nil) {return {}, 0, false}
	server, _, accept_err := net.accept_tcp(listener)
	if !testing.expect(t, accept_err == nil) {net.close(client); return {}, 0, false}
	_ = net.set_option(client, .Receive_Timeout, 20 * time.Millisecond)
	_ = net.set_option(server, .Receive_Timeout, time.Second)
	key: [32]u8 = 7
	return AP_Connection {
			socket = client,
			sender = ap.packet_cipher(key[:]),
			receiver = ap.packet_cipher(key[:]),
			connected = true,
			deadline = time.tick_add(time.tick_now(), 20 * time.Second),
		},
		server,
		true
}

test_send_packet :: proc(
	t: ^testing.T,
	socket: net.TCP_Socket,
	sender: ^ap.Packet_Cipher,
	command: u8,
	bytes: []u8,
) {
	wire := ap.seal_packet(sender, command, bytes)
	defer delete(wire)
	testing.expect(t, ap.send_full(socket, wire[:]))
}

test_audio_key_reply :: proc(
	t: ^testing.T,
	server: net.TCP_Socket,
	sender: ^ap.Packet_Cipher,
	sequence: int,
) {
	audio_key: [20]u8
	audio_key[3] = u8(sequence)
	for &byte in audio_key[4:] {byte = u8(sequence + 10)}
	test_send_packet(t, server, sender, 0x0d, audio_key[:])
}

@(test)
shared_ap_transport_requests_two_audio_keys_without_resetting_cipher_nonces :: proc(
	t: ^testing.T,
) {
	c, server, connected := test_connection(t)
	if !connected {return}
	defer close_connection(&c)
	defer net.close(server)
	key: [32]u8 = 7
	sender, receiver := ap.packet_cipher(key[:]), ap.packet_cipher(key[:])
	id: [16]u8 = 1
	file_id: [20]u8 = 2
	test_send_packet(t, server, &sender, 0x04, []u8{0, 0, 0, 0})
	for sequence in 0 ..< 2 {test_audio_key_reply(t, server, &sender, sequence)}
	for sequence in 0 ..< 2 {
		audio_key, ok := fetch_audio_key(&c, "", id, file_id, nil)
		if !testing.expect(t, ok) {return}
		testing.expect_value(t, audio_key[0], u8(sequence + 10))
		command, request, received := ap.read_packet(server, &receiver)
		defer delete(request)
		testing.expect(
			t,
			received && command == 0x0c && len(request) == 42 && request[39] == u8(sequence),
		)
	}
	testing.expect_value(t, c.sequence, u32(2))
	testing.expect_value(t, c.sender.nonce, u32(2))
	testing.expect_value(t, c.receiver.nonce, u32(3))
	testing.expect(t, c.connected && !c.broken)
}

@(test)
idle_ap_connection_handles_ping_pong_ack_and_dropped_connections :: proc(t: ^testing.T) {
	c, server, connected := test_connection(t)
	if !connected {return}
	defer close_connection(&c)
	defer net.close(server)
	key: [32]u8 = 7
	sender, receiver := ap.packet_cipher(key[:]), ap.packet_cipher(key[:])
	test_send_packet(t, server, &sender, 0x04, []u8{0, 0, 0, 0})
	for _ in 0 ..< 100 {
		poll_connection(&c, nil)
		if c.keep_alive == .Pong {break}
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, c.keep_alive, Keep_Alive.Pong)
	c.deadline = time.tick_add(time.tick_now(), -time.Second)
	poll_connection(&c, nil)
	command, payload, received := ap.read_packet(server, &receiver)
	defer delete(payload)
	testing.expect(t, received && command == 0x49 && len(payload) == 4)
	testing.expect_value(t, c.keep_alive, Keep_Alive.Ack)
	test_send_packet(t, server, &sender, 0x4a, nil)
	for _ in 0 ..< 100 {
		poll_connection(&c, nil)
		if c.keep_alive == .Ping {break}
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, c.keep_alive, Keep_Alive.Ping)
	_ = net.shutdown(server, .Both)
	for _ in 0 ..< 100 {
		poll_connection(&c, nil)
		if !c.connected {break}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, !c.connected, "a dropped idle connection must be cleared for reconnection")
	close_connection(&c)
}

@(test)
ap_packet_reads_resume_after_timeout_and_cancel_mid_packet :: proc(t: ^testing.T) {
	for cancel_read in ([]bool{false, true}) {
		c, server, connected := test_connection(t)
		if !connected {return}
		defer close_connection(&c)
		defer net.close(server)
		key: [32]u8 = 7
		sender := ap.packet_cipher(key[:])
		wire := ap.seal_packet(&sender, 0x04, []u8{1, 2, 3, 4})
		defer delete(wire)
		if !testing.expect(t, ap.send_full(server, wire[:1])) {return}
		Work :: struct {
			socket:      net.TCP_Socket,
			bytes:       []u8,
			cancel:      bool,
			cancel_read: bool,
		}
		work := Work {
			socket      = server,
			bytes       = wire[1:],
			cancel_read = cancel_read,
		}
		worker := thread.create_and_start_with_data(&work, proc(pointer: rawptr) {
			work := (^Work)(pointer)
			time.sleep(100 * time.Millisecond)
			if work.cancel_read {sync.atomic_store(&work.cancel, true)} else {_ = ap.send_full(work.socket, work.bytes)}
		})
		if !testing.expect(t, worker != nil) {return}
		defer {thread.join(worker); thread.destroy(worker)}
		command, payload, received := ap.read_packet(c.socket, &c.receiver, &work.cancel)
		defer {crypto.zero_explicit(raw_data(payload), len(payload)); delete(payload)}
		if cancel_read {
			testing.expect(t, !received && len(payload) == 0)
		} else {
			testing.expect(t, received && command == 0x04 && len(payload) == 4 && payload[3] == 4)
		}
	}
}

@(test)
broken_or_unauthenticated_packets_reconnect_once_and_retry_the_track :: proc(t: ^testing.T) {
	for bad_mac in ([]bool{false, true}) {
		c, old_server, connected := test_connection(t)
		if !connected {return}
		defer close_connection(&c)
		defer net.close(old_server)
		if bad_mac {
			key: [32]u8 = 7
			sender := ap.packet_cipher(key[:])
			wire := ap.seal_packet(&sender, 0xb2, []u8{1, 2, 3})
			defer delete(wire)
			wire[len(wire) - 1] ~= 1
			testing.expect(t, ap.send_full(old_server, wire[:]))
		} else {_ = net.shutdown(old_server, .Both)}
		listener, err := net.listen_tcp({net.IP4_Loopback, 0})
		if !testing.expect(t, err == nil) {return}
		defer net.close(listener)
		_ = net.set_option(listener, .Receive_Timeout, time.Second)
		endpoint, endpoint_err := net.bound_endpoint(listener)
		if !testing.expect(t, endpoint_err == nil) {return}
		address := fmt.aprintf("127.0.0.1:%d", endpoint.port)
		defer delete(address)
		Work :: struct {
			listener: net.TCP_Socket,
			t:        ^testing.T,
			accepted: bool,
		}
		work := Work {
			listener = listener,
			t        = t,
		}
		worker := thread.create_and_start_with_data(&work, proc(pointer: rawptr) {
			work := (^Work)(pointer)
			server, _, err := net.accept_tcp(work.listener)
			if err != nil {return}
			defer net.close(server)
			_ = net.set_option(server, .Receive_Timeout, time.Second)
			work.accepted = true
			key: [32]u8 = 7
			sender, receiver := ap.packet_cipher(key[:]), ap.packet_cipher(key[:])
			test_audio_key_reply(work.t, server, &sender, 0)
			_, bytes, received := ap.read_packet(server, &receiver)
			defer delete(bytes)
			_ = received
		})
		if !testing.expect(t, worker != nil) {return}
		defer {thread.join(worker); thread.destroy(worker)}
		id: [16]u8 = 1
		file_id: [20]u8 = 2
		audio_key, ok := fetch_audio_key(
			&c,
			address,
			id,
			file_id,
			nil,
			proc(c: ^AP_Connection, address: string, cancel: ^bool) -> bool {
				if cancelled(cancel) {return false}
				socket, err := net.dial_tcp(address)
				if err != nil {return false}
				_ = net.set_option(socket, .Receive_Timeout, 20 * time.Millisecond)
				key: [32]u8 = 7
				c^ = AP_Connection {
					socket    = socket,
					sender    = ap.packet_cipher(key[:]),
					receiver  = ap.packet_cipher(key[:]),
					connected = true,
					deadline  = time.tick_add(time.tick_now(), 20 * time.Second),
				}
				return true
			},
		)
		testing.expect(t, ok && audio_key[0] == 10)
		testing.expect(t, c.connected && c.sequence == 1)
	}
}

@(test)
missing_ping_or_pong_ack_expires_the_transport :: proc(t: ^testing.T) {
	for state in ([]Keep_Alive{.Ping, .Ack}) {
		c, server, connected := test_connection(t)
		if !connected {return}
		defer close_connection(&c)
		defer net.close(server)
		c.keep_alive = state
		c.deadline = time.tick_add(time.tick_now(), -time.Second)
		poll_connection(&c, nil)
		testing.expect(t, !c.connected)
	}
}
