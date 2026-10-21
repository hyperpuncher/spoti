package main

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import audio "spotify/audio"
import library "spotify/library"
import player "spotify/player"
import session "spotify/session"

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

// Menus retain only a URI. Resolve against current owned data at activation,
// so navigation or a page replacement cannot leave a borrowed track dangling.
app_enqueue_uri :: proc(app: ^App, uri: string) -> bool {
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

// Row, menu, and hero playback share queue ownership and shuffle selection.
app_queue_detail :: proc(app: ^App, index: int) -> bool {
	queue_detail_rows(&app.play_queue, &app.library_client.detail)
	app.queue_rows = len(app.library_client.detail.rows)
	stamp_play_queue(&app.queue_detail, &app.queue_gen, app.library_client.detail)
	app.play_index = app.shuffle ? reorder_play_queue(app.play_queue[:], index, true) : index
	return select_play_item(app.play_queue[:], app.play_index, &app.selected, &app.player_cover)
}

// The footer's single artist link: the first artist with a page. Search
// queues carry one link; detail rows carry them all.
// Idempotent, so paged-in tails stamp just their new rows.
stamp_queue_album :: proc(items: ^[dynamic]Play_Item, detail: ^library.Detail) {
	if detail.source != .Album || len(detail.id) == 0 {return}
	// Temp-scoped: only read while stamping, the queue keeps heap clones.
	uri := fmt.aprintf("spotify:album:%s", detail.id, allocator = context.temp_allocator)
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

// Accessed only by the decode worker; main clears it after joining that worker.
Play_Source :: struct {
	track:  string,
	source: session.Source,
	media:  audio.Seek_Stream,
}

clear_play_source :: proc(cache: ^Play_Source) {
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
		url     = source.url,
		key     = source.key,
		file_id = source.file_id,
		cancel  = &work.cancel,
	}
	defer audio.close_seek_stream(&media)
	if !audio.open_seek_stream(&media) {return}
	// Prime the headers, tail/granules and first playable PCM block. Ciphertext
	// persists in the disk cache; no full PCM track is kept in memory.
	pcm := make([]i16, player.BUFFER_FRAMES * 2)
	defer delete(pcm)
	_, _ = audio.read_seek_pcm(&media, pcm)
}

Login_Work :: struct {
	queue:     chan.Chan(player.Packet),
	cancel:    ^bool,
	track_url: string, // owned by the worker
	start_ms:  int,
	source:    ^Play_Source,
	preloaded: session.Source, // owned, transferred only after joining the preload worker
}

login_and_decode :: proc(pointer: rawptr) {
	work := (^Login_Work)(pointer)
	defer delete(work.track_url)
	defer session.close_source(&work.preloaded)
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
			fresh, authorized = session.open(.Remember, work.cancel, work.track_url, &unavailable)
		}
		if !authorized {
			if !sync.atomic_load(
				work.cancel,
			) {_ = chan.send(work.queue, player.Packet{kind = unavailable ? .Unavailable : .Failed})}
			return
		}
		work.source.track = strings.clone(work.track_url)
		work.source.source = fresh
		source = &work.source.source
	}
	if sync.atomic_load(work.cancel) {return}
	name := strings.clone(source.name)
	if !chan.send(
		work.queue,
		player.Packet{kind = .Ready, name = name, duration_ms = source.duration_ms},
	) {
		delete(name)
		return
	}
	media := &work.source.media
	media.url, media.key, media.file_id = source.url, source.key, source.file_id
	media.cancel = work.cancel
	decode := player.Work {
		media    = media,
		queue    = work.queue,
		cancel   = work.cancel,
		start_ms = work.start_ms,
	}
	if !player.decode(&decode) && !sync.atomic_load(work.cancel) {
		// A failed/expired CDN source must be resolved afresh on the next attempt.
		clear_play_source(work.source)
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
