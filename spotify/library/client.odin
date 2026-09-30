// One bounded Web API worker handles account data. A second worker handles
// public cover images, so slow artwork can never block navigation. Each API
// result owns one arena and is released in one call.
package library

import diagnostic "../../diagnostic"
import artwork "../artwork"
import oauth "../oauth"
import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"

State :: enum {
	Idle,
	Authorizing,
	Loading,
	Ready,
	Missing_Client_ID,
	Failed,
}

Request_Kind :: enum {
	Index,
	Detail,
	More,
}

Request :: struct {
	kind:   Request_Kind,
	list:   Kind,
	offset: int,
	cursor: string, // Index; worker frees
	source: Source,
	id:     string, // Detail, More; worker frees
}

Result :: struct {
	kind:        Request_Kind,
	list:        Kind,
	page:        Page,
	detail:      Detail,
	rows:        [dynamic]Track_Row, // allocated in rows_arena
	releases:    [dynamic]Entry, // allocated in rows_arena
	rows_arena:  virtual.Arena,
	total:       int,
	next_offset: int,
	has_more:    bool,
	source:      Source,
	id:          string, // Detail, More; receiver frees
	status:      int,
	ok:          bool,
}

Cover_Request :: struct {
	url: string,
	key: u64,
}

Cover_Result :: struct {
	key:   u64,
	image: artwork.Image,
}

Client :: struct {
	state:                 State,
	pages:                 [Kind]Page,
	pending:               [Kind]bool,
	detail:                Detail,
	detail_loading:        bool,
	detail_error:          int,
	detail_request_id:     string,
	detail_request_source: Source,
	cover_queue:           [dynamic]Cover_Result,
	covers_pending:        int,
	requests:              chan.Chan(Request),
	results:               chan.Chan(Result),
	cover_requests:        chan.Chan(Cover_Request),
	cover_results:         chan.Chan(Cover_Result),
	worker:                ^thread.Thread,
	cover_worker:          ^thread.Thread,
	cancel:                bool,
	remaining_initial:     int,
	last_http_status:      int,
	failed:                bool,
	remember:              bool,
}

run :: proc(pointer: rawptr) {
	client := (^Client)(pointer)
	tokens, auth := authorize(client.remember, &client.cancel)
	if auth != .Ready {
		if auth != .Cancelled {
			_ = chan.send(client.results, Result{status = auth == .Missing_Client_ID ? -1 : 0})
		}
		return
	}
	defer oauth.wipe_tokens(&tokens)
	streaming: oauth.Tokens
	defer oauth.wipe_tokens(&streaming)
	for request in chan.recv(client.requests) {
		defer free_all(context.temp_allocator)
		defer free_request(request)
		if sync.atomic_load(&client.cancel) {break}
		handle(client, &tokens, &streaming, request)
	}
}

free_request :: proc(request: Request) {
	delete(request.cursor)
	delete(request.id)
}

handle :: proc(client: ^Client, tokens, streaming: ^oauth.Tokens, request: Request) {
	switch request.kind {
	case .Index:
		page, status, ok := fetch_index(
			tokens.access,
			request.list,
			request.offset,
			request.cursor,
		)
		send(
			client,
			Result{kind = .Index, list = request.list, page = page, status = status, ok = ok},
		)
	case .Detail:
		detail, status, ok := fetch_detail(tokens.access, request.source, request.id)
		if ok && request.source == .Playlist && detail.rows_error == 403 {
			rows, total, next, more, rows_status, rows_ok := read_session_playlist(
				client,
				streaming,
				request.id,
				0,
				virtual.arena_allocator(&detail.arena),
			)
			if rows_ok {
				detail.rows, detail.total, detail.next_offset, detail.has_more =
					rows, total, next, more
				detail.rows_error = 0
			} else {
				detail.rows_error = rows_status != 0 ? rows_status : -1
			}
		}
		send(
			client,
			Result {
				kind = .Detail,
				source = request.source,
				id = strings.clone(request.id),
				detail = detail,
				status = status,
				ok = ok,
			},
		)
	case .More:
		aresult := Result {
			kind   = .More,
			source = request.source,
			id     = strings.clone(request.id),
		}
		if virtual.arena_init_growing(&aresult.rows_arena) != nil {
			aresult.status = 0
			send(client, aresult)
			return
		}
		allocator := virtual.arena_allocator(&aresult.rows_arena)
		if request.source == .Artist {
			aresult.releases, aresult.total, aresult.next_offset, aresult.has_more, aresult.status, aresult.ok =
				fetch_artist_albums(tokens.access, request.id, request.offset, allocator)
		} else {
			aresult.rows, aresult.total, aresult.next_offset, aresult.has_more, aresult.status, aresult.ok =
				fetch_track_page(
					tokens.access,
					request.source,
					request.id,
					request.offset,
					allocator,
				)
		}
		if request.source == .Playlist && !aresult.ok && aresult.status == 403 {
			aresult.rows, aresult.total, aresult.next_offset, aresult.has_more, aresult.status, aresult.ok =
				read_session_playlist(client, streaming, request.id, request.offset, allocator)
		}
		send(client, aresult)
	}
}

