// One worker owns the Dealer socket, streaming grant and Connect HTTP
// state updates. The UI exchanges bounded messages, never network calls.
package connect

import diagnostic "../../diagnostic"
import ap "../ap"
import http "../http"
import oauth "../oauth"
import session "../session"
import "base:runtime"
import "core:bytes"
import gzip "core:compress/gzip"
import "core:crypto"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:time"

Client :: struct {
	worker:    ^thread.Thread,
	wake:      proc "c" (_: rawptr),
	cancel:    bool,
	ready:     bool, // atomic; registration succeeded
	pending:   bool, // atomic; wake the UI to drain events
	device_id: string,
	events:    chan.Chan(Event),
	replies:   chan.Chan(Reply),
	states:    chan.Chan(Snapshot),
}

Reply :: struct {
	key:      string,
	accepted: bool,
}

valid_id :: proc(id: string) -> bool {
	if len(id) != 40 {return false}
	for ch in id {if !(ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'f') {return false}}
	return true
}

new_id :: proc() -> string {
	bytes: [20]u8
	crypto.rand_bytes(bytes[:])
	return string(hex.encode(bytes[:]))
}

start :: proc(client: ^Client, device_id: string, wake: proc "c" (_: rawptr) = nil) -> (ok: bool) {
	if client.worker != nil {return true}
	if !valid_id(device_id) {return false}
	client.device_id = strings.clone(device_id)
	client.wake = wake
	defer if !ok {stop(client)}
	allocation: runtime.Allocator_Error
	client.events, allocation = chan.create_buffered(chan.Chan(Event), 8, context.allocator)
	if allocation != nil {return false}
	client.replies, allocation = chan.create_buffered(chan.Chan(Reply), 8, context.allocator)
	if allocation != nil {return false}
	client.states, allocation = chan.create_buffered(chan.Chan(Snapshot), 2, context.allocator)
	if allocation != nil {return false}
	client.worker = thread.create_and_start_with_data(client, run)
	return client.worker != nil
}

stop :: proc(client: ^Client) {
	if client.device_id == "" {return}
	sync.atomic_store(&client.cancel, true)
	chan.close(client.events)
	chan.close(client.replies)
	chan.close(client.states)
	if client.worker != nil {thread.join(client.worker); thread.destroy(client.worker)}
	for event in chan.try_recv(client.events) {free_event(event)}
	for reply in chan.try_recv(client.replies) {delete(reply.key)}
	for state in chan.try_recv(client.states) {
		owned := state
		free_snapshot(&owned)
	}
	chan.destroy(client.events)
	chan.destroy(client.replies)
	chan.destroy(client.states)
	delete(client.device_id)
	client^ = {}
}

notify :: proc(client: ^Client) {
	sync.atomic_store(&client.pending, true)
	if client.wake != nil {client.wake(nil)}
}

take_event :: proc(client: ^Client) -> (event: Event, received: bool) {
	if client.worker == nil {return}
	return chan.try_recv(client.events)
}

publish :: proc(client: ^Client, snapshot: Snapshot) -> bool {
	if client.worker == nil {return false}
	owned := snapshot
	owned.uri = strings.clone(snapshot.uri)
	owned.context_uri = strings.clone(snapshot.context_uri)
	owned.tracks = make([dynamic]string, 0, len(snapshot.tracks))
	for uri in snapshot.tracks {append(&owned.tracks, strings.clone(uri))}
	if !chan.try_send(client.states, owned) {free_snapshot(&owned); return false}
	return true
}

acknowledge :: proc(client: ^Client, event: Event, accepted: bool) {
	if event.key == "" {return}
	diagnostic.writef("connect request action=%v accepted=%v", event.action, accepted)
	reply := Reply{strings.clone(event.key), accepted}
	if !chan.try_send(client.replies, reply) {delete(reply.key)}
}

Envelope :: struct {
	type:          string,
	uri:           string,
	message_ident: string,
	key:           string,
	headers:       map[string]string,
	payload:       struct {
		compressed: string,
	},
	payloads:      []string,
}

resolve_dealer :: proc(cancel: ^bool) -> string {
	body, code, ok := http.get(
		"https://apresolve.spotify.com/?type=dealer",
		{cancel = cancel, limit = 16384},
	)
	defer delete(body)
	if !ok || code != 200 {return ""}
	response: struct {
		dealer: []string,
	}
	if json.unmarshal(body[:], &response, allocator = context.temp_allocator) != nil {return ""}
	for address in response.dealer {
		target, error := net.parse_hostname_or_endpoint(address)
		if error != nil {continue}
		if host, valid := target.(net.Host);
		   valid && strings.has_suffix(host.hostname, ".spotify.com") && host.port == 443 {
			return strings.clone(address)
		}
	}
	return ""
}

