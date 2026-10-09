package http

import diagnostic "../../diagnostic"
import "base:runtime"
import c "core:c/libc"
import "core:crypto"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

Options :: struct {
	bearer:      string, // empty for signed CDN URLs; never forward account tokens
	range:       string, // optional HTTP byte range, e.g. "0-65535"
	method:      string, // PUT or DELETE with an empty body; empty keeps GET/POST
	limit:       int,
	range_info:  ^Range_Info, // optional validated Content-Range from a ranged GET
	retry_after: ^int, // optional Retry-After seconds from a 429
	cancel:      ^bool, // optional worker cancellation, observed by curl during transfer
}

Range_Info :: struct {
	start, end, total: int,
	valid:             bool,
}

// Header metadata one curl header callback can collect: range validation for
// ranged CDN reads, and the wait a 429 asks for.
Header_Capture :: struct {
	range:       ^Range_Info,
	retry_after: ^int,
}

read_headers :: proc "c" (input: [^]u8, size, count: int, user: rawptr) -> int {
	context = runtime.default_context()
	if size < 0 || count < 0 || count > 0 && size > 8192 / count {return 0}
	length := size * count
	capture := (^Header_Capture)(user)
	line := strings.trim_space(string(input[:length]))
	if strings.has_prefix(line, "HTTP/") {
		if capture.range != nil {capture.range^ = {}}
		if capture.retry_after != nil {capture.retry_after^ = 0}
		return length
	}
	if capture.range != nil && len(line) >= 14 && strings.equal_fold(line[:14], "Content-Range:") {
		capture.range^ = parse_content_range(strings.trim_space(line[14:]))
	} else if capture.retry_after != nil &&
	   len(line) >= 12 &&
	   strings.equal_fold(line[:12], "Retry-After:") {
		if seconds, valid := range_number(strings.trim_space(line[12:])); valid {
			capture.retry_after^ = seconds
		}
	}
	return length
}

parse_content_range :: proc(value: string) -> Range_Info {
	if !strings.has_prefix(value, "bytes ") {return {}}
	parts := strings.split(value[6:], "/")
	defer delete(parts)
	if len(parts) != 2 {return {}}
	bounds := strings.split(parts[0], "-")
	defer delete(bounds)
	if len(bounds) != 2 {return {}}
	start, a := range_number(bounds[0])
	end, b := range_number(bounds[1])
	total, c := range_number(parts[1])
	if !a || !b || !c || end < start || total <= end {return {}}
	return {start, end, total, true}
}

range_number :: proc(value: string) -> (number: int, ok: bool) {
	if len(value) == 0 {return}
	for char in value {
		if char < '0' || char > '9' {return 0, false}
		digit := int(char - '0')
		if number > (max(int) - digit) / 10 {return 0, false}
		number = number * 10 + digit
	}
	return number, true
}

Response_Buffer :: struct {
	bytes: [dynamic]u8,
	limit: int,
}

transfer_progress :: proc "c" (
	user: rawptr,
	download_total, downloaded, upload_total, uploaded: i64,
) -> c.int {
	return sync.atomic_load((^bool)(user)) ? 1 : 0
}

curl_once: sync.Once
curl_ready: bool

init_curl :: proc() {
	curl_ready = global_init(c.long(3)) == 0
}

write_response :: proc "c" (input: [^]u8, size, count: int, user: rawptr) -> int {
	context = runtime.default_context()
	state := (^Response_Buffer)(user)
	if size < 0 ||
	   count < 0 ||
	   count > 0 && size > (state.limit - len(state.bytes)) / count {return 0}
	length := size * count
	if length > state.limit - len(state.bytes) {return 0}
	append(&state.bytes, ..input[:length])
	return length
}

// One bounded HTTPS GET. Responses are returned even for non-2xx status so
// callers can diagnose a rejected grant without ever printing response bodies.
// Caller must delete the returned bytes; URLs can contain signed CDN secrets.
get :: proc(
	address: string,
	options: Options = {},
	reuse: rawptr = nil,
) -> (
	body: [dynamic]u8,
	status: int,
	ok: bool,
) {
	return request(address, options, reuse = reuse)
}

