package oauth

import "core:crypto"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

Wait_Result :: enum {
	Bind_Failed,
	Timed_Out,
	Denied,
	Authorized,
	Cancelled,
}

// Browser approval owns the listener and one-use secrets. Grant persistence
// and the decision to start an interactive flow belong to the caller.
authorize :: proc(
	grant: Grant,
	kind: Prompt,
	cancel: ^bool = nil,
) -> (
	tokens: Tokens,
	browser: Wait_Result,
	result: Token_Result,
) {
	if cancel != nil && sync.atomic_load(cancel) {return {}, .Cancelled, .Network_Error}
	listener, ready := listen(int(grant.port))
	if !ready {return {}, .Bind_Failed, .Network_Error}
	defer net.close(listener)
	flow := begin(grant)
	defer {
		publish_prompt(kind, "")
		crypto.zero_explicit(raw_data(flow.verifier), len(flow.verifier))
		delete(flow.verifier)
		delete(flow.state)
		delete(flow.url)
	}
	publish_prompt(kind, flow.url)
	code: string
	code, browser = wait_for_code(listener, flow.state, cancel)
	if browser != .Authorized {return}
	defer {crypto.zero_explicit(raw_data(code), len(code)); delete(code)}
	tokens, result = exchange_code(code, flow.verifier, grant)
	return
}

listen :: proc(port: int = 8898) -> (net.TCP_Socket, bool) {
	socket, err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = port})
	if err != nil {return {}, false}
	if net.set_blocking(socket, false) != nil {
		net.close(socket)
		return {}, false
	}
	return socket, true
}

// Only localhost is bound. Bounded HTTP reads, a receive timeout and a
// ten-minute accept deadline keep abandoned or hostile redirects from hanging
// sign-in indefinitely. Call after listen() and after showing the browser URL.
wait_for_code :: proc(
	listener: net.TCP_Socket,
	state: string,
	cancel: ^bool = nil,
) -> (
	code: string,
	result: Wait_Result,
) {
	started := time.now()
	for time.since(started) < time.Duration(10 * time.Minute) {
		if cancel != nil && sync.atomic_load(cancel) {return "", .Cancelled}
		client, _, err := net.accept_tcp(listener)
		if err == .Would_Block {
			time.sleep(time.Duration(50 * time.Millisecond))
			continue
		}
		if err != nil {return "", .Bind_Failed}
		_ = net.set_option(client, .Receive_Timeout, time.Duration(3 * time.Second))
		buffer: [4096]u8
		used := 0
		line: string
		for used < len(buffer) {
			n, read_err := net.recv_tcp(client, buffer[used:])
			if read_err != nil || n == 0 {break}
			used += n
			end := strings.index_byte(string(buffer[:used]), '\n')
			if end != -1 {line = strings.trim_right(string(buffer[:end]), "\r"); break}
		}
		found, outcome := parse_callback(line, state)
		body := "Sign-in was not accepted. Return to spoti."
		if outcome == .Authorized {body = "Sign-in complete. Return to spoti."}
		response := fmt.aprintf(
			"HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: %d\r\n\r\n%s",
			len(body),
			body,
			allocator = context.temp_allocator,
		)
		written := 0
		for written < len(response) {
			n, send_err := net.send_tcp(client, transmute([]u8)response[written:])
			if send_err != nil || n == 0 {break}
			written += n
		}
		net.close(client)
		free_all(context.temp_allocator)
		switch outcome {
		case .Authorized:
			return found, .Authorized
		case .Denied:
			return "", .Denied
		case .Rejected, .Ignored: // wait for a valid redirect
		}
	}
	return "", .Timed_Out
}
