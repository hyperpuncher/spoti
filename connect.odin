#+feature using-stmt
package main

import "core:strings"
import connect "spotify/connect"
import sdl "vendor:sdl3"

// State changes are sent at once. Position-only changes are sent every five
// seconds; the timestamp lets other devices advance their own progress bar.
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
	before, after := connect_snapshot, snapshot
	before.position, after.position = 0, 0
	if before == after && now - connect_published_at < 5_000_000_000 {return}
	if !connect.publish(&connect_client, snapshot) {return}
	delete(connect_snapshot.uri)
	connect_snapshot = snapshot
	connect_snapshot.uri = strings.clone(snapshot.uri)
	connect_published_at = now
}
