package main

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import diagnostic "diagnostic"
import audio "spotify/audio"
import library "spotify/library"
import player "spotify/player"
import session "spotify/session"
import sdl "vendor:sdl3"

PREVIOUS_RESTART_MS :: 3000

Stage :: enum {
	Idle,
	Signing_In,
	Buffering,
	Playing,
	Paused,
	Ended,
	Failed,
	Stopping,
}

Play_Item :: struct {
	uri:          string,
	name:         string,
	duration_ms:  int,
	artist:       string, // joined display names
	artist_links: []library.Artist_Link, // owned, in display order
	album:        string,
	album_uri:    string,
	cover:        string,
	order:        int,
	queued:       bool, // added manually; not a row from the playing collection
}

free_play_item :: proc(item: Play_Item) {
	delete(item.uri)
	delete(item.name)
	delete(item.artist)
	for link in item.artist_links {
		delete(link.name)
		delete(link.uri)
	}
	delete(item.artist_links)
	delete(item.album)
	delete(item.album_uri)
	delete(item.cover)
}

free_play_queue :: proc(items: ^[dynamic]Play_Item) {
	for item in items^ {free_play_item(item)}
	delete(items^)
	items^ = nil
}

// Drop all occurrences, preserving order and selecting the following item.
// A run of unavailable tracks shrinks the queue instead of retrying forever.
discard_play_track :: proc(
	items: ^[dynamic]Play_Item,
	uri: string,
	index: ^int,
	context_rows: ^int = nil,
) -> bool {
	next := index^
	kept := 0
	for item, at in items^ {
		if item.uri == uri {
			if context_rows != nil && !item.queued {context_rows^ = max(0, context_rows^ - 1)}
			if at < index^ {next -= 1}
			free_play_item(item)
		} else {
			items^[kept] = item
			kept += 1
		}
	}
	resize(items, kept)
	index^ = next < kept && next >= 0 ? next : -1
	return index^ >= 0
}

clone_play_item :: proc(item: $T, order: int, fallback_cover: string = "") -> Play_Item {
	row: library.Track_Row
	when T == library.Entry {
		first: [1]library.Artist_Link
		row = {
			uri         = item.uri,
			name        = item.name,
			artists     = item.subtitle,
			album       = item.album,
			album_uri   = item.album_uri,
			image       = item.image,
			duration_ms = item.duration_ms,
		}
		if item.first_artist != "" || item.artist_uri != "" {
			first[0] = {
				name = item.first_artist,
				uri  = item.artist_uri,
			}
			row.artist_links = first[:]
		}
	} else when T == Play_Item {
		row = {
			uri          = item.uri,
			name         = item.name,
			artists      = item.artist,
			artist_links = item.artist_links,
			album        = item.album,
			album_uri    = item.album_uri,
			image_small  = item.cover,
			duration_ms  = item.duration_ms,
		}
	} else {row = item}
	cover := row.image_small != "" ? row.image_small : row.image != "" ? row.image : fallback_cover
	return {
		uri = strings.clone(row.uri),
		name = strings.clone(row.name),
		duration_ms = row.duration_ms,
		artist = strings.clone(row.artists),
		artist_links = library.clone_artist_links(row.artist_links),
		album = strings.clone(row.album),
		album_uri = strings.clone(row.album_uri),
		cover = strings.clone(cover),
		order = order,
	}
}

build_play_queue :: proc(items: ^[dynamic]Play_Item, rows: []$T, fallback_cover: string = "") {
	free_play_queue(items)
	items^ = make([dynamic]Play_Item, 0, len(rows))
	for item, index in rows {append(items, clone_play_item(item, index, fallback_cover))}
}

