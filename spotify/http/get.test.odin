package http

import c "core:c/libc"
import "core:sync"
import "core:testing"
import "core:time"
import curl "vendor:curl"

@(test)
linked_curl_supports_https_and_websockets :: proc(t: ^testing.T) {
	handle := open_handle()
	if !testing.expect(t, handle != nil) {return}
	defer close_handle(handle)
	info := curl.version_info(curl.VERSION_NOW)
	for required in ([]string{"https", "ws", "wss"}) {
		found := false
		for index := 0; info.protocols[index] != nil; index += 1 {
			if string(info.protocols[index]) == required {found = true; break}
		}
		testing.expectf(t, found, "linked libcurl must support %s", required)
	}
}

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
	// A shared cooldown rejects a different Web API request without network I/O.
	previous := sync.atomic_load(&web_api_resume_ns)
	defer sync.atomic_store(&web_api_resume_ns, previous)
	deadline := time.time_add(time.now(), time.Minute)
	web_api_defer_until(deadline)
	web_api_defer_until(time.time_add(deadline, -time.Second))
	testing.expect_value(t, web_api_resume_at(), deadline)
	body, status, ok := get("https://api.spotify.com/v1/me", {retry_after = &retry_after})
	defer delete(body)
	testing.expect(t, ok && status == 429 && len(body) == 0 && retry_after > 0)
	extended := time.time_add(deadline, time.Minute)
	web_api_defer_until(extended)
	web_api_defer_until(deadline)
	testing.expect_value(t, web_api_resume_at(), extended)
}

@(test)
web_api_limit_reason_never_returns_server_text :: proc(t: ^testing.T) {
	quota := `{"error":{"status":429,"message":"private server text","reason":"QUOTA_EXCEEDED"}}`
	testing.expect_value(t, web_api_limit_reason(transmute([]u8)quota), "quota-exceeded")
	for body in ([]string{"", "not JSON", "[]", "null", `{"error":{"message":"private server text"}}`, `{"error":{"reason":"UNRECOGNISED"}}`, `{"error":{"reason":123}}`}) {
		testing.expect_value(t, web_api_limit_reason(transmute([]u8)body), "unknown")
	}
}

feed_header :: proc(capture: ^Header_Capture, line: string) {
	_ = read_headers(raw_data(line), 1, c.size_t(len(line)), capture)
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
	testing.expect_value(t, write_response(raw_data(input), max(c.size_t), 2, &buffer), 0)
	testing.expect_value(t, len(buffer.bytes), 0)
	testing.expect_value(t, write_response(raw_data(input), 1, 8, &buffer), 8)
	testing.expect_value(t, write_response(raw_data(input), 1, 1, &buffer), 0)
	testing.expect_value(t, len(buffer.bytes), 8)
	testing.expect_value(t, buffer.bytes[7], u8(8))
}
