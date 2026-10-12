#+private
package http

// Small libcurl C ABI used by OAuth and Spotify media requests. Odin's
// installed vendor:curl package links optional mbedTLS development libraries
// unavailable on this system; the system libcurl already handles TLS.
// Constants below are CURL* values from curl.h.
import c "core:c/libc"

foreign import libcurl "system:curl"

@(default_calling_convention = "c", link_prefix = "curl_")
foreign libcurl {
	global_init :: proc(flags: c.long) -> c.int ---
	easy_init :: proc() -> rawptr ---
	easy_reset :: proc(handle: rawptr) ---
	easy_cleanup :: proc(handle: rawptr) ---
	easy_setopt :: proc(handle: rawptr, option: c.int, #c_vararg args: ..any) -> c.int ---
	easy_perform :: proc(handle: rawptr) -> c.int ---
	easy_getinfo :: proc(handle: rawptr, info: c.int, #c_vararg args: ..any) -> c.int ---
	slist_append :: proc(list: ^Slist, line: cstring) -> ^Slist ---
	slist_free_all :: proc(list: ^Slist) ---
	ws_recv :: proc(handle: rawptr, buffer: rawptr, capacity: uint, received: ^uint, frame: ^^WS_Frame) -> c.int ---
	ws_send :: proc(handle: rawptr, buffer: rawptr, length: uint, sent: ^uint, frame_size: i64, flags: c.uint) -> c.int ---
}

Slist :: struct {
	data: cstring,
	next: ^Slist,
}

WS_Frame :: struct {
	age:       c.int,
	flags:     c.uint,
	offset:    i64,
	bytesleft: i64,
	len:       uint,
}

CURL_CONNECT_ONLY :: c.int(141)
CURL_URL :: c.int(10002)
CURL_POSTFIELDS :: c.int(10015)
CURL_POSTFIELDSIZE :: c.int(60)
CURL_TIMEOUT :: c.int(13)
CURL_WRITEFUNCTION :: c.int(20011)
CURL_WRITEDATA :: c.int(10001)
CURL_HEADERFUNCTION :: c.int(20079)
CURL_HEADERDATA :: c.int(10029)
CURL_NOPROGRESS :: c.int(43)
CURL_XFERINFOFUNCTION :: c.int(20219)
CURL_XFERINFODATA :: c.int(10057)
CURL_HTTPHEADER :: c.int(10023)
CURL_CUSTOMREQUEST :: c.int(10036)
CURL_RANGE :: c.int(10007)
CURL_RESPONSE_CODE :: c.int(0x200002)