// Manual additions remain FIFO immediately after the current track. Keep
// stable ordinals so turning shuffle off restores this requested position.
// Takes ownership of the item strings; the caller must not free them.
app_enqueue_items :: proc(app: ^App, items: []Play_Item) {
	if len(items) == 0 {return}
	at := clamp(app.play_index + 1, 0, len(app.play_queue))
	for at < len(app.play_queue) && app.play_queue[at].queued {at += 1}
	base := at > 0 ? app.play_queue[at - 1].order + 1 : 0
	for &existing in app.play_queue {if existing.order >= base {existing.order += len(items)}}
	for &item, index in items {
		item.queued = true
		item.order = base + index
	}
	inject_at(&app.play_queue, at, ..items)
	if app.worker == nil &&
	   (app.selected == "" ||
			   app.play_index < 0 ||
			   app.play_index >= len(app.play_queue)) {app_finish_queue(app)}
	app.state_dirty, app.pending_redraw = true, true
	show_toast(app, "Added to queue")
}

app_enqueue_track :: proc(app: ^App, row: $T) {
	if row.uri == "" {return}
	items := [1]Play_Item{clone_play_item(row, 0)}
	app_enqueue_items(app, items[:])
}

// Add every loaded track from a release page as one FIFO run. The detail
// supplies album links that bare album track objects omit.
app_enqueue_detail_rows :: proc(app: ^App, detail: ^library.Detail) {
	items := make([dynamic]Play_Item, 0, len(detail.rows), context.temp_allocator)
	for row in detail.rows {
		if row.uri == "" {continue}
		append(&items, clone_play_item(row, 0, detail.image_small))
	}
	stamp_queue_album(&items, detail)
	app_enqueue_items(app, items[:])
}

footer_duration :: proc(app: ^App) -> int {
	return app.remote_control ? app.library_client.remote.duration : app.duration_ms
}

footer_cover :: proc(app: ^App) -> string {
	return app.remote_control ? app.library_client.remote.cover : app.player_cover
}

footer_active_device :: proc(app: ^App) -> string {
	if app_connect_active(app) {return app.app_state.connect_device}
	if app.remote_control {return app.library_client.remote.device_id}
	for device in app.library_client.devices {if device.active {return device.id}}
	return ""
}

app_probe_remote :: proc(app: ^App) {
	app.remote_polled_at = sdl.GetTicksNS()
	_ = library.refresh_player_state(&app.library_client)
}

app_library_result :: proc(result: ^library.Result, user_data: rawptr) {
	app := (^App)(user_data)
	#partial switch result.kind {
	case .Transfer:
		if !result.ok {show_toast(app, "Couldn't transfer playback"); return}
		show_toast(app, "Playback transferred")
		// A transfer here will arrive as a native Load command.
		if result.device_id == app.app_state.connect_device {return}
		if app.preload_worker != nil {sync.atomic_store(&app.preload_work.cancel, true)}
		app.play_after_stop, app.replay_pending = false, false
		app.seek_dragging, app.start_paused = false, false
		app.seek_ms = 0
		if app.worker != nil && app.stage != .Stopping {app_stop_audio(app)}
		app.remote_control = true
		app_probe_remote(app)
		_ = library.refresh_devices(&app.library_client)
	case .Player_State:
		if result.ok {
			// An older poll must not override playback that just started locally.
			leaving := app.stage == .Stopping && !app.play_after_stop
			if app.remote_control || app.worker == nil || leaving {
				device := result.player
				app.remote_control =
					device.device_id != "" &&
					device.device_id != app.app_state.connect_device &&
					!device.restricted
			}
		} else if result.status == 204 {
			app.remote_control = false
		}
	case .Queue_Album:
		if result.ok && len(result.detail.rows) > 0 {
			app_enqueue_detail_rows(app, &result.detail)
		} else {
			show_toast(app, "Couldn't add to queue")
		}
	}
}