// Authenticated player and library writes: PUT, POST and DELETE with an
// empty body. The method is restricted to the verbs the app needs.
write :: proc(
	method, address: string,
	options: Options = {},
	reuse: rawptr = nil,
) -> (
	status: int,
	ok: bool,
) {
	if method != "PUT" && method != "POST" && method != "DELETE" {return 0, false}
	opts := options
	opts.method = method
	_, status, ok = request(address, opts, reuse = reuse)
	return status, ok
}

// OAuth uses the same curl lifetime and bounded response handling as GETs.
post_form :: proc(
	address, form: string,
	reuse: rawptr = nil,
) -> (
	body: [dynamic]u8,
	status: int,
	ok: bool,
) {
	if len(form) == 0 {return nil, 0, false}
	return request(address, {limit = 64 * 1024}, form, 20, reuse = reuse)
}

// Binary protobuf bodies may contain NUL bytes; POSTFIELDSIZE bounds the upload.
post_protobuf :: proc(
	address: string,
	body: []u8,
	options: Options = {},
	reuse: rawptr = nil,
) -> (
	response: [dynamic]u8,
	status: int,
	ok: bool,
) {
	if len(body) == 0 {return nil, 0, false}
	return request(
		address,
		options,
		transmute(string)body,
		content_type = "Content-Type: application/x-protobuf",
		reuse = reuse,
	)
}

// Authenticated JSON POST, e.g. adding items to a playlist. The body is a
// plain string, never logged; POSTFIELDSIZE bounds the upload.
post_json :: proc(
	address, body: string,
	options: Options = {},
	reuse: rawptr = nil,
) -> (
	response: [dynamic]u8,
	status: int,
	ok: bool,
) {
	if len(body) == 0 {return nil, 0, false}
	return request(
		address,
		options,
		body,
		content_type = "Content-Type: application/json",
		reuse = reuse,
	)
}

// Authenticated JSON PUT, e.g. transferring Connect playback. The body
// is a plain string, never logged; POSTFIELDSIZE bounds the upload.
put_json :: proc(
	address, body: string,
	options: Options = {},
	reuse: rawptr = nil,
) -> (
	response: [dynamic]u8,
	status: int,
	ok: bool,
) {
	if len(body) == 0 {return nil, 0, false}
	opts := options
	opts.method = "PUT"
	return request(
		address,
		opts,
		body,
		content_type = "Content-Type: application/json",
		reuse = reuse,
	)
}

// Authenticated JSON DELETE, e.g. removing items from a playlist. The body
// is a plain string, never logged; POSTFIELDSIZE bounds the upload.
delete_json :: proc(
	address, body: string,
	options: Options = {},
	reuse: rawptr = nil,
) -> (
	response: [dynamic]u8,
	status: int,
	ok: bool,
) {
	if len(body) == 0 {return nil, 0, false}
	opts := options
	opts.method = "DELETE"
	return request(
		address,
		opts,
		body,
		content_type = "Content-Type: application/json",
		reuse = reuse,
	)
}

