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
	uri:    string,
	artist: string,
	cover:  string,
	order:  int,
}

free_play_queue :: proc(items: ^[dynamic]Play_Item) {
	for item in items^ {
		delete(item.uri)
		delete(item.artist)
		delete(item.cover)
	}
	delete(items^)
	items^ = nil
}

build_play_queue :: proc(
	items: ^[dynamic]Play_Item,
	rows: []library.Track_Row,
	fallback_cover: string = "",
) {
	free_play_queue(items)
	items^ = make([dynamic]Play_Item, 0, len(rows))
	for row, index in rows {
		cover :=
			row.image_small != "" ? row.image_small : row.image != "" ? row.image : fallback_cover
		append(
			items,
			Play_Item {
				uri = strings.clone(row.uri),
				artist = strings.clone(row.artists),
				cover = strings.clone(cover),
				order = index,
			},
		)
	}
}

// Search tracks arrive as cards, not detail rows. The subtitle carries the
// artists and the image carries the cover, so a queue builds directly.
build_play_queue_from_entries :: proc(items: ^[dynamic]Play_Item, entries: []library.Entry) {
	free_play_queue(items)
	items^ = make([dynamic]Play_Item, 0, len(entries))
	for entry, index in entries {
		append(
			items,
			Play_Item {
				uri = strings.clone(entry.uri),
				artist = strings.clone(entry.subtitle),
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

select_play_item :: proc(items: []Play_Item, index: int, selected, cover: ^string) -> bool {
	if index < 0 || index >= len(items) {return false}
	delete(selected^)
	selected^ = strings.clone(items[index].uri)
	delete(cover^)
	cover^ = strings.clone(items[index].cover)
	return true
}

advance_play_item :: proc(
	items: []Play_Item,
	index: ^int,
	delta: int,
	selected, cover: ^string,
) -> bool {
	if !select_play_item(items, index^ + delta, selected, cover) {return false}
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
	track:    string,
	source:   session.Source,
	cancel:   bool,
	remember: bool,
}

clear_preload :: proc(preload: ^Preload_Work) {
	session.close_source(&preload.source)
	delete(preload.track)
	preload^ = {}
}

preload_track :: proc(pointer: rawptr) {
	work := (^Preload_Work)(pointer)
	source, ok := session.open(work.remember ? .Remember : .Restore, &work.cancel, work.track)
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
	remember:  bool,
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
			fresh, authorized = session.open(
				work.remember ? .Remember : .Restore,
				work.cancel,
				work.track_url,
			)
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
