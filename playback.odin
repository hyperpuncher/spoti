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
	artist:       string, // joined display names
	artist_links: []library.Artist_Link, // owned, in display order
	album:        string,
	album_uri:    string,
	cover:        string,
	order:        int,
}

free_play_item :: proc(item: Play_Item) {
	delete(item.uri)
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
discard_play_track :: proc(items: ^[dynamic]Play_Item, uri: string, index: ^int) -> bool {
	next := index^
	kept := 0
	for item, at in items^ {
		if item.uri == uri {
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

append_play_item :: proc(
	items: ^[dynamic]Play_Item,
	row: library.Track_Row,
	order: int,
	fallback_cover: string = "",
) {
	cover := row.image_small != "" ? row.image_small : row.image != "" ? row.image : fallback_cover
	append(
		items,
		Play_Item {
			uri = strings.clone(row.uri),
			artist = strings.clone(row.artists),
			artist_links = library.clone_artist_links(row.artist_links),
			album = strings.clone(row.album),
			album_uri = strings.clone(row.album_uri),
			cover = strings.clone(cover),
			order = order,
		},
	)
}

build_play_queue :: proc(items: ^[dynamic]Play_Item, rows: []$T, fallback_cover: string = "") {
	free_play_queue(items)
	items^ = make([dynamic]Play_Item, 0, len(rows))
	for item, index in rows {
		row: library.Track_Row
		when T == library.Entry {
			first: [1]library.Artist_Link
			row = {
				uri       = item.uri,
				artists   = item.subtitle,
				album     = item.album,
				album_uri = item.album_uri,
				image     = item.image,
			}
			if item.first_artist != "" || item.artist_uri != "" {
				first[0] = {
					name = item.first_artist,
					uri  = item.artist_uri,
				}
				row.artist_links = first[:]
			}
		} else {row = item}
		append_play_item(items, row, index, fallback_cover)
	}
}

app_restore_play_queue :: proc(app: ^App) {
	played := &app.app_state.last_played
	app.shuffle = played.shuffle
	if played.queue_index < 0 || played.queue_index >= len(played.queue) {return}
	if played.queue[played.queue_index].uri != played.track {return}
	free_play_queue(&app.play_queue)
	app.play_queue, played.queue = played.queue, nil
	app.play_index = played.queue_index
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
	stamp_play_queue(&app.queue_detail, &app.queue_gen, app.library_client.detail)
	app.play_index = app.shuffle ? reorder_play_queue(app.play_queue[:], index, true) : index
	return select_play_item(
		app.play_queue[:],
		app.play_index,
		&app.selected,
		&app.player_cover,
		&app.artist,
	)
}

// The footer's single artist link: the first artist with a page. Search
// queues carry one link; detail rows carry them all.
// Idempotent, so paged-in tails stamp just their new rows.
stamp_queue_album :: proc(items: ^[dynamic]Play_Item, detail: ^library.Detail) {
	if detail.source != .Album || len(detail.id) == 0 {return}
	// Temp-scoped: only read while stamping, the queue keeps heap clones.
	uri := fmt.aprintf("spotify:album:%s", detail.id, allocator = context.temp_allocator)
	for &item in items {
		if len(item.album_uri) > 0 {continue}
		item.album_uri = strings.clone(uri)
		item.album = strings.clone(detail.name)
	}
}

// The live queue mirrors a detail page; later pages extend it in place.
stamp_play_queue :: proc(queue_uri: ^string, generation: ^uint, detail: library.Detail) {
	delete(queue_uri^)
	queue_uri^ = strings.clone(detail_card_uri(detail))
	generation^ = detail.generation
}

// A playing detail keeps paging in after playback starts. Rows only ever
// append, so the live queue grows in place and the current index holds.
append_play_queue_tail :: proc(
	items: ^[dynamic]Play_Item,
	rows: []library.Track_Row,
	fallback_cover: string = "",
) {
	for row in rows {append_play_item(items, row, len(items), fallback_cover)}
}

// Stable ordinals distinguish repeated tracks and restore the original order.
reorder_play_queue :: proc(items: []Play_Item, index: int, shuffle: bool) -> int {
	if index < 0 || index >= len(items) {return index}
	current := items[index].order
	if shuffle {
		items[0], items[index] = items[index], items[0]
		rand.shuffle(items[1:])
		return 0
	}
	slice.sort_by(items, proc(a, b: Play_Item) -> bool {return a.order < b.order})
	for item, i in items {if item.order == current {return i}}
	return index
}

select_play_item :: proc(
	items: []Play_Item,
	index: int,
	selected, cover, artist: ^string,
) -> bool {
	if index < 0 || index >= len(items) {return false}
	delete(selected^)
	selected^ = strings.clone(items[index].uri)
	delete(cover^)
	cover^ = strings.clone(items[index].cover)
	delete(artist^)
	artist^ = strings.clone(items[index].artist)
	return true
}

advance_play_item :: proc(
	items: []Play_Item,
	index: ^int,
	delta: int,
	selected, cover, artist: ^string,
) -> bool {
	select_play_item(items, index^ + delta, selected, cover, artist) or_return
	index^ += delta
	return true
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
	seconds := max(0, duration_ms) / 1000
	return fmt.aprintf("%d:%02d", seconds / 60, seconds % 60, allocator = context.temp_allocator)
}