run_covers :: proc(pointer: rawptr) {
	client := (^Client)(pointer)
	for request in chan.recv(client.cover_requests) {
		defer free_all(context.temp_allocator)
		defer delete(request.url)
		if sync.atomic_load(&client.cancel) {break}
		image: artwork.Image
		if artwork.valid_cover_url(request.url) {
			bytes, status, fetched := cover_get(request.url)
			if fetched {
				if status == 200 {
					image, _ = artwork.decode(bytes[:])
					if len(image.pixels) == 0 {cache_remove("cover", request.url)}
				}
				delete(bytes)
			}
		}
		diagnostic.cover_decode_result(len(image.pixels) > 0)
		result := Cover_Result {
				key   = request.key,
				image = image,
			}
		if !chan.send(client.cover_results, result) {artwork.free_image(&result.image)}
	}
}

send :: proc(client: ^Client, result: Result) -> bool {
	if chan.send(client.results, result) {return true}
	free_result(result)
	return false
}

free_result :: proc(result: Result) {
	local := result
	free_page(&local.page)
	free_detail(&local.detail)
	virtual.arena_destroy(&local.rows_arena)
	delete(local.id)
}

start :: proc(client: ^Client, remember: bool) -> bool {
	if client.worker != nil {return true}
	id := os.get_env("WEB_CLIENT_ID", context.allocator)
	valid := valid_client_id(id)
	delete(id)
	if !valid {
		client.state = .Missing_Client_ID
		return false
	}
	allocation: runtime.Allocator_Error
	client.requests, allocation = chan.create_buffered(chan.Chan(Request), 8, context.allocator)
	if allocation != nil {client.state = .Failed; return false}
	client.results, allocation = chan.create_buffered(chan.Chan(Result), 8, context.allocator)
	if allocation != nil {
		chan.destroy(client.requests)
		client.state = .Failed
		return false
	}
	client.cover_requests, allocation = chan.create_buffered(
		chan.Chan(Cover_Request),
		16,
		context.allocator,
	)
	if allocation != nil {
		chan.destroy(client.requests)
		chan.destroy(client.results)
		client.state = .Failed
		return false
	}
	client.cover_results, allocation = chan.create_buffered(
		chan.Chan(Cover_Result),
		16,
		context.allocator,
	)
	if allocation != nil {
		chan.destroy(client.requests)
		chan.destroy(client.results)
		chan.destroy(client.cover_requests)
		client.state = .Failed
		return false
	}
	client.remember = remember
	client.worker = thread.create_and_start_with_data(client, run)
	client.cover_worker = thread.create_and_start_with_data(client, run_covers)
	if client.worker == nil || client.cover_worker == nil {
		sync.atomic_store(&client.cancel, true)
		chan.close(client.requests)
		chan.close(client.results)
		chan.close(client.cover_requests)
		chan.close(client.cover_results)
		if client.worker != nil {thread.join(client.worker); thread.destroy(client.worker)}
		if client.cover_worker != nil {
			thread.join(client.cover_worker)
			thread.destroy(client.cover_worker)
		}
		chan.destroy(client.requests)
		chan.destroy(client.results)
		chan.destroy(client.cover_requests)
		chan.destroy(client.cover_results)
		client.worker, client.cover_worker = nil, nil
		client.state = .Failed
		return false
	}
	diagnostic.write("library and cover workers started")
	client.state = .Authorizing
	client.remaining_initial = 3
	for kind in ([]Kind{Kind.Playlists, Kind.Albums, Kind.Artists}) {
		client.pending[kind] = true
		_ = chan.send(client.requests, Request{kind = .Index, list = kind})
	}
	return true
}