// Menus retain only a URI. Resolve against current owned data at activation,
// so navigation or a page replacement cannot leave a borrowed track dangling.
app_enqueue_uri :: proc(app: ^App, uri: string) -> bool {
	if strings.has_prefix(
		uri,
		"spotify:album:",
	) {return library.queue_album(&app.library_client, uri)}
	for source_row in app.library_client.detail.rows {
		if source_row.uri != uri {continue}
		row := source_row
		if app.library_client.detail.source == .Album {
			row.album = app.library_client.detail.name
			row.album_uri = detail_card_uri(app.library_client.detail)
			if row.image == "" &&
			   row.image_small == "" {row.image_small = app.library_client.detail.image_small}
		}
		app_enqueue_track(app, row)
		return true
	}
	for page in ([]^library.Page{&app.library_client.search_pages[.Tracks], &app.library_client.pages[.Tracks]}) {
		for entry in page.items {
			if entry.uri != uri {continue}
			app_enqueue_track(app, entry)
			return true
		}
	}
	for item in app.play_queue {
		if item.uri != uri {continue}
		app_enqueue_track(app, item)
		return true
	}
	return false
}

app_restore_play_queue :: proc(app: ^App) {
	played := &app.app_state.last_played
	app.shuffle = played.shuffle
	if played.queue_index < 0 || played.queue_index >= len(played.queue) {return}
	if played.queue[played.queue_index].uri != played.track {return}
	free_play_queue(&app.play_queue)
	app.play_queue, played.queue = played.queue, nil
	app.play_index = played.queue_index
	app.queue_rows = 0
	for item in app.play_queue {if !item.queued {app.queue_rows += 1}}
	replace_string(&app.queue_detail, played.collection)
	app.queue_restore_pending = played.collection != ""
}

// Builds the queue from the open detail. Album track objects carry no album
// block, so those rows would leave the footer title unlinked; stamp them
// from the open page while it is in scope.
queue_detail_rows :: proc(items: ^[dynamic]Play_Item, detail: ^library.Detail) {
	build_play_queue(items, detail.rows[:], detail.image_small)
	stamp_queue_album(items, detail)
}

// Connect supplies track IDs, not display metadata. Reuse only exact matches.
load_connect_queue :: proc(app: ^App, uris: []string) {
	old := app.play_queue
	defer free_play_queue(&old)
	app.play_queue = make([dynamic]Play_Item, 0, len(uris))
	detail, remote := &app.library_client.detail, &app.library_client.remote
	fallback_cover := detail.image_small != "" ? detail.image_small : detail.image
	tracks: for uri, index in uris {
		for item in old {
			if item.uri != uri || item.cover == "" {continue}
			append(&app.play_queue, clone_play_item(item, index))
			continue tracks
		}
		row := library.Track_Row {
			uri = uri,
		}
		cover := ""
		if uri == remote.uri {
			row.name, row.artists, row.image, row.duration_ms =
				remote.title, remote.artist, remote.cover, remote.duration
		}
		for candidate in detail.rows {
			if candidate.uri != uri {continue}
			row = candidate
			if detail.source == .Album {
				row.album = detail.name
				row.album_uri = library.library_uri(.Album, detail.id, context.temp_allocator)
				cover = fallback_cover
			}
			break
		}
		append(&app.play_queue, clone_play_item(row, index, cover))
	}
}

// Row, menu, and hero playback share queue ownership and shuffle selection.
app_queue_detail :: proc(app: ^App, index: int) -> bool {
	queue_detail_rows(&app.play_queue, &app.library_client.detail)
	app.queue_rows = len(app.library_client.detail.rows)
	stamp_play_queue(&app.queue_detail, &app.queue_gen, app.library_client.detail)
	if app.library_client.detail.source == .Radio {app.shuffle = false}
	app.play_index = app.shuffle ? reorder_play_queue(app.play_queue[:], index, true) : index
	return select_play_item(app.play_queue[:], app.play_index, &app.selected, &app.player_cover)
}

// The footer's single artist link: the first artist with a page. Search
// queues carry one link; detail rows carry them all.
// Idempotent, so paged-in tails stamp just their new rows.
stamp_queue_album :: proc(items: ^[dynamic]Play_Item, detail: ^library.Detail) {
	if detail.source != .Album || len(detail.id) == 0 {return}
	// Temp-scoped: only read while stamping, the queue keeps heap clones.
	uri := fmt.tprintf("spotify:album:%s", detail.id)
	for &item in items {
		if item.queued || len(item.album_uri) > 0 {continue}
		item.album_uri = strings.clone(uri)
		item.album = strings.clone(detail.name)
	}
}

