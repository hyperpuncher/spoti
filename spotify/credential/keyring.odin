// Keep Spotify refresh credentials in the desktop Secret Service. Never
// write them to an app state file or pass them in process arguments.
#+build linux
package credential

import c "core:c/libc"
import "core:crypto"
import "core:strings"

foreign import secret "system:secret-1"
foreign import glib "system:glib-2.0"

@(default_calling_convention = "c", link_prefix = "secret_")
foreign secret {
	schema_new :: proc(name: cstring, flags: c.int, #c_vararg args: ..any) -> rawptr ---
	schema_unref :: proc(schema: rawptr) ---
	password_lookup_sync :: proc(schema, cancellable: rawptr, error: ^^G_Error, #c_vararg args: ..any) -> cstring ---
	password_store_sync :: proc(schema: rawptr, collection, label, password: cstring, cancellable: rawptr, error: ^^G_Error, #c_vararg args: ..any) -> c.int ---
	password_clear_sync :: proc(schema, cancellable: rawptr, error: ^^G_Error, #c_vararg args: ..any) -> c.int ---
	password_free :: proc(password: cstring) ---
}

@(default_calling_convention = "c", link_prefix = "g_")
foreign glib {
	error_free :: proc(error: ^G_Error) ---
}

G_Error :: struct {
	domain:  u32,
	code:    c.int,
	message: cstring,
}

// Use a private application namespace rather than Spotifast's credential
// entry. The stored value is only a refresh token, not an account password.
Slot :: enum {
	Playback,
	Library,
}

slot_name :: proc(slot: Slot) -> cstring {
	return slot == .Library ? cstring("library") : cstring("playback")
}

new_schema :: proc() -> rawptr {
	return schema_new("org.spoti.playback", 0, cstring("slot"), c.int(0), cstring(nil))
}

load :: proc(slot: Slot = .Playback) -> (token: string, found: bool) {
	schema := new_schema()
	if schema == nil {return "", false}
	defer schema_unref(schema)
	failure: ^G_Error
	ptr := password_lookup_sync(
		schema,
		nil,
		&failure,
		cstring("slot"),
		slot_name(slot),
		cstring(nil),
	)
	if failure != nil {error_free(failure); return "", false}
	if ptr == nil {return "", false}
	defer password_free(ptr)
	value := string(ptr)
	if len(value) == 0 {return "", false}
	return strings.clone(value), true
}

save :: proc(token: string, slot: Slot = .Playback) -> bool {
	if len(token) == 0 || strings.contains(token, "\x00") {return false}
	schema := new_schema()
	if schema == nil {return false}
	defer schema_unref(schema)
	failure: ^G_Error
	c_token := strings.clone_to_cstring(token)
	defer {
		// A copy remains inside libsecret only after successful storage.
		crypto.zero_explicit(rawptr(c_token), len(token))
		delete(c_token)
	}
	ok := password_store_sync(
		schema,
		nil,
		slot == .Library ? cstring("spoti Spotify library") : cstring("spoti Spotify playback"),
		c_token,
		nil,
		&failure,
		cstring("slot"),
		slot_name(slot),
		cstring(nil),
	)
	if failure != nil {error_free(failure); return false}
	return ok != 0
}

clear :: proc(slot: Slot = .Playback) -> bool {
	schema := new_schema()
	if schema == nil {return false}
	defer schema_unref(schema)
	failure: ^G_Error
	ok := password_clear_sync(
		schema,
		nil,
		&failure,
		cstring("slot"),
		slot_name(slot),
		cstring(nil),
	)
	if failure != nil {error_free(failure); return false}
	return ok != 0
}