put_state :: proc(
	client: ^Client,
	access, connection_id, session_id: string,
	snapshot: Snapshot,
	reason: u64,
	sender: string,
	message: u32,
	reuse: rawptr,
) -> bool {
	body := encode_state(client.device_id, session_id, snapshot, reason, sender, message)
	defer delete(body)
	address := fmt.aprintf(
		"https://spclient.wg.spotify.com/connect-state/v1/devices/%s",
		client.device_id,
		allocator = context.temp_allocator,
	)
	response, code, ok := http.put_protobuf(
		address,
		body[:],
		{
			bearer = access,
			connection_id = connection_id,
			cancel = &client.cancel,
			limit = 1024 * 1024,
		},
		reuse,
	)
	defer delete(response)
	diagnostic.writef(
		"connect state reason=%d status=%d ok=%v shuffle=%v command=%v sender=%v",
		reason,
		code,
		ok,
		snapshot.shuffle,
		message != 0,
		sender != "",
	)
	return ok && code >= 200 && code < 300
}

dealer_payload :: proc(encoded: string) -> (data: []u8, compressed, ok: bool) {
	decoded, error := base64.decode(encoded, allocator = context.temp_allocator)
	if error != nil || len(decoded) == 0 {return}
	if len(decoded) < 2 || decoded[0] != 0x1f || decoded[1] != 0x8b {
		return decoded, false, true
	}
	compressed = true
	// Gzip stores its uncompressed size in the final little-endian word.
	if len(decoded) < 18 {return nil, true, false}
	last := len(decoded) - 4
	size :=
		u64(decoded[last]) |
		u64(decoded[last + 1]) << 8 |
		u64(decoded[last + 2]) << 16 |
		u64(decoded[last + 3]) << 24
	if size > http.WS_LIMIT {return nil, true, false}
	buffer: bytes.Buffer
	if gzip.load(
		   data = decoded,
		   buf = &buffer,
		   known_gzip_size = len(decoded),
		   allocator = context.temp_allocator,
	   ) !=
	   nil {return nil, true, false}
	data = bytes.buffer_to_bytes(&buffer)
	return data, true, len(data) <= http.WS_LIMIT
}

reply_to_dealer :: proc(client: ^Client, socket: ^http.WebSocket, reply: Reply) -> bool {
	defer delete(reply.key)
	body, error := json.marshal(struct {
			type:    string,
			key:     string,
			payload: struct {
				success: bool,
			},
		}{"reply", reply.key, {reply.accepted}}, allocator = context.temp_allocator)
	return error == nil && http.ws_write(socket, body, &client.cancel)
}

