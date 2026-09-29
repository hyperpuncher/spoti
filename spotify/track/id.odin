package track

import "core:fmt"
import "core:strings"

// Spotify track IDs are 22 base-62 digits encoding a 128-bit identifier.
// Accept the URL the user supplied or its equivalent spotify:track: URI.
parse_id :: proc(input: string) -> (raw: [16]u8, ok: bool) {
	id := input
	if strings.has_prefix(input, "https://open.spotify.com/track/") {
		id = input[len("https://open.spotify.com/track/"):]
	} else if strings.has_prefix(input, "spotify:track:") {
		id = input[len("spotify:track:"):]
	}
	if question := strings.index_byte(id, '?'); question != -1 {id = id[:question]}
	if len(id) != 22 {return {}, false}
	value: u128
	for ch in transmute([]u8)id {
		digit: u128
		switch {
		case ch >= '0' && ch <= '9':
			digit = u128(ch - '0')
		case ch >= 'a' && ch <= 'z':
			digit = u128(ch - 'a') + 10
		case ch >= 'A' && ch <= 'Z':
			digit = u128(ch - 'A') + 36
		case:
			return {}, false
		}
		if value > (max(u128) - digit) / 62 {return {}, false}
		value = value * 62 + digit
	}
	for i in 0 ..< 16 {raw[i] = u8(value >> u128(8 * (15 - i)))}
	return raw, true
}

hex_id :: proc(id: [16]u8) -> string {
	value: u128
	for b in id {value = value << 8 | u128(b)}
	return fmt.aprintf("%032x", value)
}
