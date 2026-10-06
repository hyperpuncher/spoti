package http

import "core:testing"

@(test)
get_rejects_invalid_or_non_https_addresses :: proc(t: ^testing.T) {
	_, _, ok := get("http://127.0.0.1/", {})
	testing.expect(t, !ok)
	_, _, ok = get("https://example.test/\x00http://127.0.0.1", {})
	testing.expect(t, !ok)
	_, _, ok = get("https://example.test/", {bearer = "bad\r\nInjected: header"})
	testing.expect(t, !ok)
}

@(test)
post_form_rejects_invalid_addresses_and_empty_forms :: proc(t: ^testing.T) {
	_, _, ok := post_form("http://127.0.0.1/", "grant_type=refresh_token")
	testing.expect(t, !ok)
	_, _, ok = post_form("https://example.test/\x00", "grant_type=refresh_token")
	testing.expect(t, !ok)
	_, _, ok = post_form("https://example.test/", "")
	testing.expect(t, !ok)
}

@(test)
header_capture_reads_retry_after_and_resets_per_response :: proc(t: ^testing.T) {
	retry_after := 7
	info: Range_Info
	capture := Header_Capture {
		range       = &info,
		retry_after = &retry_after,
	}
	feed_header(&capture, "HTTP/1.1 429 Too Many Requests\r\n")
	testing.expect_value(t, retry_after, 0)
	feed_header(&capture, "Retry-After: 121\r\n")
	testing.expect_value(t, retry_after, 121)
	feed_header(&capture, "Content-Range: bytes 0-15/1000\r\n")
	testing.expect(t, info.valid && info.start == 0 && info.end == 15 && info.total == 1000)
	// A new response clears both, and a malformed value leaves the reset one.
	feed_header(&capture, "HTTP/1.1 200 OK\r\n")
	testing.expect_value(t, retry_after, 0)
	testing.expect(t, !info.valid)
	feed_header(&capture, "Retry-After: soon\r\n")
	testing.expect_value(t, retry_after, 0)
}

feed_header :: proc(capture: ^Header_Capture, line: string) {
	_ = read_headers(raw_data(line), 1, len(line), capture)
}

@(test)
response_buffer_rejects_overflow_and_excess_data :: proc(t: ^testing.T) {
	buffer := Response_Buffer {
		bytes = make([dynamic]u8),
		limit = 8,
	}
	defer delete(buffer.bytes)
	input := []u8{1, 2, 3, 4, 5, 6, 7, 8}
	// Reject the multiplication before an overflowing length can bypass the bound.
	max_int := max(int)
	testing.expect_value(t, write_response(raw_data(input), max_int, 2, &buffer), 0)
	testing.expect_value(t, len(buffer.bytes), 0)
	testing.expect_value(t, write_response(raw_data(input), 1, 8, &buffer), 8)
	testing.expect_value(t, write_response(raw_data(input), 1, 1, &buffer), 0)
	testing.expect_value(t, len(buffer.bytes), 8)
	testing.expect_value(t, buffer.bytes[7], u8(8))
}

// Live request: the token endpoint needs no grant to refuse one, so a bogus
// refresh proves the full perform path. Covers both owned handles (the
// default) and a reused worker handle across sequential calls.
@(test)
https_requests_perform_with_owned_and_reused_handles :: proc(t: ^testing.T) {
	form := "grant_type=refresh_token&client_id=abc&refresh_token=abc"
	body, status, ok := post_form("https://accounts.spotify.com/api/token", form)
	defer delete(body)
	if !testing.expect(t, ok) {return}
	testing.expect(t, status == 400 || status == 401)
	reuse := open_handle()
	if !testing.expect(t, reuse != nil) {return}
	defer close_handle(reuse)
	for _ in 0 ..< 2 {
		again, code, fetched := post_form("https://accounts.spotify.com/api/token", form, reuse)
		defer delete(again)
		if !testing.expect(t, fetched) {return}
		testing.expect(t, code == 400 || code == 401)
	}
}

@(test)
write_rejects_anything_but_put_and_delete :: proc(t: ^testing.T) {
	_, ok := write("GET", "https://api.spotify.com/v1/me/library?uris=x")
	testing.expect(t, !ok)
	_, ok = write("POST", "https://api.spotify.com/v1/me/library?uris=x")
	testing.expect(t, !ok)
	_, ok = write("", "https://api.spotify.com/v1/me/library?uris=x")
	testing.expect(t, !ok)
	// Valid verbs still refuse non-HTTPS without touching the network.
	_, ok = write("PUT", "http://127.0.0.1/")
	testing.expect(t, !ok)
	_, ok = write("DELETE", "http://127.0.0.1/")
	testing.expect(t, !ok)
}
