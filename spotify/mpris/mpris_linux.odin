#+build linux
// MPRIS 2.0 over sd-bus. The vtable and marshalling live in mpris_sd_bus.c;
// this file owns the worker thread, change detection and the command queue.
package mpris

import "core:strings"
import "core:sync"
import "core:thread"

foreign import sd_bus {"../../build/mpris_sd_bus.a", "system:systemd"}

foreign sd_bus {
	spoti_mpris_start :: proc() -> i32 ---
	spoti_mpris_set_wake :: proc(wake: proc "c" (userdata: rawptr), userdata: rawptr) ---
	spoti_mpris_stop :: proc() ---
	spoti_mpris_service :: proc() ---
	spoti_mpris_wait :: proc(timeout_us: i64) -> i32 ---
	spoti_mpris_take_command :: proc(command: ^i32, value: ^i64) -> i32 ---
	spoti_mpris_set_track :: proc(title, artist: cstring, duration_us: i64) ---
	spoti_mpris_set_status :: proc(playing, shuffle, repeat, can_seek, can_next, can_previous: i32, volume: f64) ---
	spoti_mpris_set_position :: proc(position_us: i64) ---
	spoti_mpris_seeked :: proc(position_us: i64) ---
}

worker: ^thread.Thread
quit: bool

// sd-bus messages arrive on the bus fd, which SDL does not watch. This thread
// services them and the C handler wakes the UI through the SDL event.
@(private = "file")
service :: proc() {
	for !sync.atomic_load(&quit) {
		spoti_mpris_service()
		spoti_mpris_wait(100_000)
	}
}

start :: proc(wake: Wake) -> bool {
	if spoti_mpris_start() < 0 {return false}
	if wake != nil {spoti_mpris_set_wake(wake, nil)}
	sync.atomic_store(&quit, false)
	worker = thread.create_and_start(service)
	return worker != nil
}

poll :: proc() -> (command: Command, position_ms: int, ok: bool) {
	numeric_command: i32
	numeric_value: i64
	if spoti_mpris_take_command(&numeric_command, &numeric_value) == 0 {return}
	return Command(numeric_command), int(numeric_value / 1000), true
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
	have_last = true
}

seeked :: proc(position_ms: int) {
	spoti_mpris_seeked(i64(position_ms) * 1000)
}

close :: proc() {
	sync.atomic_store(&quit, true)
	if worker != nil {
		thread.join(worker)
		thread.destroy(worker)
		worker = nil
	}
	spoti_mpris_stop()
	delete(last_title)
	delete(last_artist)
	last_title, last_artist = "", ""
	have_last = false
}

@(private = "file")
flag :: proc(value: bool) -> i32 {return value ? 1 : 0}
