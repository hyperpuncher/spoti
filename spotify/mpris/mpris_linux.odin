#+build linux
// MPRIS 2.0 over sd-bus. The vtable and property marshalling live in
// mpris_sd_bus.c; this file owns the command queue and change detection.
package mpris

import "core:strings"

foreign import sd_bus {"../../build/mpris_sd_bus.a", "system:systemd"}

foreign sd_bus {
	spoti_mpris_start :: proc(handler: proc "c" (command: i32, value: i64, userdata: rawptr), userdata: rawptr) -> i32 ---
	spoti_mpris_stop :: proc() ---
	spoti_mpris_poll :: proc() ---
	spoti_mpris_set_track :: proc(title, artist: cstring, duration_us: i64) ---
	spoti_mpris_set_status :: proc(playing, shuffle, repeat, can_seek, can_next, can_previous: i32, volume: f64) ---
	spoti_mpris_set_position :: proc(position_us: i64) ---
	spoti_mpris_changed :: proc() ---
	spoti_mpris_seeked :: proc(position_us: i64) ---
}

MAX_PENDING :: 16

pending_commands: [MAX_PENDING]Command
pending_values: [MAX_PENDING]int
pending_head, pending_tail: int

@(private = "file")
bridge :: proc "c" (command: i32, value: i64, _: rawptr) {
	next := (pending_tail + 1) %% MAX_PENDING
	if next == pending_head {return} 	// queue full; drop the newest command
	pending_commands[pending_tail] = Command(command)
	pending_values[pending_tail] = int(value / 1000) // microseconds to milliseconds
	pending_tail = next
}

start :: proc() -> bool {
	return spoti_mpris_start(bridge, nil) >= 0
}

poll :: proc() -> (command: Command, position_ms: int, ok: bool) {
	spoti_mpris_poll()
	if pending_head == pending_tail {return}
	command = pending_commands[pending_head]
	position_ms = pending_values[pending_head]
	pending_head = (pending_head + 1) %% MAX_PENDING
	return command, position_ms, true
}

@(private = "file")
Status :: struct {
	playing:      bool,
	shuffle:      bool,
	repeat:       bool,
	can_seek:     bool,
	can_next:     bool,
	can_previous: bool,
	volume:       f32,
}

last_title, last_artist: string
last_duration_ms: int
last_status: Status
have_last: bool

update :: proc(now: Now_Playing) {
	track_changed :=
		!have_last ||
		now.title != last_title ||
		now.artist != last_artist ||
		now.duration_ms != last_duration_ms
	if track_changed {
		spoti_mpris_set_track(
			strings.clone_to_cstring(now.title, context.temp_allocator),
			strings.clone_to_cstring(now.artist, context.temp_allocator),
			i64(now.duration_ms) * 1000,
		)
		delete(last_title)
		delete(last_artist)
		last_title = strings.clone(now.title)
		last_artist = strings.clone(now.artist)
		last_duration_ms = now.duration_ms
	}
	status := Status {
		playing      = now.playing,
		shuffle      = now.shuffle,
		repeat       = now.repeat,
		can_seek     = now.can_seek,
		can_next     = now.can_next,
		can_previous = now.can_previous,
		volume       = now.volume,
	}
	status_changed := !have_last || status != last_status
	if status_changed {
		spoti_mpris_set_status(
			flag(now.playing),
			flag(now.shuffle),
			flag(now.repeat),
			flag(now.can_seek),
			flag(now.can_next),
			flag(now.can_previous),
			f64(now.volume),
		)
		last_status = status
	}
	spoti_mpris_set_position(i64(now.position_ms) * 1000)
	if track_changed || status_changed {spoti_mpris_changed()}
	have_last = true
}

seeked :: proc(position_ms: int) {
	spoti_mpris_seeked(i64(position_ms) * 1000)
}

close :: proc() {
	spoti_mpris_stop()
	delete(last_title)
	delete(last_artist)
	last_title, last_artist = "", ""
	have_last = false
}

@(private = "file")
flag :: proc(value: bool) -> i32 {return value ? 1 : 0}