more :: proc(client: ^Client, kind: Kind) {
	if client.worker == nil || client.state != .Ready {return}
	i := kind
	page := &client.pages[i]
	if !page.has_more || client.pending[i] {return}
	request := Request {
		kind   = .Index,
		list   = kind,
		offset = page.next_offset,
		cursor = strings.clone(page.cursor),
	}
	if chan.try_send(client.requests, request) {
		client.pending[i] = true
	} else {
		delete(request.cursor)
	}
}

open_detail :: proc(client: ^Client, source: Source, id: string, preview: Entry) -> bool {
	if client.worker == nil || client.state != .Ready || len(id) == 0 {return false}
	request := Request {
		kind   = .Detail,
		source = source,
		id     = strings.clone(id),
	}
	if !chan.try_send(client.requests, request) {
		delete(request.id)
		return false
	}
	// Clone before releasing the current detail: discography cards can borrow
	// their strings from that arena. Keep the card cover through hero loading.
	next: Detail
	if virtual.arena_init_growing(&next.arena) == nil {
		allocator := virtual.arena_allocator(&next.arena)
		next.ready = true
		next.source = source
		next.id = strings.clone(id, allocator)
		next.name = strings.clone(preview.name, allocator)
		next.subtitle = strings.clone(preview.subtitle, allocator)
		next.image = strings.clone(preview.image, allocator)
		next.image_preview = strings.clone(preview.image, allocator)
		next.image_small = strings.clone(preview.image, allocator)
		next.total = preview.total
		switch source {
		case .Playlist, .Liked:
			next.label = strings.clone("Playlist", allocator)
		case .Album:
			next.label = strings.clone("Album", allocator)
		case .Artist:
			next.label = strings.clone("Artist", allocator)
		}
	}
	request_id := strings.clone(id)
	move_detail(&client.detail, &next)
	delete(client.detail_request_id)
	client.detail_request_id = request_id
	client.detail_request_source = source
	client.detail_loading = true
	client.detail_error = 0
	return true
}

clear_detail :: proc(client: ^Client) {
	free_detail(&client.detail)
	delete(client.detail_request_id)
	client.detail_request_id = ""
	client.detail_loading = false
	client.detail_error = 0
}

more_rows :: proc(client: ^Client) -> bool {
	if client.worker == nil || client.detail_loading || !client.detail.has_more {return false}
	if len(client.detail.id) == 0 {return false}
	request := Request {
		kind   = .More,
		source = client.detail.source,
		id     = strings.clone(client.detail.id),
		offset = client.detail.next_offset,
	}
	if !chan.try_send(client.requests, request) {
		delete(request.id)
		return false
	}
	client.detail_loading = true
	return true
}

request_cover :: proc(client: ^Client, url: string, key: u64) -> bool {
	if client.cover_worker == nil || client.state != .Ready || len(url) == 0 {return false}
	request := Cover_Request {
		url = strings.clone(url),
		key = key,
	}
	if !chan.try_send(client.cover_requests, request) {
		delete(request.url)
		return false
	}
	client.covers_pending += 1
	return true
}

take_cover :: proc(client: ^Client) -> (cover: Cover_Result, ok: bool) {
	if len(client.cover_queue) == 0 {return}
	cover = pop(&client.cover_queue)
	return cover, true
}

poll :: proc(client: ^Client) -> bool {
	changed := false
	for result in chan.try_recv(client.results) {
		changed = true
		apply(client, result)
	}
	for result in chan.try_recv(client.cover_results) {
		changed = true
		client.covers_pending = max(0, client.covers_pending - 1)
		append(&client.cover_queue, result)
	}
	return changed
}

