// Worker-owned TLS WebSocket. libcurl verifies the server certificate and
// handles protocol ping replies. Addresses can carry tokens: never log them.
package http

import c "core:c/libc"
import "core:crypto"
import "core:strings"
import "core:sync"
import "core:time"

WS_LIMIT :: 1024 * 1024

WebSocket :: struct {
	handle:    rawptr,
	message:   [dynamic]u8,
	last_pong: time.Time,
}

ws_open :: proc(address: string, cancel: ^bool) -> (socket: WebSocket, ok: bool) {
	if !strings.has_prefix(address, "wss://") || strings.contains(address, "\x00") {return}
	socket.handle = open_handle()
	if socket.handle == nil {return}
	defer if !ok {ws_close(&socket)}
	url := strings.clone_to_cstring(address)
	defer {crypto.zero_explicit(rawptr(url), len(address)); delete(url)}
	response := Response_Buffer {
		limit = 16384,
	}
	defer delete(response.bytes)
	socket.last_pong = time.now()
	if easy_setopt(socket.handle, CURL_URL, url) != 0 ||
	   easy_setopt(socket.handle, CURL_CONNECT_ONLY, c.long(2)) != 0 ||
	   easy_setopt(socket.handle, CURL_WRITEFUNCTION, write_response) != 0 ||
	   easy_setopt(socket.handle, CURL_WRITEDATA, &response) != 0 ||
	   easy_setopt(socket.handle, CURL_TIMEOUT, c.long(15)) != 0 ||
	   easy_setopt(socket.handle, CURL_NOPROGRESS, c.long(0)) != 0 ||
	   easy_setopt(socket.handle, CURL_XFERINFOFUNCTION, transfer_progress) != 0 ||
	   easy_setopt(socket.handle, CURL_XFERINFODATA, cancel) != 0 {return socket, false}
	ok = easy_perform(socket.handle) == 0
	return
}

ws_close :: proc(socket: ^WebSocket) {
	close_handle(socket.handle)
	delete(socket.message)
	socket^ = {}
}

// ready=false is a nonblocking wait, ok=false means reconnect. A message
// remains valid until the next receive. Control frames never enter it.
ws_read :: proc(socket: ^WebSocket) -> (body: []u8, ready, ok: bool) {
	buffer: [16384]u8
	count: uint
	frame: ^WS_Frame
	code := ws_recv(socket.handle, raw_data(buffer[:]), uint(len(buffer)), &count, &frame)
	if code == 81 {return nil, false, true} 	// CURLE_AGAIN
	if code != 0 || frame == nil {return nil, false, false}
	if frame.flags & 8 != 0 {return nil, false, false} 	// CLOSE
	if frame.flags & 64 != 0 {socket.last_pong = time.now()}
	if frame.flags & (16 | 64) != 0 {return nil, false, true} 	// PING/PONG
	if frame.flags & 1 == 0 ||
	   count > uint(WS_LIMIT - len(socket.message)) ||
	   frame.bytesleft >
		   i64(WS_LIMIT - len(socket.message) - int(count)) {return nil, false, false}
	append(&socket.message, ..buffer[:int(count)])
	if frame.bytesleft != 0 || frame.flags & 4 != 0 {return nil, false, true}
	body = socket.message[:]
	// Retain the bytes for the caller, but overwrite them on the next read.
	clear(&socket.message)
	return body, true, true
}

ws_write :: proc(socket: ^WebSocket, body: []u8, cancel: ^bool, ping: bool = false) -> bool {
	deadline := time.tick_add(time.tick_now(), 3 * time.Second)
	offset := 0
	for {
		if sync.atomic_load(cancel) ||
		   time.tick_diff(time.tick_now(), deadline) <= 0 {return false}
		sent: uint
		remaining := len(body) - offset
		code := ws_send(
			socket.handle,
			raw_data(body[offset:]),
			uint(remaining),
			&sent,
			0,
			ping ? c.uint(16) : c.uint(1),
		)
		if code != 0 && code != 81 {return false}
		offset += int(sent)
		if offset == len(body) && code == 0 {return true}
		time.sleep(10 * time.Millisecond)
	}
}
