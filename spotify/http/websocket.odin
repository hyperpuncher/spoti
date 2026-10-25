// Worker-owned TLS WebSocket. libcurl verifies the server certificate and
// handles protocol ping replies. Addresses can carry tokens: never log them.
package http

import c "core:c/libc"
import "core:crypto"
import "core:strings"
import "core:sync"
import "core:time"
import curl "vendor:curl"

WS_LIMIT :: 1024 * 1024

WebSocket :: struct {
	handle:    ^curl.CURL,
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
	if curl.easy_setopt(socket.handle, .URL, url) != .E_OK ||
	   curl.easy_setopt(socket.handle, .CONNECT_ONLY, c.long(2)) != .E_OK ||
	   curl.easy_setopt(socket.handle, .WRITEFUNCTION, write_response) != .E_OK ||
	   curl.easy_setopt(socket.handle, .WRITEDATA, &response) != .E_OK ||
	   curl.easy_setopt(socket.handle, .TIMEOUT, c.long(15)) != .E_OK ||
	   curl.easy_setopt(socket.handle, .NOPROGRESS, c.long(0)) != .E_OK ||
	   curl.easy_setopt(socket.handle, .XFERINFOFUNCTION, transfer_progress) != .E_OK ||
	   curl.easy_setopt(socket.handle, .XFERINFODATA, cancel) != .E_OK {return socket, false}
	ok = curl.easy_perform(socket.handle) == .E_OK
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
	frame: ^curl.ws_frame
	code := curl.ws_recv(socket.handle, raw_data(buffer[:]), uint(len(buffer)), &count, &frame)
	if code == .E_AGAIN {return nil, false, true}
	if code != .E_OK || frame == nil {return nil, false, false}
	if .CLOSE in frame.flags {return nil, false, false}
	if .PONG in frame.flags {socket.last_pong = time.now()}
	if .PING in frame.flags || .PONG in frame.flags {return nil, false, true}
	if .TEXT not_in frame.flags ||
	   count > uint(WS_LIMIT - len(socket.message)) ||
	   frame.bytesleft >
		   i64(WS_LIMIT - len(socket.message) - int(count)) {return nil, false, false}
	append(&socket.message, ..buffer[:int(count)])
	if frame.bytesleft != 0 || .CONT in frame.flags {return nil, false, true}
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
		code := curl.ws_send(
			socket.handle,
			raw_data(body[offset:]),
			uint(remaining),
			&sent,
			0,
			ping ? curl.WS_PING : curl.WS_TEXT,
		)
		if code != .E_OK && code != .E_AGAIN {return false}
		offset += int(sent)
		if offset == len(body) && code == .E_OK {return true}
		time.sleep(10 * time.Millisecond)
	}
}