apply :: proc(client: ^Client, result: Result) {
	local := result
	defer free_result(local)
	switch local.kind {
	case .Index:
		if !local.ok {
			client.failed = true
			client.last_http_status = local.status
			client.state = local.status <= 0 ? .Missing_Client_ID : .Failed
			return
		}
		i := local.list
		client.pending[i] = false
		if client.remaining_initial > 0 {client.remaining_initial -= 1}
		destination := &client.pages[i]
		message := fmt.aprintf(
			"library page merge: kind=%v existing=%d incoming=%d capacity=%d",
			local.list,
			len(destination.items),
			len(local.page.items),
			cap(destination.items),
		)
		diagnostic.write(message)
		delete(message)
		if !destination.ready {
			free_page(destination)
			destination^ = local.page // arena ownership moves to the client
			// Dynamic arrays retain an allocator pointing to the original arena
			// struct. Rebind it to the new owner before any subsequent resize.
			destination.items.allocator = virtual.arena_allocator(&destination.arena)
			local.page = {}
		} else {
			// Grow in the owned arena without moving existing strings.
			allocator := virtual.arena_allocator(&destination.arena)
			destination.items.allocator = allocator
			for entry in local.page.items {
				append(&destination.items, clone_entry(entry, allocator))
			}
			destination.cursor = strings.clone(local.page.cursor, allocator)
			destination.has_more = local.page.has_more
			destination.next_offset = local.page.next_offset
			destination.total = local.page.total
		}
		diagnostic.write("library page merge completed")
		client.state = client.failed ? .Failed : client.remaining_initial > 0 ? .Loading : .Ready
	case .Detail:
		if local.source != client.detail_request_source ||
		   local.id != client.detail_request_id {return}
		client.detail_loading = false
		if !local.ok {
			client.last_http_status = local.status
			client.detail_error = local.status
			client.state = local.status == 401 || local.status == 403 ? .Failed : client.state
			return
		}
		diagnostic.write("library detail applied")
		// The metadata response can arrive before its larger cover. Keep the
		// selected card's cover alive in the incoming arena until texture upload.
		local.detail.image_preview = strings.clone(
			client.detail.image_preview,
			virtual.arena_allocator(&local.detail.arena),
		)
		move_detail(&client.detail, &local.detail)
	case .More:
		if local.source == client.detail.source && local.id == client.detail.id {
			client.detail_loading = false
			if local.ok && client.detail.ready {
				allocator := virtual.arena_allocator(&client.detail.arena)
				if local.source == .Artist {
					for release in local.releases {
						append(&client.detail.releases, clone_entry(release, allocator))
					}
				} else {
					for row in local.rows {append(&client.detail.rows, clone_row(row, allocator))}
				}
				client.detail.total = local.total
				client.detail.next_offset = local.next_offset
				client.detail.has_more = local.has_more
			}
		}
	}
}

stop :: proc(client: ^Client) {
	diagnostic.write("library workers stopping")
	if client.worker != nil {
		sync.atomic_store(&client.cancel, true)
		chan.close(client.requests)
		chan.close(client.results)
		chan.close(client.cover_requests)
		chan.close(client.cover_results)
		thread.join(client.worker)
		thread.destroy(client.worker)
		thread.join(client.cover_worker)
		thread.destroy(client.cover_worker)
		for request in chan.try_recv(client.requests) {free_request(request)}
		for result in chan.try_recv(client.results) {free_result(result)}
		for request in chan.try_recv(client.cover_requests) {delete(request.url)}
		for result in chan.try_recv(client.cover_results) {delete(result.image.pixels)}
		chan.destroy(client.requests)
		chan.destroy(client.results)
		chan.destroy(client.cover_requests)
		chan.destroy(client.cover_results)
	}
	for &page in client.pages {free_page(&page)}
	free_detail(&client.detail)
	delete(client.detail_request_id)
	for i in 0 ..< len(client.cover_queue) {artwork.free_image(&client.cover_queue[i].image)}
	delete(client.cover_queue)
	client^ = {}
}