run_connection :: proc(client: ^Client, tokens: oauth.Tokens, snapshot: ^Snapshot, reuse: rawptr) {
	access := tokens.access
	host := resolve_dealer(&client.cancel)
	defer delete(host)
	if host == "" {return}
	encoded := net.percent_encode(access, context.temp_allocator)
	address := fmt.aprintf(
		"wss://%s/?access_token=%s",
		host,
		encoded,
		allocator = context.temp_allocator,
	)
	socket, connected := http.ws_open(address, &client.cancel)
	if !connected {diagnostic.write("connect Dealer connection failed"); return}
	defer http.ws_close(&socket)
	defer sync.atomic_store(&client.ready, false)
	connection_id := ""
	defer delete(connection_id)
	defer if connection_id != "" && sync.atomic_load(&client.cancel) {
		cleanup_address := fmt.aprintf(
			"https://spclient.wg.spotify.com/connect-state/v1/devices/%s",
			client.device_id,
			allocator = context.temp_allocator,
		)
		_, _ = http.write("DELETE", cleanup_address, {bearer = access}, reuse)
	}
	session_id := new_id()
	defer delete(session_id)
	last_sender := ""
	defer delete(last_sender)
	last_message: u32
	ping_at := time.now()
	waiting_for_pong := false
	for !sync.atomic_load(&client.cancel) {
		defer free_all(context.temp_allocator)
		if time.since(tokens.expires_at) >= -time.Minute {return}
		for reply in chan.try_recv(client.replies) {
			if !reply_to_dealer(client, &socket, reply) {return}
		}
		changed := false
		for state in chan.try_recv(client.states) {
			free_snapshot(snapshot)
			snapshot^ = state
			changed = true
		}
		if changed && connection_id != "" {
			if !put_state(
				client,
				access,
				connection_id,
				session_id,
				snapshot^,
				4,
				last_sender,
				last_message,
				reuse,
			) {return}
		}
		body, ready, ok := http.ws_read(&socket)
		if !ok {return}
		if ready {
			envelope: Envelope
			if json.unmarshal(body, &envelope, allocator = context.temp_allocator) !=
			   nil {continue}
			if envelope.type == "message" &&
			   strings.has_prefix(envelope.uri, "hm://pusher/v1/connections/") {
				id := envelope.headers["Spotify-Connection-Id"]
				if id == "" {return}
				delete(connection_id)
				connection_id = strings.clone(id)
				if !put_state(
					client,
					access,
					connection_id,
					session_id,
					snapshot^,
					3,
					"",
					0,
					reuse,
				) {return}
				sync.atomic_store(&client.ready, true)
				notify(client)
				diagnostic.write("connect device registered")
			} else if envelope.type == "message" && len(envelope.payloads) == 1 {
				data, _, payload_ok := dealer_payload(envelope.payloads[0])
				if !payload_ok {continue}
				event: Event
				deliver := false
				if envelope.uri == "hm://connect-state/v1/connect/volume" {
					volume, found, valid := ap.get_number(data, 1)
					if found && valid && volume <= 65535 {
						event = Event {
							action = .Volume,
							volume = f32(volume) / 65535,
						}
						deliver = true
					}
				} else if envelope.uri == "hm://connect-state/v1/cluster" && snapshot.active {
					cluster, found, valid := ap.get_bytes(data, 1)
					if found && valid {
						active, _, active_valid := ap.get_bytes(cluster, 2)
						if active_valid && string(active) != client.device_id {
							event.action = .Inactive
							deliver = true
							snapshot.active = false
						}
					}
				}
				if deliver {
					if !chan.try_send(client.events, event) {return}
					notify(client)
				}
			} else if envelope.type == "request" {
				event: Event
				request: Request
				accepted, decoded := false, false
				player_command :=
					strings.trim_right(envelope.message_ident, "/") ==
					"hm://connect-state/v1/player/command"
				compressed := false
				if player_command {
					data, payload_compressed, payload_ok := dealer_payload(
						envelope.payload.compressed,
					)
					compressed = payload_compressed
					if payload_ok {
						decoded = true
						event, request, accepted = parse_command(data)
						if accepted &&
						   event.action == .Load &&
						   (request.command.endpoint == "transfer" || len(event.tracks) == 0) {
							accepted = resolve_context(client, access, &event, reuse)
						}
						if accepted {
							delete(last_sender)
							last_sender = strings.clone(request_sender(request))
							last_message = request_message_id(request)
						}
					}
				}
				diagnostic.writef(
					"connect request player=%v decoded=%v endpoint=%s parsed=%v tracks=%d compressed=%v",
					player_command,
					decoded,
					request.command.endpoint,
					accepted,
					len(event.tracks),
					compressed,
				)
				event.key = strings.clone(envelope.key)
				if !accepted || !chan.try_send(client.events, event) {
					free_event(event)
					if !reply_to_dealer(
						client,
						&socket,
						{strings.clone(envelope.key), false},
					) {return}
				} else {
					notify(client)
				}
			}
		}
		if waiting_for_pong {
			if time.since(socket.last_pong) < time.since(ping_at) {
				waiting_for_pong = false
			} else if time.since(ping_at) > 3 * time.Second {return}
		}
		if time.since(ping_at) >= 30 * time.Second {
			if !http.ws_write(&socket, nil, &client.cancel, ping = true) {return}
			ping_at = time.now()
			waiting_for_pong = true
		}
		if !ready {time.sleep(20 * time.Millisecond)}
	}
}

run :: proc(pointer: rawptr) {
	client := (^Client)(pointer)
	reuse := http.open_handle()
	defer http.close_handle(reuse)
	snapshot := Snapshot {
		volume = 0.5,
	}
	defer free_snapshot(&snapshot)
	for !sync.atomic_load(&client.cancel) {
		defer free_all(context.temp_allocator)
		tokens, authorized := session.authorize(.Remember, &client.cancel, interactive = false)
		if authorized {
			run_connection(client, tokens, &snapshot, reuse)
			oauth.wipe_tokens(&tokens)
		}
		for _ in 0 ..< 100 {
			if sync.atomic_load(&client.cancel) {return}
			time.sleep(100 * time.Millisecond)
		}
	}
}
