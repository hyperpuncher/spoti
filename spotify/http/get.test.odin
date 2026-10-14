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
	for method in ([]string{"POST", "PUT", "DELETE"}) {
		_, _, ok = json_request(method, "http://example.test/", "{}")
		testing.expect(t, !ok)
		_, _, ok = json_request(method, "https://example.test/", "")
		testing.expect(t, !ok)
	}
	_, _, ok = json_request("GET", "https://example.test/", "{}")
	testing.expect(t, !ok)
	for method in ([]string{"POST", "PUT", "DELETE"}) {
		_, _, ok = protobuf_request(method, "http://example.test/", []u8{0, 1})
		testing.expect(t, !ok)
	}
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