// The live queue mirrors a detail page; later pages extend it in place.
stamp_play_queue :: proc(queue_uri: ^string, generation: ^uint, detail: library.Detail) {
	replace_string(queue_uri, detail_card_uri(detail))
	generation^ = detail.generation
}

// A playing detail keeps paging in after playback starts. Rows only ever
// append, so the live queue grows in place and the current index holds.
append_play_queue_tail :: proc(
	items: ^[dynamic]Play_Item,
	rows: []library.Track_Row,
	fallback_cover: string = "",
) {
	next_order := 0
	for item in items^ {next_order = max(next_order, item.order + 1)}
	for row in rows {
		append(items, clone_play_item(row, next_order, fallback_cover))
		next_order += 1
	}
}

// Stable ordinals distinguish repeated tracks and restore the original order.
reorder_play_queue :: proc(items: []Play_Item, index: int, shuffle: bool) -> int {
	if index < 0 || index >= len(items) {return index}
	current := items[index].order
	if shuffle {
		// The temporary copy borrows metadata; the queue keeps ownership.
		ordered := make([]Play_Item, len(items), context.temp_allocator)
		ordered[0] = items[index]
		next := 1
		for at in index + 1 ..< len(items) {
			if !items[at].queued {continue}
			ordered[next] = items[at]
			next += 1
		}
		first_shuffled := next
		for item, at in items {
			if at == index || at > index && item.queued {continue}
			ordered[next] = item
			next += 1
		}
		rand.shuffle(ordered[first_shuffled:])
		copy(items, ordered)
		return 0
	}
	slice.sort_by(items, proc(a, b: Play_Item) -> bool {return a.order < b.order})
	for item, i in items {if item.order == current {return i}}
	return index
}

select_play_item :: proc(items: []Play_Item, index: int, selected, cover: ^string) -> bool {
	if index < 0 || index >= len(items) {return false}
	replace_string(selected, items[index].uri)
	replace_string(cover, items[index].cover)
	return true
}

advance_play_item :: proc(
	items: []Play_Item,
	index: ^int,
	delta: int,
	selected, cover: ^string,
) -> bool {
	select_play_item(items, index^ + delta, selected, cover) or_return
	index^ += delta
	return true
}

// End-of-queue and Next past its last track share one stopped reset.
// Keep metadata in the queue so this needs no decode or network request.
app_finish_queue :: proc(app: ^App) {
	if app.preload_worker != nil {sync.atomic_store(&app.preload_work.cancel, true)}
	if app.worker != nil {cancel_worker(app.queue, &app.cancel)}
	clear_audio_stream(&app.stream)
	app.stage = app.worker != nil ? .Stopping : .Idle
	app.finished, app.play_after_stop, app.replay_pending = false, false, false
	app.seek_dragging, app.start_paused = false, false
	app.seek_ms, app.displayed_ms = 0, 0
	if select_play_item(app.play_queue[:], 0, &app.selected, &app.player_cover) {
		app.play_index = 0
		first := app.play_queue[0]
		replace_string(&app.title, first.name)
		replace_string(&app.artist, first.artist)
		app.duration_ms = first.duration_ms
	}
	app.state_dirty = true
	app.pending_redraw = true
}

// The track that plays after the current one, using the same rules as a
// track ending: repeat-one, then the next queue item, then the start of a
// repeated context. -1 means playback stops.
next_play_index :: proc(app: ^App) -> int {
	if app.play_index < 0 || app.play_index >= len(app.play_queue) {return -1}
	if app.repeat {return app.play_index}
	if app.play_index + 1 < len(app.play_queue) {return app.play_index + 1}
	if app.connect_repeat_context {return 0}
	return -1
}

