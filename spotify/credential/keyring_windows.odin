// Keep Spotify refresh credentials in the Windows Credential Manager
// through the WinCred API. Same semantics as the other backends: only a
// refresh token is stored, never an account password.
package credential

import "core:strings"
import win "core:sys/windows"

foreign import advapi32 "system:advapi32"

CREDENTIALW :: struct {
	flags:                u32,
	type:                 u32,
	target_name:          win.wstring,
	comment:              win.wstring,
	last_written:         win.FILETIME,
	credential_blob_size: u32,
	credential_blob:      [^]u8,
	persist:              u32,
	attribute_count:      u32,
	attributes:           rawptr,
	target_alias:         win.wstring,
	user_name:            win.wstring,
}

CRED_TYPE_GENERIC :: 1
CRED_PERSIST_LOCAL_MACHINE :: 2

foreign advapi32 {
	CredWriteW :: proc(credential: ^CREDENTIALW, flags: u32) -> win.BOOL ---
	CredReadW :: proc(target_name: win.wstring, type: u32, flags: u32, credential: ^^CREDENTIALW) -> win.BOOL ---
	CredDeleteW :: proc(target_name: win.wstring, type: u32, flags: u32) -> win.BOOL ---
	CredFree :: proc(buffer: rawptr) ---
}

Slot :: enum {
	Playback,
	Library,
	Library_Client,
}

slot_target :: proc(slot: Slot) -> string {
	switch slot {
	case .Library:
		return "spoti/library"
	case .Library_Client:
		return "spoti/library_client"
	case .Playback:
		return "spoti/playback"
	}
	return "spoti/playback"
}

slot_comment :: proc(slot: Slot) -> string {
	switch slot {
	case .Library:
		return "spoti Spotify library"
	case .Library_Client:
		return "spoti Spotify app ID"
	case .Playback:
		return "spoti Spotify playback"
	}
	return "spoti Spotify playback"
}

load :: proc(slot: Slot = .Playback) -> (token: string, found: bool) {
	target := win.utf8_to_wstring(slot_target(slot))
	found_cred: ^CREDENTIALW
	if CredReadW(target, CRED_TYPE_GENERIC, 0, &found_cred) == false {return "", false}
	defer CredFree(found_cred)
	if found_cred.credential_blob_size == 0 {return "", false}
	value := string(found_cred.credential_blob[:found_cred.credential_blob_size])
	if len(value) == 0 {return "", false}
	return strings.clone(value), true
}

save :: proc(token: string, slot: Slot = .Playback) -> bool {
	if len(token) == 0 || strings.contains(token, "\x00") {return false}
	cred := CREDENTIALW {
		type                 = CRED_TYPE_GENERIC,
		target_name          = win.utf8_to_wstring(slot_target(slot)),
		comment              = win.utf8_to_wstring(slot_comment(slot)),
		credential_blob_size = u32(len(token)),
		credential_blob      = raw_data(token),
		persist              = CRED_PERSIST_LOCAL_MACHINE,
		user_name            = win.utf8_to_wstring("spoti"),
	}
	return CredWriteW(&cred, 0) != false
}

clear :: proc(slot: Slot = .Playback) -> bool {
	target := win.utf8_to_wstring(slot_target(slot))
	return CredDeleteW(target, CRED_TYPE_GENERIC, 0) != false
}
