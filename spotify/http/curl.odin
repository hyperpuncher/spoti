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
	easy_cleanup :: proc(handle: rawptr) ---
	easy_setopt :: proc(handle: rawptr, option: c.int, #c_vararg args: ..any) -> c.int ---
	easy_perform :: proc(handle: rawptr) -> c.int ---
	easy_getinfo :: proc(handle: rawptr, info: c.int, #c_vararg args: ..any) -> c.int ---
	slist_append :: proc(list: ^Slist, line: cstring) -> ^Slist ---
	slist_free_all :: proc(list: ^Slist) ---
}

Slist :: struct {
	data: cstring,
	next: ^Slist,
}

CURL_URL :: c.int(10002)
CURL_POSTFIELDS :: c.int(10015)
CURL_POSTFIELDSIZE :: c.int(60)
CURL_TIMEOUT :: c.int(13)
CURL_WRITEFUNCTION :: c.int(20011)
CURL_WRITEDATA :: c.int(10001)
CURL_HTTPHEADER :: c.int(10023)
CURL_RANGE :: c.int(10007)
CURL_RESPONSE_CODE :: c.int(0x200002)
