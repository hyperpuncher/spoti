// Keep Spotify refresh credentials in the macOS Keychain through the
// security CLI. Same semantics as the Secret Service backend: only a
// refresh token is stored, never an account password.
package credential

import "core:os"
import "core:strings"

SERVICE :: "org.spoti.playback"

Slot :: enum {
	Playback,
	Library,
	Library_Client,
}

slot_account :: proc(slot: Slot) -> string {
	switch slot {
	case .Library:
		return "library"
	case .Library_Client:
		return "library_client"
	case .Playback:
		return "playback"
	}
	return "playback"
}

slot_label :: proc(slot: Slot) -> string {
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
	state, output, _, err := os.process_exec(
		{
			command = {
				"security",
				"find-generic-password",
				"-a",
				slot_account(slot),
				"-s",
				SERVICE,
				"-w",
			},
		},
		context.temp_allocator,
	)
	if err != nil || !state.exited || state.exit_code != 0 {return "", false}
	value := strings.trim_space(string(output))
	if len(value) == 0 {return "", false}
	return strings.clone(value), true
}

save :: proc(token: string, slot: Slot = .Playback) -> bool {
	if len(token) == 0 || strings.contains(token, "\x00") {return false}
	state, _, _, err := os.process_exec(
		{
			command = {
				"security",
				"add-generic-password",
				"-a",
				slot_account(slot),
				"-s",
				SERVICE,
				"-l",
				slot_label(slot),
				"-w",
				token,
				"-U",
			},
		},
		context.temp_allocator,
	)
	return err == nil && state.exited && state.exit_code == 0
}

clear :: proc(slot: Slot = .Playback) -> bool {
	state, _, _, err := os.process_exec(
		{
			command = {
				"security",
				"delete-generic-password",
				"-a",
				slot_account(slot),
				"-s",
				SERVICE,
			},
		},
		context.temp_allocator,
	)
	return err == nil && state.exited && state.exit_code == 0
}
