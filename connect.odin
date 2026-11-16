#+feature using-stmt
package main

import "core:hash"
import "core:strings"
import connect "spotify/connect"
import sdl "vendor:sdl3"

connect_queue_revision :: proc(items: []Play_Item) -> u64 {
	revision: u64 = 14695981039346656037
	for item in items {
		revision = hash.fnv64a(transmute([]u8)item.uri, revision)
		revision = hash.fnv64a([]u8{0xff}, revision)
	}
	return revision
}

connect_state_equal :: proc(a, b: connect.Snapshot) -> bool {
	return(
		a.uri == b.uri &&
		a.context_uri == b.context_uri &&
		a.index == b.index &&
		a.queue_revision == b.queue_revision &&
		a.duration == b.duration &&
		a.active == b.active &&
		a.playing == b.playing &&
		a.paused == b.paused &&
		a.buffering == b.buffering &&
		a.volume == b.volume &&
		a.shuffle == b.shuffle &&
		a.repeat_context == b.repeat_context &&
		a.repeat_track == b.repeat_track \
	)
}

// Send state only when it changes, as librespot does. Each state carries a
// position and a timestamp, so other devices advance their own progress bar.
// A position that leaves that extrapolation (a seek) is a change too.
CONNECT_POSITION_DRIFT_MS :: 1500
// A track start passes buffering, metadata and playing within ~200 ms.
// A change waits until the state holds still this long, then sends once.
CONNECT_SETTLE_NS :: u64(250_000_000)

// Identity of a candidate state, so a settle window restarts on any change.
connect_state_key :: proc(s: connect.Snapshot) -> u64 {
	key := hash.fnv64a(transmute([]u8)s.uri)
	key = hash.fnv64a(transmute([]u8)s.context_uri, key)
	flags := [?]bool {
		s.active,
		s.playing,
		s.paused,
		s.buffering,
		s.shuffle,
		s.repeat_context,
		s.repeat_track,
	}
	key = hash.fnv64a(transmute([]u8)flags[:], key)
	numbers := [?]u64{u64(s.index), s.queue_revision, u64(s.duration), u64(transmute(u32)s.volume)}
	return hash.fnv64a(([^]u8)(&numbers)[:size_of(numbers)], key)
}

app_connect_publish :: proc(app: ^App) {
	using app
	if connect_client.worker == nil {return}
	now := sdl.GetTicksNS()
	active :=
		!remote_control &&
		worker != nil &&
		stage != .Stopping &&
		stage != .Failed &&
		stage != .Idle
	snapshot := connect.Snapshot {
		uri            = active ? selected : "",
		context_uri    = active ? queue_detail : "",
		active         = active,
		position       = displayed_ms,
		duration       = duration_ms,
		playing        = stage == .Playing,
		paused         = stage == .Paused || stage == .Ended,
		buffering      = stage == .Signing_In || stage == .Buffering,
		volume         = volume,
		shuffle        = shuffle,
		repeat_context = connect_repeat_context,
		repeat_track   = repeat,
	}
	queue_window: []Play_Item
	if active && play_index >= 0 && play_index < len(play_queue) {
		first := max(0, play_index - connect.MAX_TRACKS / 2)
		last := min(len(play_queue), first + connect.MAX_TRACKS)
		first = max(0, last - connect.MAX_TRACKS)
		snapshot.index = play_index - first
		queue_window = play_queue[first:last]
		snapshot.queue_revision = connect_queue_revision(queue_window)
	}
	expected := connect_snapshot.position
	if connect_snapshot.playing {
		expected += int((now - connect_published_at) / 1_000_000)
	}
	if connect_state_equal(connect_snapshot, snapshot) &&
	   abs(displayed_ms - expected) <= CONNECT_POSITION_DRIFT_MS {
		connect_settle_at = 0
		return
	}
	if key := connect_state_key(snapshot); key != connect_settle_key || connect_settle_at == 0 {
		connect_settle_key = key
		connect_settle_at = now + CONNECT_SETTLE_NS
	}
	if now < connect_settle_at {return}
	snapshot.tracks = make([dynamic]string, len(queue_window), context.temp_allocator)
	for item, index in queue_window {snapshot.tracks[index] = item.uri}
	if !connect.publish(&connect_client, snapshot) {return}
	connect.free_snapshot(&connect_snapshot)
	connect_snapshot = snapshot
	connect_snapshot.uri = strings.clone(snapshot.uri)
	connect_snapshot.context_uri = strings.clone(snapshot.context_uri)
	connect_snapshot.tracks = nil
	connect_published_at = now
	connect_settle_at = 0
}