// Keep the worker's next-track offer current. Queue edits, shuffle and
// repeat changes all flow through here before the worker takes the offer.
app_offer_next_track :: proc(app: ^App) {
	if app.worker == nil || app.stage == .Stopping || app.stage == .Failed {return}
	// Once the worker holds the next track, the following one is offered at
	// the boundary, when the queue position moves.
	if app.upcoming.active {return}
	next := next_play_index(app)
	if next < 0 {offer_next_track(&app.next_track, "", app.tracks_started, nil); return}
	uri := app.play_queue[next].uri
	preloaded: ^session.Source
	if app.preload_worker == nil &&
	   app.preload_work.track == uri &&
	   app.preload_work.source.url != "" {
		preloaded = &app.preload_work.source
	}
	offer_next_track(&app.next_track, uri, app.tracks_started, preloaded)
}

REMOTE_VOLUME_NS :: 150_000_000

// Send the newest remote volume at most once per REMOTE_VOLUME_NS. A value
// that must wait keeps remote_volume_pending; the event wait wakes for it.
app_send_remote_volume :: proc(app: ^App) {
	if !app.remote_volume_pending {return}
	if !app.remote_control {app.remote_volume_pending = false; return}
	now := sdl.GetTicksNS()
	if now < app.remote_volume_at {return}
	_ = library.send_player_command(&app.library_client, .Volume, int(app.volume * 100 + 0.5))
	app.remote_volume_pending = false
	app.remote_volume_at = now + REMOTE_VOLUME_NS
}

// The slider position is what the user, Connect and MPRIS see; loudness is
// perceived logarithmically, so the stream gain follows a cubic curve.
// Halfway sounds about half as loud instead of nearly full.
volume_gain :: proc(volume: f32) -> f32 {return volume * volume * volume}

clear_upcoming :: proc(app: ^App) {
	delete(app.upcoming.name)
	delete(app.upcoming.uri)
	app.upcoming = {}
}

// Switch the footer, queue position and progress origin when playback
// reaches the first sample of a gaplessly queued track. If the queue changed
// after the worker took its offer, the queued audio is the wrong track: stop
// and start the right one, which keeps a short gap only in that case.
app_gapless_boundary :: proc(app: ^App) {
	if !app.upcoming.active || app.upcoming.pending || app.stream == nil {return}
	queued := max(0, int(sdl.GetAudioStreamQueued(app.stream)))
	if app.sent_frames - queued / 4 < app.upcoming.boundary_frames {return}
	index := next_play_index(app)
	if index < 0 || app.play_queue[index].uri != app.upcoming.uri {
		diagnostic.write("playback gapless track no longer next; restarting")
		clear_upcoming(app)
		if index < 0 {app_finish_queue(app); return}
		app.play_index = index
		_ = select_play_item(app.play_queue[:], index, &app.selected, &app.player_cover)
		app.seek_ms, app.start_paused = 0, false
		app_stop_audio(app)
		app.play_after_stop = true
		return
	}
	app.play_index = index
	_ = select_play_item(app.play_queue[:], index, &app.selected, &app.player_cover)
	item := &app.play_queue[index]
	replace_string(&item.name, app.upcoming.name)
	item.duration_ms = app.upcoming.duration_ms
	replace_string(&app.title, app.upcoming.name)
	replace_string(&app.artist, item.artist)
	app.duration_ms = app.upcoming.duration_ms
	app.origin_frames = app.upcoming.boundary_frames - app.upcoming.base_frames
	app.displayed_ms = 0
	clear_upcoming(app)
	app.state_dirty, app.pending_redraw = true, true
}

// Accessed only by the decode worker; main clears it after joining that worker.
Play_Source :: struct {
	track:  string,
	source: session.Source,
	media:  audio.Seek_Stream,
	fetch:  audio.Fetch, // downloads the rest of the track into the disk cache
}

clear_play_source :: proc(cache: ^Play_Source) {
	audio.stop_fetch(&cache.fetch)
	audio.close_seek_stream(&cache.media)
	session.close_source(&cache.source)
	delete(cache.track)
	cache^ = {}
}

