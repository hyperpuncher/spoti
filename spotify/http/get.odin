package http

import diagnostic "../../diagnostic"
import "base:runtime"
import c "core:c/libc"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import curl "vendor:curl"

Options :: struct {
	bearer:        string, // empty for signed CDN URLs; never forward account tokens
	connection_id: string, // Dealer connection header; never logged
	range:         string, // optional HTTP byte range, e.g. "0-65535"
	method:        string, // PUT or DELETE with an empty body; empty keeps GET/POST
	limit:         int,
	range_info:    ^Range_Info, // optional validated Content-Range from a ranged GET
	retry_after:   ^int, // optional Retry-After seconds from a 429
	cancel:        ^bool, // optional worker cancellation, observed by curl during transfer
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

read_headers :: proc "c" (input: [^]u8, size, count: c.size_t, user: rawptr) -> c.size_t {
	context = runtime.default_context()
	if count > 0 && size > 8192 / count {return 0}
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
web_api_resume_ns: i64

// The Web API quota is shared by reads and writes, not by covers or AP calls.
// Keep the deadline atomic because the worker writes it and the UI reads it.
web_api_resume_at :: proc() -> time.Time {
	return time.from_nanoseconds(sync.atomic_load(&web_api_resume_ns))
}

// Restore saved deadlines before workers start; later responses can only extend them.
web_api_defer_until :: proc(at: time.Time) {
	deadline := time.time_to_unix_nano(at)
	current := sync.atomic_load(&web_api_resume_ns)
	for current < deadline {
		previous, changed := sync.atomic_compare_exchange_weak(
			&web_api_resume_ns,
			current,
			deadline,
		)
		if changed {return}
		current = previous
	}
}

// Only a documented, recognised reason may reach diagnostics. Never log body text.
web_api_limit_reason :: proc(body: []u8) -> string {
	response: struct {
		error: struct {
			reason: string,
		},
	}
	if json.unmarshal(body, &response, allocator = context.temp_allocator) == nil &&
	   response.error.reason == "QUOTA_EXCEEDED" {return "quota-exceeded"}
	return "unknown"
}

init_curl :: proc() {
	curl_ready = curl.global_init(curl.GLOBAL_DEFAULT) == .E_OK
}

write_response :: proc "c" (input: [^]u8, size, count: c.size_t, user: rawptr) -> c.size_t {
	context = runtime.default_context()
	state := (^Response_Buffer)(user)
	if count > 0 && size > c.size_t(state.limit - len(state.bytes)) / count {return 0}
	length := size * count
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
	body, code, sent := request(address, opts, reuse = reuse)
	delete(body)
	return code, sent
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

// Upload sizes are explicit, including NUL bytes in protobuf payloads.
protobuf_request :: proc(
	method, address: string,
	body: []u8,
	options: Options = {},
	reuse: rawptr = nil,
) -> (
	response: [dynamic]u8,
	status: int,
	ok: bool,
) {
	if method != "POST" && method != "PUT" || method == "POST" && len(body) == 0 {return}
	opts := options
	opts.method = method
	return request(
		address,
		opts,
		transmute(string)body,
		content_type = "Content-Type: application/x-protobuf",
		reuse = reuse,
	)
}

// JSON writes share validation and response ownership.
json_request :: proc(
	method, address, body: string,
	options: Options = {},
	reuse: rawptr = nil,
) -> (
	response: [dynamic]u8,
	status: int,
	ok: bool,
) {
	if len(body) == 0 || method != "POST" && method != "PUT" && method != "DELETE" {return}
	opts := options
	opts.method = method
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
	   strings.contains(options.connection_id, "\r") ||
	   strings.contains(options.connection_id, "\n") ||
	   strings.contains(options.connection_id, "\x00") ||
	   strings.contains(options.range, "\r") ||
	   strings.contains(options.range, "\n") ||
	   strings.contains(options.range, "\x00") ||
	   limit < 0 ||
	   limit > 32 * 1024 * 1024 {
		return nil, 0, false
	}
	web_api := strings.has_prefix(address, "https://api.spotify.com/")
	if web_api {
		if delay := -time.since(web_api_resume_at()); delay > 0 {
			seconds := int((delay + time.Second - 1) / time.Second)
			if options.retry_after != nil {options.retry_after^ = seconds}
			diagnostic.writef("web api request deferred retry-after=%ds", seconds)
			return nil, 429, true
		}
	}
	client := (^curl.CURL)(reuse)
	if client == nil {
		client = open_handle()
		if client == nil {return nil, 0, false}
	} else {curl.easy_reset(client)}
	// Owned handles are cleaned up here; reused worker handles outlive the call.
	defer if reuse == nil {
		curl.easy_cleanup(client)
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
	if curl.easy_setopt(client, .URL, c_address) != .E_OK ||
	   curl.easy_setopt(client, .TIMEOUT, timeout) != .E_OK ||
	   curl.easy_setopt(client, .WRITEFUNCTION, write_response) != .E_OK ||
	   curl.easy_setopt(client, .WRITEDATA, &received) != .E_OK {
		return nil, 0, false
	}
	if options.cancel != nil {
		if sync.atomic_load(options.cancel) {return nil, 0, false}
		if curl.easy_setopt(client, .NOPROGRESS, c.long(0)) != .E_OK ||
		   curl.easy_setopt(client, .XFERINFOFUNCTION, transfer_progress) != .E_OK ||
		   curl.easy_setopt(client, .XFERINFODATA, options.cancel) != .E_OK {return nil, 0, false}
	}
	// curl keeps this pointer until perform completes, not just until setopt.
	retry_after := 0
	capture := Header_Capture {
		range       = options.range_info,
		retry_after = options.retry_after,
	}
	if web_api {capture.retry_after = &retry_after}
	if options.range_info != nil || options.retry_after != nil || web_api {
		if options.range_info != nil {options.range_info^ = {}}
		if options.retry_after != nil {options.retry_after^ = 0}
		if curl.easy_setopt(client, .HEADERFUNCTION, read_headers) != .E_OK ||
		   curl.easy_setopt(client, .HEADERDATA, &capture) != .E_OK {return nil, 0, false}
	}
	if len(form) > 0 {
		if curl.easy_setopt(client, .POSTFIELDSIZE, c.long(len(form))) != .E_OK ||
		   curl.easy_setopt(client, .POSTFIELDS, raw_data(form)) != .E_OK {return nil, 0, false}
	}
	if options.method != "" {
		c_method := strings.clone_to_cstring(options.method)
		defer delete(c_method)
		if curl.easy_setopt(client, .CUSTOMREQUEST, c_method) != .E_OK {return nil, 0, false}
		// An explicit empty body so a bodyless write carries Content-Length: 0.
		// A JSON body was already installed above and must not be cleared.
		if len(form) == 0 {
			if curl.easy_setopt(client, .POSTFIELDS, "") != .E_OK ||
			   curl.easy_setopt(client, .POSTFIELDSIZE, c.long(0)) != .E_OK {return nil, 0, false}
		}
	}
	if options.range != "" {
		c_range := strings.clone_to_cstring(options.range)
		defer delete(c_range)
		if curl.easy_setopt(client, .RANGE, c_range) != .E_OK {return nil, 0, false}
	}
	headers: ^curl.slist
	defer {
		for node := headers; node != nil; node = node.next {
			text := string(cstring(node.data))
			crypto.zero_explicit(raw_data(text), len(text))
		}
		curl.slist_free_all(headers)
	}
	if content_type != nil {
		headers = curl.slist_append(nil, content_type)
		if headers == nil {return nil, 0, false}
	}
	if options.bearer != "" {
		line := fmt.caprintf("Authorization: Bearer %s", options.bearer)
		defer {
			crypto.zero_explicit(rawptr(line), len(string(line)))
			delete(line)
		}
		extended := curl.slist_append(headers, line)
		if extended == nil {return nil, 0, false}
		headers = extended
	}
	if options.connection_id != "" {
		line := fmt.caprintf(
			"X-Spotify-Connection-Id: %s",
			options.connection_id,
			allocator = context.temp_allocator,
		)
		extended := curl.slist_append(headers, line)
		if extended == nil {return nil, 0, false}
		headers = extended
	}
	if headers != nil &&
	   curl.easy_setopt(client, .HTTPHEADER, headers) != .E_OK {return nil, 0, false}
	started := time.now()
	if curl.easy_perform(client) != .E_OK {
		diagnostic.http(address, -1, 0, elapsed_ms(started))
		return nil, 0, false
	}
	code: c.long
	if curl.easy_getinfo(client, .RESPONSE_CODE, &code) != .E_OK {return nil, 0, false}
	if web_api {
		if options.retry_after != nil {options.retry_after^ = retry_after}
		if code == 429 {
			// Use a minute when the server omits its delay. Bound the conversion
			// to nanoseconds so an invalid header cannot overflow the deadline.
			seconds := retry_after > 0 ? min(retry_after, int(max(i32))) : 60
			resume := time.time_add(time.now(), time.Duration(seconds) * time.Second)
			web_api_defer_until(resume)
			diagnostic.writef(
				"web api paused seconds=%d reason=%s",
				seconds,
				web_api_limit_reason(received.bytes[:]),
			)
		}
	}
	diagnostic.http(address, int(code), len(received.bytes), elapsed_ms(started), retry_after)
	return received.bytes, int(code), true
}

elapsed_ms :: proc(start: time.Time) -> f64 {
	return f64(time.since(start)) / f64(time.Millisecond)
}

// A worker-owned easy handle for connection reuse. Thread-confined: create
// and use on one thread, close it there too.
open_handle :: proc() -> ^curl.CURL {
	sync.once_do(&curl_once, init_curl)
	if !curl_ready {return nil}
	return curl.easy_init()
}

close_handle :: proc(handle: rawptr) {
	if handle != nil {curl.easy_cleanup((^curl.CURL)(handle))}
}
