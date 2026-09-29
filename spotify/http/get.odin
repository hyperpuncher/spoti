package http

import "base:runtime"
import c "core:c/libc"
import "core:crypto"
import "core:fmt"
import "core:strings"
import "core:sync"

Options :: struct {
	bearer: string, // empty for signed CDN URLs; never forward account tokens
	range:  string, // optional HTTP byte range, e.g. "0-65535"
	limit:  int,
}

Response_Buffer :: struct {
	bytes: [dynamic]u8,
	limit: int,
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
get :: proc(address: string, options: Options = {}) -> (body: [dynamic]u8, status: int, ok: bool) {
	return request(address, options)
}

// OAuth uses the same curl lifetime and bounded response handling as GETs.
post_form :: proc(address, form: string) -> (body: [dynamic]u8, status: int, ok: bool) {
	if len(form) == 0 {return nil, 0, false}
	return request(address, {limit = 64 * 1024}, form, 20)
}

@(private)
request :: proc(
	address: string,
	options: Options,
	form: string = "",
	timeout: c.long = 15,
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
	client := easy_init()
	if client == nil {return nil, 0, false}
	defer easy_cleanup(client)
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
	if len(form) > 0 {
		if easy_setopt(client, CURL_POSTFIELDSIZE, c.long(len(form))) != 0 ||
		   easy_setopt(client, CURL_POSTFIELDS, raw_data(form)) != 0 {return nil, 0, false}
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
		headers = slist_append(nil, c_line)
		if headers == nil {return nil, 0, false}
		if easy_setopt(client, CURL_HTTPHEADER, headers) != 0 {return nil, 0, false}
	}
	if easy_perform(client) != 0 {return nil, 0, false}
	code: c.long
	if easy_getinfo(client, CURL_RESPONSE_CODE, &code) != 0 {return nil, 0, false}
	return received.bytes, int(code), true
}