cached_play_source :: proc(cache: ^Play_Source, uri: string) -> ^session.Source {
	if cache.track == uri && cache.source.url != "" {return &cache.source}
	return nil
}

Preload_Work :: struct {
	track:  string,
	source: session.Source,
	cancel: bool,
}

clear_preload :: proc(preload: ^Preload_Work) {
	session.close_source(&preload.source)
	delete(preload.track)
	preload^ = {}
}

preload_track :: proc(pointer: rawptr) {
	work := (^Preload_Work)(pointer)
	source, ok := session.open(.Remember, &work.cancel, work.track)
	if !ok {return}
	work.source = source
	if sync.atomic_load(&work.cancel) {return}
	media := audio.Seek_Stream {
		url         = source.url,
		key         = source.key,
		file_id     = source.file_id,
		duration_ms = source.duration_ms,
		cancel      = &work.cancel,
	}
	defer audio.close_seek_stream(&media)
	if !audio.open_seek_stream(&media) {return}
	// Prime the headers, tail/granules and first playable PCM block. Ciphertext
	// persists in the disk cache; no full PCM track is kept in memory.
	pcm := make([]i16, player.BUFFER_FRAMES * 2)
	defer delete(pcm)
	_, _ = audio.read_seek_pcm(&media, pcm)
}

// The main thread offers the track that follows the one being decoded.
// The worker takes it when its current track ends, so the next track's
// audio follows in the same stream with no gap. An offer names the track
// count it follows, so an offer made before main sees the worker's latest
// Ready packet is ignored instead of replaying a track.
Next_Track :: struct {
	mutex:     sync.Mutex,
	uri:       string, // owned; "" means the queue ends after this track
	preloaded: session.Source, // owned; a resolved source for uri, if any
	after:     int, // the offer follows the worker's track number `after`
}

// Replace the offer with uri, or "" to end after the current track. A
// preloaded source for the same uri is attached when it becomes available.
offer_next_track :: proc(next: ^Next_Track, uri: string, after: int, preloaded: ^session.Source) {
	sync.mutex_guard(&next.mutex)
	if next.uri != uri || next.after != after {
		delete(next.uri)
		session.close_source(&next.preloaded)
		next.uri = strings.clone(uri)
		next.after = after
	}
	if uri != "" && preloaded != nil && next.preloaded.url == "" {
		next.preloaded, preloaded^ = preloaded^, {}
	}
}

clear_next_track :: proc(next: ^Next_Track) {
	sync.mutex_guard(&next.mutex)
	delete(next.uri)
	session.close_source(&next.preloaded)
	next^ = {}
}

@(private = "file")
take_next_track :: proc(
	next: ^Next_Track,
	started: int,
) -> (
	uri: string,
	preloaded: session.Source,
) {
	sync.mutex_guard(&next.mutex)
	if next.uri == "" || next.after != started {return}
	uri, preloaded = next.uri, next.preloaded
	next.uri, next.preloaded = "", {}
	return
}

Login_Work :: struct {
	queue:     chan.Chan(player.Packet),
	cancel:    ^bool,
	track_url: string, // owned by the worker
	start_ms:  int,
	source:    ^Play_Source,
	preloaded: session.Source, // owned, transferred only after joining the preload worker
	next:      ^Next_Track, // optional; continues gaplessly into the offered track
	open:      type_of(session.open), // nil uses session.open; tests replace the network
	cache:     string, // tests use a private audio cache directory
}

// Decode the requested track, then each offered next track, into one packet
// stream. Every track starts with a Ready packet; End follows the last one.
login_and_decode :: proc(pointer: rawptr) {
	work := (^Login_Work)(pointer)
	defer delete(work.track_url)
	defer session.close_source(&work.preloaded)
	start_ms := work.start_ms
	for started := 1;; started += 1 {
		if !decode_track(work, start_ms) {return}
		if work.next == nil {break}
		uri, preloaded := take_next_track(work.next, started)
		if uri == "" {break}
		delete(work.track_url)
		session.close_source(&work.preloaded)
		work.track_url, work.preloaded = uri, preloaded
		start_ms = 0
	}
	if !sync.atomic_load(work.cancel) {_ = chan.send(work.queue, player.Packet{kind = .End})}
}

