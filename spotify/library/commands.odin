// Spotify Connect playback commands for the API-active device. No
// device id is sent: without one Spotify targets the active device.
// Bodies are empty; every parameter rides the query string.
package library

import diagnostic "../../diagnostic"
import http "../http"
import "core:fmt"
import "core:strings"

PLAY_ADDRESS :: "https://api.spotify.com/v1/me/player/play"
PAUSE_ADDRESS :: "https://api.spotify.com/v1/me/player/pause"
NEXT_ADDRESS :: "https://api.spotify.com/v1/me/player/next"
PREVIOUS_ADDRESS :: "https://api.spotify.com/v1/me/player/previous"
SEEK_ADDRESS :: "https://api.spotify.com/v1/me/player/seek"
VOLUME_ADDRESS :: "https://api.spotify.com/v1/me/player/volume"
SHUFFLE_ADDRESS :: "https://api.spotify.com/v1/me/player/shuffle"
REPEAT_ADDRESS :: "https://api.spotify.com/v1/me/player/repeat"

// One player command. Seek carries milliseconds, Volume a 0-100 percent,
// Shuffle 1 or 0, Repeat one of track, context or off.
Command :: enum {
	Play,
	Pause,
	Next,
	Previous,
	Seek,
	Volume,
	Shuffle,
	Repeat,
}

// Builds the command address. Rejects out-of-range values instead of
// clamping silently, except volume which the drag already bounds.
command_address :: proc(
	command: Command,
	value: int = 0,
	state: string = "",
	allocator := context.allocator,
) -> (
	address: string,
	ok: bool,
) {
	switch command {
	case .Play:
		return strings.clone(PLAY_ADDRESS, allocator), true
	case .Pause:
		return strings.clone(PAUSE_ADDRESS, allocator), true
	case .Next:
		return strings.clone(NEXT_ADDRESS, allocator), true
	case .Previous:
		return strings.clone(PREVIOUS_ADDRESS, allocator), true
	case .Seek:
		if value < 0 {return "", false}
		return fmt.aprintf("%s?position_ms=%d", SEEK_ADDRESS, value, allocator = allocator), true
	case .Volume:
		if value < 0 || value > 100 {return "", false}
		return fmt.aprintf("%s?volume_percent=%d", VOLUME_ADDRESS, value, allocator = allocator),
			true
	case .Shuffle:
		if value != 0 && value != 1 {return "", false}
		return fmt.aprintf("%s?state=%v", SHUFFLE_ADDRESS, value == 1, allocator = allocator), true
	case .Repeat:
		if state != "track" && state != "context" && state != "off" {return "", false}
		return fmt.aprintf("%s?state=%s", REPEAT_ADDRESS, state, allocator = allocator), true
	}
	return "", false
}

command_method :: proc(command: Command) -> string {
	if command == .Next || command == .Previous {return "POST"}
	return "PUT"
}

// Sends one command at the active device. Fire-and-forget: the answer only
// reaches the diagnostic log, never the UI.
send_command :: proc(
	access: string,
	command: Command,
	value: int = 0,
	state: string = "",
	reuse: rawptr = nil,
) -> (
	status: int,
	ok: bool,
) {
	address, built := command_address(command, value, state, context.temp_allocator)
	if !built {return 0, false}
	code, sent := http.write(command_method(command), address, {bearer = access}, reuse)
	diagnostic.writef("connect command=%v status=%d ok=%v", command, code, sent)
	return code, sent && code == 204
}
