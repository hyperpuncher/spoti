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

// Deep-copies row links (arena) onto the heap queue; empty stays nil so
// plain text never pays for links.
free_artist_links :: proc(links: []library.Artist_Link) {
	for link in links {
		delete(link.name)
		delete(link.uri)
	}
	delete(links)
}

free_play_queue :: proc(items: ^[dynamic]Play_Item) {
	for item in items^ {
		delete(item.uri)
		delete(item.artist)
		free_artist_links(item.artist_links)
		delete(item.album)
		delete(item.album_uri)
		delete(item.cover)
	}
	delete(items^)
	items^ = nil
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

build_play_queue :: proc(
	items: ^[dynamic]Play_Item,
	rows: []library.Track_Row,
	fallback_cover: string = "",
) {
	free_play_queue(items)
	items^ = make([dynamic]Play_Item, 0, len(rows))
	for row, index in rows {append_play_item(items, row, index, fallback_cover)}
}

// Builds the queue from the open detail. Album track objects carry no album
// block, so those rows would leave the footer title unlinked; stamp them
// from the open page while it is in scope.
queue_detail_rows :: proc(items: ^[dynamic]Play_Item, detail: ^library.Detail) {
	build_play_queue(items, detail.rows[:], detail.image_small)
	stamp_queue_album(items, detail)
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

// Search tracks arrive as cards, not detail rows. The subtitle carries the
// artists and the image carries the cover, so a queue builds directly.
build_play_queue_from_entries :: proc(items: ^[dynamic]Play_Item, entries: []library.Entry) {
	free_play_queue(items)
	items^ = make([dynamic]Play_Item, 0, len(entries))
	for entry, index in entries {
		links: []library.Artist_Link
		if len(entry.first_artist) > 0 || len(entry.artist_uri) > 0 {
			links = make([]library.Artist_Link, 1)
			links[0] = library.Artist_Link {
				name = strings.clone(entry.first_artist),
				uri  = strings.clone(entry.artist_uri),
			}
		}
		append(
			items,
			Play_Item {
				uri = strings.clone(entry.uri),
				artist = strings.clone(entry.subtitle),
				artist_links = links,
				album = strings.clone(entry.album),
				album_uri = strings.clone(entry.album_uri),
				cover = strings.clone(entry.image),
				order = index,
			},
		)
	}
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
	if !select_play_item(items, index^ + delta, selected, cover, artist) {return false}
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
		if work.preloaded.url != "" {
			fresh = work.preloaded
			work.preloaded = {}
			authorized = true
		} else {
			fresh, authorized = session.open(.Remember, work.cancel, work.track_url)
		}
		if !authorized {
			if !sync.atomic_load(
				work.cancel,
			) {_ = chan.send(work.queue, player.Packet{kind = .Failed})}
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

cancel_worker :: proc(queue: chan.Chan(player.Packet), cancel, closed: ^bool) {
	sync.atomic_store(cancel, true)
	if !closed^ {chan.close(queue); closed^ = true}
}

release_worker :: proc(
	worker: ^thread.Thread,
	queue: chan.Chan(player.Packet),
	cancel: ^bool,
	closed: bool,
) {
	closed := closed
	cancel_worker(queue, cancel, &closed)
	thread.join(worker)
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