@(private = "file")
decode_track :: proc(work: ^Login_Work, start_ms: int) -> bool {
	source := cached_play_source(work.source, work.track_url)
	if source == nil {
		clear_play_source(work.source)
		fresh: session.Source
		authorized := false
		unavailable := false
		if work.preloaded.url != "" {
			fresh = work.preloaded
			work.preloaded = {}
			authorized = true
		} else {
			open := work.open != nil ? work.open : session.open
			fresh, authorized = open(.Remember, work.cancel, work.track_url, &unavailable)
		}
		if !authorized {
			if !sync.atomic_load(
				work.cancel,
			) {_ = chan.send(work.queue, player.Packet{kind = unavailable ? .Unavailable : .Failed})}
			return false
		}
		work.source.track = strings.clone(work.track_url)
		work.source.source = fresh
		source = &work.source.source
	}
	if sync.atomic_load(work.cancel) {return false}
	ready := player.Packet {
		kind        = .Ready,
		name        = strings.clone(source.name),
		uri         = strings.clone(work.track_url),
		duration_ms = source.duration_ms,
	}
	if !chan.send(work.queue, ready) {
		delete(ready.name)
		delete(ready.uri)
		return false
	}
	media := &work.source.media
	media.url, media.key, media.file_id = source.url, source.key, source.file_id
	media.duration_ms, media.cancel = source.duration_ms, work.cancel
	if work.cache != "" &&
	   media.disk.path == "" {media.disk = audio.open_disk_cache(media.file_id, work.cache)}
	decode := player.Work {
		media    = media,
		queue    = work.queue,
		cancel   = work.cancel,
		start_ms = start_ms,
		on_open  = work.cache == "" ? start_track_fetch : nil,
		user     = &work.source.fetch,
	}
	if player.decode(&decode) {return true}
	// A failed/expired CDN source must be resolved afresh on the next attempt.
	if !sync.atomic_load(work.cancel) {clear_play_source(work.source)}
	return false
}

// Runs on the decode worker once the file size is known. One fetcher per
// source; a seek or replay of the same track keeps the running one.
start_track_fetch :: proc(media: ^audio.Seek_Stream, user: rawptr) {
	fetch := (^audio.Fetch)(user)
	if fetch.thread != nil {return}
	if audio.start_fetch(fetch, media.url, media.file_id, media.size, media.cache_offset) {
		media.fetch = fetch
	}
}

cancel_worker :: proc(queue: chan.Chan(player.Packet), cancel: ^bool) {
	sync.atomic_store(cancel, true)
	chan.close(queue)
}

release_worker :: proc(worker: ^thread.Thread, queue: chan.Chan(player.Packet), cancel: ^bool) {
	cancel_worker(queue, cancel)
	thread.destroy(worker)
	for packet in chan.try_recv(queue) {
		delete(packet.pcm)
		delete(packet.name)
		delete(packet.uri)
	}
	chan.destroy(queue)
}

seek_position_ms :: proc(x, left, width: f32, duration_ms: int) -> int {
	if width <= 0 || duration_ms <= 0 {return 0}
	return min(duration_ms - 1, int(clamp((x - left) / width, 0, 1) * f32(duration_ms)))
}

duration_text :: proc(duration_ms: int, buffer: []u8) -> string {
	seconds := max(0, duration_ms) / 1000
	return fmt.bprintf(buffer, "%d:%02d", seconds / 60, seconds % 60)
}

duration_text_alloc :: proc(duration_ms: int) -> string {
	buffer: [32]u8
	return strings.clone(duration_text(duration_ms, buffer[:]), context.temp_allocator)
}