// A reused easy handle keeps its TCP/TLS session alive across sequential
// requests on one worker thread. Handles must never cross threads; callers
// pass nil for one-off requests outside the workers.
@(private)
request :: proc(
	address: string,
	options: Options,
	form: string = "",
	timeout: c.long = 15,
	content_type: cstring = nil,
	reuse: rawptr = nil,
) -> (
	body: [dynamic]u8,
	status: int,
	ok: bool,
) {
	limit := options.limit
	if limit == 0 {limit = 64 * 1024}
	if !strings.has_prefix(address, "https://") ||
	   strings.contains(address, "\x00") ||
	   strings.contains(options.bearer, "\r") ||
	   strings.contains(options.bearer, "\n") ||
	   strings.contains(options.bearer, "\x00") ||
	   strings.contains(options.range, "\r") ||
	   strings.contains(options.range, "\n") ||
	   strings.contains(options.range, "\x00") ||
	   limit < 0 ||
	   limit > 32 * 1024 * 1024 {
		return nil, 0, false
	}
	sync.once_do(&curl_once, init_curl)
	if !curl_ready {return nil, 0, false}
	client := reuse
	if client == nil {
		client = easy_init()
		if client == nil {return nil, 0, false}
	} else {easy_reset(client)}
	// Owned handles are cleaned up here; reused worker handles outlive the call.
	defer if reuse == nil {
		easy_cleanup(client)
	}
	received := Response_Buffer {
		bytes = make([dynamic]u8),
		limit = limit,
	}
	defer if !ok {
		if len(form) > 0 {crypto.zero_explicit(raw_data(received.bytes), len(received.bytes))}
		delete(received.bytes)
	}
	c_address := strings.clone_to_cstring(address)
	defer delete(c_address)
	if easy_setopt(client, CURL_URL, c_address) != 0 ||
	   easy_setopt(client, CURL_TIMEOUT, timeout) != 0 ||
	   easy_setopt(client, CURL_WRITEFUNCTION, write_response) != 0 ||
	   easy_setopt(client, CURL_WRITEDATA, &received) != 0 {
		return nil, 0, false
	}
	if options.cancel != nil {
		if sync.atomic_load(options.cancel) {return nil, 0, false}
		if easy_setopt(client, CURL_NOPROGRESS, c.long(0)) != 0 ||
		   easy_setopt(client, CURL_XFERINFOFUNCTION, transfer_progress) != 0 ||
		   easy_setopt(client, CURL_XFERINFODATA, options.cancel) != 0 {return nil, 0, false}
	}
	if options.range_info != nil || options.retry_after != nil {
		if options.range_info != nil {options.range_info^ = {}}
		if options.retry_after != nil {options.retry_after^ = 0}
		capture := Header_Capture {
			range       = options.range_info,
			retry_after = options.retry_after,
		}
		if easy_setopt(client, CURL_HEADERFUNCTION, read_headers) != 0 ||
		   easy_setopt(client, CURL_HEADERDATA, &capture) != 0 {return nil, 0, false}
	}
	if len(form) > 0 {
		if easy_setopt(client, CURL_POSTFIELDSIZE, c.long(len(form))) != 0 ||
		   easy_setopt(client, CURL_POSTFIELDS, raw_data(form)) != 0 {return nil, 0, false}
	}
	if options.method != "" {
		c_method := strings.clone_to_cstring(options.method)
		defer delete(c_method)
		if easy_setopt(client, CURL_CUSTOMREQUEST, c_method) != 0 {return nil, 0, false}
		// An explicit empty body so a bodyless write carries Content-Length: 0.
		// A JSON body was already installed above and must not be cleared.
		if len(form) == 0 {
			if easy_setopt(client, CURL_POSTFIELDS, "") != 0 ||
			   easy_setopt(client, CURL_POSTFIELDSIZE, c.long(0)) != 0 {return nil, 0, false}
		}
	}
	if options.range != "" {
		c_range := strings.clone_to_cstring(options.range)
		defer delete(c_range)
		if easy_setopt(client, CURL_RANGE, c_range) != 0 {return nil, 0, false}
	}
	headers: ^Slist
	defer {
		for node := headers; node != nil; node = node.next {
			text := string(node.data)
			crypto.zero_explicit(raw_data(text), len(text))
		}
		slist_free_all(headers)
	}
	if content_type != nil {
		headers = slist_append(nil, content_type)
		if headers == nil {return nil, 0, false}
	}
	if options.bearer != "" {
		line := fmt.aprintf("Authorization: Bearer %s", options.bearer)
		defer {
			crypto.zero_explicit(raw_data(line), len(line))
			delete(line)
		}
		c_line := strings.clone_to_cstring(line)
		defer {
			crypto.zero_explicit(rawptr(c_line), len(line))
			delete(c_line)
		}
		extended := slist_append(headers, c_line)
		if extended == nil {return nil, 0, false}
		headers = extended
	}
	if headers != nil && easy_setopt(client, CURL_HTTPHEADER, headers) != 0 {return nil, 0, false}
	started := time.now()
	if easy_perform(client) != 0 {
		diagnostic.http(address, -1, 0, elapsed_ms(started))
		return nil, 0, false
	}
	code: c.long
	if easy_getinfo(client, CURL_RESPONSE_CODE, &code) != 0 {return nil, 0, false}
	diagnostic.http(address, int(code), len(received.bytes), elapsed_ms(started))
	return received.bytes, int(code), true
}

elapsed_ms :: proc(start: time.Time) -> f64 {
	return f64(time.since(start)) / f64(time.Millisecond)
}

// A worker-owned easy handle for connection reuse. Thread-confined: create
// and use on one thread, close it there too.
open_handle :: proc() -> rawptr {
	sync.once_do(&curl_once, init_curl)
	if !curl_ready {return nil}
	return easy_init()
}

close_handle :: proc(handle: rawptr) {
	if handle != nil {easy_cleanup(handle)}
}
