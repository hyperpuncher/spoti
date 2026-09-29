package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
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
	uri:   string,
	cover: string,
}

free_play_queue :: proc(items: ^[dynamic]Play_Item) {
	for item in items^ {
		delete(item.uri)
		delete(item.cover)
	}
	delete(items^)
	items^ = nil
}

build_play_queue :: proc(items: ^[dynamic]Play_Item, rows: []library.Track_Row) {
	free_play_queue(items)
	items^ = make([dynamic]Play_Item, 0, len(rows))
	for row in rows {
		append(
			items,
			Play_Item{uri = strings.clone(row.uri), cover = strings.clone(row.image_small)},
		)
	}
}

select_play_item :: proc(items: []Play_Item, index: int, selected, cover: ^string) -> bool {
	if index < 0 || index >= len(items) {return false}
	delete(selected^)
	selected^ = strings.clone(items[index].uri)
	delete(cover^)
	cover^ = strings.clone(items[index].cover)
	return true
}

Login_Work :: struct {
	queue:     chan.Chan(player.Packet),
	cancel:    ^bool,
	track_url: string, // owned by the worker
	remember:  bool,
}

login_and_decode :: proc(pointer: rawptr) {
	work := (^Login_Work)(pointer)
	defer delete(work.track_url)
	source, authorized := session.open(
		work.remember ? .Remember : .Restore,
		work.cancel,
		work.track_url,
	)
	if !authorized {
		if !sync.atomic_load(work.cancel) {
			_ = chan.send(work.queue, player.Packet{kind = .Failed})
		}
		return
	}
	defer session.close_source(&source)
	if sync.atomic_load(work.cancel) {return}
	name := strings.clone(source.name)
	if !chan.send(
		work.queue,
		player.Packet{kind = .Ready, name = name, duration_ms = source.duration_ms},
	) {
		delete(name)
		return
	}
	decode := player.Work {
		url    = source.url,
		key    = source.key,
		queue  = work.queue,
		cancel = work.cancel,
	}
	player.decode(&decode)
}

release_worker :: proc(
	worker: ^thread.Thread,
	queue: chan.Chan(player.Packet),
	cancel: ^bool,
	closed: bool,
) {
	sync.atomic_store(cancel, true)
	if !closed {chan.close(queue)}
	thread.join(worker)
	thread.destroy(worker)
	for packet in chan.try_recv(queue) {
		delete(packet.pcm)
		delete(packet.name)
	}
	chan.destroy(queue)
}

duration_text :: proc(duration_ms: int, buffer: []u8) -> string {
	seconds := max(0, duration_ms) / 1000
	return fmt.bprintf(buffer, "%d:%02d", seconds / 60, seconds % 60)
}

duration_text_alloc :: proc(duration_ms: int) -> string {
	seconds := max(0, duration_ms) / 1000
	return fmt.aprintf("%d:%02d", seconds / 60, seconds % 60, allocator = context.temp_allocator)
}
