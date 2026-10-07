// One bounded Web API worker handles account data. A second worker handles
// public cover images, so slow artwork can never block navigation. Each API
// result owns one arena and is released in one call.
package library

import diagnostic "../../diagnostic"
import artwork "../artwork"
import credential "../credential"
import http "../http"
import oauth "../oauth"
import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:time"

State :: enum {
	Idle,
	Authorizing,
	Sign_In_Failed,
	Loading,
	Ready,
	Missing_Client_ID,
	Failed,
}

Request_Kind :: enum {
	Index,
	Detail,
	More,
	Search,
	Like,
	Auth, // result-only: the worker could not sign in
}

Request :: struct {
	kind:    Request_Kind,
	list:    Kind,
	offset:  int,
	cursor:  string, // Index; worker frees
	source:  Source,
	id:      string, // Detail, More; worker frees
	query:   string, // Search; worker frees
	serial:  u64, // Search; echoes back so stale results are dropped
	liked:   bool, // Like; the membership to set
	saved:   bool, // Detail; the preview already knows the membership
	refresh: bool, // Index; a revalidation that replaces the page
}

Result :: struct {
	kind:          Request_Kind,
	list:          Kind,
	page:          Page,
	detail:        Detail,
	rows:          [dynamic]Track_Row, // allocated in rows_arena
	releases:      [dynamic]Entry, // allocated in rows_arena
	rows_arena:    virtual.Arena,
	search_pages:  [Kind]Page, // Search; receiver frees or adopts
	search_query:  string, // Search; receiver frees or adopts
	search_serial: u64, // Search; only the latest applies
	total:         int,
	next_offset:   int,
	has_more:      bool,
	source:        Source,
	id:            string, // Detail, More; receiver frees
	status:        int,
	ok:            bool,
	liked:         bool, // Like; echoes the requested membership
	auth:          Auth_Result, // Auth; why sign-in stopped
	retry_after:   int, // Index; seconds the server asked us to wait
	refresh:       bool, // Index; a revalidation that replaces the page
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
	prev_detail:           Detail, // last page left, with its rows; instant back-nav
	prev_at:               time.Time,
	detail_loading:        bool,
	detail_loading_at:     time.Time,
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
	page_at:               time.Time, // earliest time the next page request may go out
	saved_at:              time.Time, // earliest time the next membership check may go out
	rate_limited:          u8, // consecutive 429s; drives the doubling backoff
	search_query:          string, // applied query; owned
	search_serial:         u64, // latest request; stale results are dropped
	search_loading:        bool,
	search_error:          int,
	search_pages:          [Kind]Page,
	like_pending:          bool, // hero heart toggle in flight
}

run :: proc(pointer: rawptr) {
	client := (^Client)(pointer)
	// Read-time TTLs only hide old bodies, so sweep them once at startup.
	cache_prune("api", API_STALE)
	// One easy handle for the worker's lifetime keeps TCP/TLS sessions
	// alive across sequential API requests. Never shared with the cover
	// worker; easy handles are thread-confined.
	reuse := http.open_handle()
	defer http.close_handle(reuse)
	tokens, auth := authorize(&client.cancel)
	diagnostic.writef("library auth=%v", auth)
	if auth != .Ready {
		if auth != .Cancelled {
			_ = chan.send(client.results, Result{kind = .Auth, auth = auth})
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
		handle(client, &tokens, &streaming, request, reuse)
	}
}

free_request :: proc(request: Request) {
	delete(request.cursor)
	delete(request.id)
	delete(request.query)
}

// Sends a worker request; drops and frees it when the queue is full.
queue_request :: proc(client: ^Client, request: ^Request) -> bool {
	if client.worker == nil || client.state != .Ready {return false}
	if !chan.try_send(client.requests, request^) {
		free_request(request^)
		return false
	}
	return true
}

// The access token lives about an hour. Search and pagination fire long
// after startup, so they renew it on demand instead of failing with 401.
// A failed renewal fails the request; the UI keeps its old state.
ensure_tokens :: proc(client: ^Client, tokens: ^oauth.Tokens) -> bool {
	if !oauth.expired(tokens^) {return true}
	if sync.atomic_load(&client.cancel) {return false}
	client_id := os.get_env("WEB_CLIENT_ID", context.temp_allocator)
	if !valid_client_id(client_id) {return false}
	grant := oauth.web_grant(client_id)
	fresh, status := oauth.refresh(tokens.refresh, grant)
	if status != .Authorized {return false}
	oauth.wipe_tokens(tokens)
	tokens^ = fresh
	if len(fresh.refresh) > 0 {
		_ = credential.save(fresh.refresh, .Library)
	}
	return true
}

fail_request :: proc(client: ^Client, request: Request) {
	#partial switch request.kind {
	case .Index:
		send(client, Result{kind = .Index, list = request.list, status = -1})
	case .Detail:
		send(
			client,
			Result {
				kind = .Detail,
				source = request.source,
				id = strings.clone(request.id),
				status = -1,
			},
		)
	case .More:
		send(
			client,
			Result {
				kind = .More,
				source = request.source,
				id = strings.clone(request.id),
				status = -1,
			},
		)
	case .Search:
		send(
			client,
			Result {
				kind = .Search,
				search_serial = request.serial,
				search_query = strings.clone(request.query),
				status = -1,
			},
		)
	case .Like:
		send(
			client,
			Result {
				kind = .Like,
				source = request.source,
				id = strings.clone(request.id),
				liked = request.liked,
				status = -1,
			},
		)
	}
}

handle :: proc(
	client: ^Client,
	tokens, streaming: ^oauth.Tokens,
	request: Request,
	reuse: rawptr = nil,
) {
	diagnostic.writef("library request=%v offset=%d", request.kind, request.offset)
	if !ensure_tokens(client, tokens) {
		fail_request(client, request)
		return
	}
	#partial switch request.kind {
	case .Index:
		retry_after: int
		page, status, ok := fetch_index(
			tokens.access,
			request.list,
			request.offset,
			request.cursor,
			reuse,
			&retry_after,
			refresh = request.refresh,
		)
		send(
			client,
			Result {
				kind = .Index,
				list = request.list,
				page = page,
				status = status,
				ok = ok,
				retry_after = retry_after,
				refresh = request.refresh,
			},
		)
	case .Detail:
		detail, status, ok := fetch_detail(
			tokens.access,
			request.source,
			request.id,
			reuse = reuse,
		)
		if ok && request.source == .Playlist && detail.rows_error == 403 {
			rows, total, next, more, rows_status, rows_ok := read_session_playlist(
				client,
				streaming,
				request.id,
				0,
				virtual.arena_allocator(&detail.arena),
				reuse,
			)
			if rows_ok {
				detail.rows, detail.total, detail.next_offset, detail.has_more =
					rows, total, next, more
				detail.rows_error = 0
			} else {
				detail.rows_error = rows_status != 0 ? rows_status : -1
			}
		}
		if ok {
			detail.liked = request.saved
			if !request.saved && time.since(client.saved_at) >= 0 {
				if liked, known := fetch_saved(tokens.access, request.source, request.id, reuse);
				   known {
					detail.liked = liked
				} else {
					// A failed check must not read as "not saved", and must not
					// be repeated on every open.
					client.saved_at = time.time_add(time.now(), SAVED_CHECK_BACKOFF)
				}
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
	case .Like:
		uri := library_uri(request.source, request.id)
		defer delete(uri)
		status, ok := set_saved(tokens.access, uri, request.liked, reuse)
		send(
			client,
			Result {
				kind = .Like,
				source = request.source,
				id = strings.clone(request.id),
				liked = request.liked,
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
				fetch_artist_albums(tokens.access, request.id, request.offset, allocator, reuse)
		} else {
			aresult.rows, aresult.total, aresult.next_offset, aresult.has_more, aresult.status, aresult.ok =
				fetch_track_page(
					tokens.access,
					request.source,
					request.id,
					request.offset,
					allocator,
					"",
					reuse,
				)
		}
		if request.source == .Playlist && !aresult.ok && aresult.status == 403 {
			aresult.rows, aresult.total, aresult.next_offset, aresult.has_more, aresult.status, aresult.ok =
				read_session_playlist(
					client,
					streaming,
					request.id,
					request.offset,
					allocator,
					reuse,
				)
		}
		send(client, aresult)
	case .Search:
		pages, status, ok := fetch_search(tokens.access, request.query, reuse)
		send(
			client,
			Result {
				kind = .Search,
				search_serial = request.serial,
				search_query = strings.clone(request.query),
				search_pages = pages,
				status = status,
				ok = ok,
			},
		)
	}
}

run_covers :: proc(pointer: rawptr) {
	client := (^Client)(pointer)
	reuse := http.open_handle()
	defer http.close_handle(reuse)
	for request in chan.recv(client.cover_requests) {
		defer free_all(context.temp_allocator)
		defer delete(request.url)
		if sync.atomic_load(&client.cancel) {break}
		image: artwork.Image
		if artwork.valid_cover_url(request.url) {
			bytes, status, fetched := cover_get(request.url, reuse)
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
	free_search_pages(&local.search_pages)
	delete(local.search_query)
	delete(local.id)
}

start :: proc(client: ^Client) -> bool {
	if client.worker != nil {return true}
	client.cancel, client.failed = false, false
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
		// Paint the cache now so the first frame is never blank, then let
		// the worker replace it with a fresh read behind the scenes.
		if page, _, ok := fetch_index("", kind, cache_only = true); ok {
			destination := &client.pages[kind]
			free_page(destination)
			destination^ = page
			destination.items.allocator = virtual.arena_allocator(&destination.arena)
		}
		client.pending[kind] = true
		_ = chan.send(client.requests, Request{kind = .Index, list = kind, refresh = true})
	}
	return true
}

// Spotify answers request bursts with 429 on a rolling window, and every paged
// read counts against it, so pages are spaced out. A rejected page waits for
// the server's Retry-After or a doubling backoff instead of poisoning the
// client, which would also stop cover loading and search.
PAGE_INTERVAL :: 400 * time.Millisecond
PAGE_RATE_LIMIT_BACKOFF :: 2 * time.Second
PAGE_RETRY_BACKOFF :: 500 * time.Millisecond
// /me/library/contains shares a quota bucket with the album and artist tabs,
// so a failed check backs off instead of firing on every page open.
SAVED_CHECK_BACKOFF :: 5 * time.Minute
RATE_LIMIT_STEPS :: 4
// A placeholder only appears when a fetch is actually slow: a cached page
// lands within a frame or two and must not flash "Loading tracks...".
DETAIL_LOADING_DELAY :: 150 * time.Millisecond

rate_limit_delay :: proc(client: ^Client, retry_after: int) -> time.Duration {
	client.rate_limited = min(client.rate_limited + 1, RATE_LIMIT_STEPS)
	if retry_after > 0 {return time.Duration(retry_after) * time.Second}
	return PAGE_RATE_LIMIT_BACKOFF * time.Duration(1 << (client.rate_limited - 1))
}

more :: proc(client: ^Client, kind: Kind) {
	if client.worker == nil || client.state != .Ready {return}
	i := kind
	page := &client.pages[i]
	// A page that never loaded keeps has_more false; ask again instead of
	// treating the tab as finished.
	if page.ready && !page.has_more {return}
	if client.pending[i] || time.since(client.page_at) < 0 {return}
	request := Request {
		kind   = .Index,
		list   = kind,
		offset = page.next_offset,
		cursor = strings.clone(page.cursor),
	}
	if queue_request(client, &request) {
		client.pending[i] = true
		client.page_at = time.time_add(time.now(), PAGE_INTERVAL)
	}
}

open_detail :: proc(client: ^Client, source: Source, id: string, preview: Entry) -> bool {
	if len(id) == 0 {return false}
	// A page left minutes ago reopens with its rows in place: no request,
	// no paging chain, and the banked scroll offset applies at once.
	if detail_buffer_take(client, source, id, preview) {return true}
	request := Request {
		kind   = .Detail,
		source = source,
		id     = strings.clone(id),
		saved  = preview.saved,
	}
	if !queue_request(client, &request) {return false}
	// Clone before releasing the current detail: discography cards can borrow
	// their strings from that arena. Keep the card cover through hero loading.
	next: Detail
	warm, _, warm_ok := fetch_detail("", source, id, cache_only = true)
	if warm_ok && warm.rows_error == 0 {
		// The page is already on disk, so it opens with its rows in place.
		// The queued request above still revalidates it in the background.
		next = warm
		next.image_preview = strings.clone(preview.image, virtual.arena_allocator(&next.arena))
	} else {
		if warm_ok {free_detail(&warm)}
		if virtual.arena_init_growing(&next.arena) == nil {
			allocator := virtual.arena_allocator(&next.arena)
			next.ready = true
			next.source = source
			next.id = strings.clone(id, allocator)
			next.name = strings.clone(preview.name, allocator)
			next.subtitle = strings.clone(preview.subtitle, allocator)
			next.year = strings.clone(preview.year, allocator)
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
	}
	next.liked = preview.saved
	next.generation = client.detail.generation + 1
	request_id := strings.clone(id)
	detail_buffer_stash(client)
	move_detail(&client.detail, &next)
	delete(client.detail_request_id)
	client.detail_request_id = request_id
	client.detail_request_source = source
	client.detail_loading = true
	client.detail_loading_at = time.time_add(time.now(), DETAIL_LOADING_DELAY)
	client.detail_error = 0
	return true
}

// True while an open is slow enough, and empty enough, that a placeholder
// helps. Pagination keeps its rows; only the first fill can show the table.
detail_loading_visible :: proc(client: ^Client) -> bool {
	if !client.detail_loading || time.since(client.detail_loading_at) < 0 {return false}
	return len(client.detail.rows) == 0 && len(client.detail.releases) == 0
}

// Queues a library membership flip for the hero heart. The worker answers
// with a Like result that flips the detail and syncs the sidebar grids.
toggle_like :: proc(client: ^Client, source: Source, id: string, liked: bool) -> bool {
	if len(id) == 0 {return false}
	request := Request {
		kind   = .Like,
		source = source,
		id     = strings.clone(id),
		liked  = liked,
	}
	if !queue_request(client, &request) {return false}
	client.like_pending = true
	return true
}

// Keeps the sidebar grids in step with hero heart toggles. Unlike drops
// the card; like appends one built from the open detail, stamped now so a
// just-added collection sorts first. Anything else surfaces on the next
// full load.
sync_library_membership :: proc(client: ^Client, source: Source, id: string, liked: bool) {
	kind, ok := source_kind(source)
	if !ok {return}
	uri := library_uri(source, id)
	if len(uri) == 0 {return}
	defer delete(uri)
	page := &client.pages[kind]
	allocator := virtual.arena_allocator(&page.arena)
	page.items.allocator = allocator
	if liked {
		for entry in page.items {if entry.uri == uri {return}}
		if client.detail.source != source || client.detail.id != id {return}
		detail := client.detail
		// The default order is Spotify's, which lists newest first, so a
		// just-liked card goes back to the front where the heart was clicked.
		inject_at(
			&page.items,
			0,
			Entry {
				name = strings.clone(detail.name, allocator),
				uri = strings.clone(uri, allocator),
				image = strings.clone(detail.image, allocator),
				subtitle = strings.clone(detail.subtitle, allocator),
				year = strings.clone(detail.year, allocator),
				saved = true,
				total = detail.total,
			},
		)
		page.total += 1
	} else {
		for entry, index in page.items {
			if entry.uri != uri {continue}
			ordered_remove(&page.items, index)
			page.total = max(0, page.total - 1)
			return
		}
	}
}

source_kind :: proc(source: Source) -> (kind: Kind, ok: bool) {
	switch source {
	case .Playlist:
		return .Playlists, true
	case .Album:
		return .Albums, true
	case .Artist:
		return .Artists, true
	case .Liked:
		return .Playlists, false
	}
	return .Playlists, false
}

// The page being left keeps its rows for the trip back: playlist to
// artist and back replays zero requests while the buffer stays fresh.
detail_buffer_stash :: proc(client: ^Client) {
	outgoing := &client.detail
	if !outgoing.ready || outgoing.rows_error != 0 {return}
	if len(outgoing.rows) == 0 && len(outgoing.releases) == 0 {return}
	free_detail(&client.prev_detail)
	client.prev_detail = {}
	move_detail(&client.prev_detail, outgoing)
	client.prev_at = time.now()
}

detail_buffer_take :: proc(client: ^Client, source: Source, id: string, preview: Entry) -> bool {
	prev := &client.prev_detail
	if !prev.ready || prev.source != source || prev.id != id {return false}
	if prev.rows_error != 0 {return false}
	if len(prev.rows) == 0 && len(prev.releases) == 0 {return false}
	if time.since(client.prev_at) >= PAGE_TTL {return false}
	if preview.total > 0 && prev.total > 0 && preview.total != prev.total {return false}
	// Take first, then bank the outgoing page: the other order would free
	// the buffered rows while stashing over them and break ping-pong trips.
	outgoing := client.detail
	client.detail = {}
	move_detail(&client.detail, prev)
	move_detail(prev, &outgoing)
	client.prev_at = time.now()
	allocator := virtual.arena_allocator(&client.detail.arena)
	client.detail.liked = preview.saved
	client.detail.image_preview = strings.clone(preview.image, allocator)
	client.detail.generation += 1
	delete(client.detail_request_id)
	client.detail_request_id = strings.clone(id)
	client.detail_request_source = source
	client.detail_loading = false
	client.detail_error = 0
	return true
}

clear_detail :: proc(client: ^Client) {
	detail_buffer_stash(client)
	free_detail(&client.detail)
	delete(client.detail_request_id)
	client.detail_request_id = ""
	client.detail_loading = false
	client.detail_error = 0
}

// A page already on disk costs no quota, so cached pages chain back to
// back while network pages keep their pacing between fetches.
detail_page_fresh :: proc(source: Source, id: string, offset: int) -> bool {
	switch source {
	case .Artist:
		address := artist_albums_address(id, offset)
		defer delete(address)
		return cache_fresh("api", address, PAGE_TTL)
	case .Liked, .Album:
		address, ok := track_page_address(source, id, offset)
		if !ok {return false}
		defer delete(address)
		return cache_fresh("api", address, PAGE_TTL)
	case .Playlist:
		address, ok := track_page_address(.Playlist, id, offset)
		if !ok {return false}
		defer delete(address)
		if cache_fresh("api", address, PAGE_TTL) {return true}
		window_key := playlist_cache_key("ap-playlist-window", id, offset)
		defer delete(window_key)
		meta_key := playlist_cache_key("ap-playlist-meta", id, offset)
		defer delete(meta_key)
		return cache_fresh("api", window_key, PAGE_TTL) && cache_fresh("api", meta_key, PAGE_TTL)
	}
	return false
}

more_rows :: proc(client: ^Client) -> bool {
	if client.detail_loading || !client.detail.has_more {return false}
	if len(client.detail.id) == 0 {return false}
	fresh := detail_page_fresh(client.detail.source, client.detail.id, client.detail.next_offset)
	if !fresh && time.since(client.page_at) < 0 {return false}
	request := Request {
		kind   = .More,
		source = client.detail.source,
		id     = strings.clone(client.detail.id),
		offset = client.detail.next_offset,
	}
	if !queue_request(client, &request) {return false}
	client.detail_loading = true
	client.detail_loading_at = time.time_add(time.now(), DETAIL_LOADING_DELAY)
	if !fresh {client.page_at = time.time_add(time.now(), PAGE_INTERVAL)}
	return true
}

// Queue a catalog search. Only the latest request applies; rapid typing
// cannot repopulate the grid with an older query. Returns false when the
// library is not ready or the query is empty.
search :: proc(client: ^Client, query: string) -> bool {
	if client.worker == nil || client.state != .Ready {return false}
	trimmed := strings.trim_space(query)
	if len(trimmed) == 0 || len(trimmed) > 256 {return false}
	client.search_serial += 1
	request := Request {
		kind   = .Search,
		query  = strings.clone(trimmed),
		serial = client.search_serial,
	}
	if !queue_request(client, &request) {return false}
	client.search_loading = true
	client.search_error = 0
	return true
}

// Drop results and invalidate any search still on the worker.
clear_search :: proc(client: ^Client) {
	client.search_serial += 1
	free_search_pages(&client.search_pages)
	delete(client.search_query)
	client.search_query = ""
	client.search_loading = false
	client.search_error = 0
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
			client.pending[local.list] = false
			client.last_http_status = local.status
			diagnostic.result(
				fmt.aprintf("index-%v", local.list, allocator = context.temp_allocator),
				false,
				local.status,
				0,
				0,
				false,
			)
			switch {
			case local.status == 429:
				delay := rate_limit_delay(client, local.retry_after)
				client.page_at = time.time_add(time.now(), delay)
				diagnostic.writef(
					"library rate limited retry-after=%ds backoff-ms=%d",
					local.retry_after,
					int(delay / time.Millisecond),
				)
			case local.status >= 500 || local.status <= 0:
				client.page_at = time.time_add(time.now(), PAGE_RETRY_BACKOFF)
			case:
				// An authorization problem (401, 403) stops the session until
				// sign-in is fixed; everything else retries after the backoff.
				client.failed = true
				client.state = .Failed
				return
			}
			// A failed initial load still counts as attempted, so the tab can
			// leave the loading state and ask again later.
			if client.remaining_initial > 0 {client.remaining_initial -= 1}
			client.state = client.remaining_initial > 0 ? .Loading : .Ready
			return
		}
		i := local.list
		client.pending[i] = false
		client.rate_limited = 0
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
		// A revalidation lands after the warm cache paint and replaces it;
		// later pages still append.
		if !destination.ready || local.refresh {
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
		diagnostic.result(
			fmt.aprintf("index-%v", local.list, allocator = context.temp_allocator),
			local.ok,
			local.status,
			len(destination.items),
			destination.total,
			destination.has_more,
		)
		client.state = client.failed ? .Failed : client.remaining_initial > 0 ? .Loading : .Ready
	case .Auth:
		client.state = local.auth == .Missing_Client_ID ? .Missing_Client_ID : .Sign_In_Failed
	case .Detail:
		if local.source != client.detail_request_source ||
		   local.id != client.detail_request_id {return}
		client.detail_loading = false
		if !local.ok {
			client.last_http_status = local.status
			client.detail_error = local.status
			client.state = local.status == 401 || local.status == 403 ? .Failed : client.state
			diagnostic.result("detail", false, local.status, 0, 0, false)
			return
		}
		diagnostic.result(
			"detail",
			local.ok,
			local.ok ? 200 : local.status,
			len(local.detail.rows),
			local.detail.total,
			local.detail.has_more,
		)
		// The metadata response can arrive before its larger cover. Keep the
		// selected card's cover alive in the incoming arena until texture upload.
		local.detail.image_preview = strings.clone(
			client.detail.image_preview,
			virtual.arena_allocator(&local.detail.arena),
		)
		move_detail(&client.detail, &local.detail)
	case .Like:
		if !local.ok {
			client.like_pending = false
			client.last_http_status = local.status
			diagnostic.result("like", false, local.status, 0, 0, false)
			return
		}
		diagnostic.result("like", true, local.status, 0, 0, false)
		client.like_pending = false
		if local.source == client.detail.source && local.id == client.detail.id {
			client.detail.liked = local.liked
		}
		sync_library_membership(client, local.source, local.id, local.liked)
	case .More:
		if local.source == client.detail.source && local.id == client.detail.id {
			client.detail_loading = false
			if !local.ok {
				if local.status == 429 {
					client.page_at = time.time_add(
						time.now(),
						rate_limit_delay(client, local.retry_after),
					)
				} else if local.status >= 500 || local.status <= 0 {
					client.page_at = time.time_add(time.now(), PAGE_RETRY_BACKOFF)
				} else {
					// Transient failures wait out the backoff instead of spending
					// a retry and giving up on the rest of the page.
					client.detail.more_failures += 1
					if client.detail.more_failures >= 3 {client.detail.has_more = false}
				}
			}
			if local.ok && client.detail.ready {
				client.detail.more_failures = 0
				client.rate_limited = 0
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
			diagnostic.result(
				"more",
				local.ok,
				local.status,
				len(client.detail.rows),
				client.detail.total,
				client.detail.has_more,
			)
		}
	case .Search:
		if local.search_serial != client.search_serial {return}
		client.search_loading = false
		if !local.ok {
			client.search_error = local.status
			free_search_pages(&client.search_pages)
			delete(client.search_query)
			client.search_query = ""
			diagnostic.result("search", false, local.status, 0, 0, false)
			return
		}
		free_search_pages(&client.search_pages)
		for kind in Kind {
			client.search_pages[kind] = local.search_pages[kind]
			local.search_pages[kind] = {}
			client.search_pages[kind].items.allocator = virtual.arena_allocator(
				&client.search_pages[kind].arena,
			)
		}
		delete(client.search_query)
		client.search_query = local.search_query
		local.search_query = ""
		diagnostic.result("search", local.ok, local.status, 0, 0, false)
	}
}

stop_workers :: proc(client: ^Client) {
	if client.worker == nil {return}
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
	client.worker, client.cover_worker = nil, nil
}

// Retry a failed browser approval. The worker has already exited, so its
// channels are dropped and a fresh worker starts like it does at launch.
restart :: proc(client: ^Client) -> bool {
	if client.state != .Sign_In_Failed {return false}
	stop_workers(client)
	return start(client)
}

stop :: proc(client: ^Client) {
	diagnostic.write("library workers stopping")
	stop_workers(client)
	for &page in client.pages {free_page(&page)}
	free_detail(&client.detail)
	free_detail(&client.prev_detail)
	delete(client.detail_request_id)
	free_search_pages(&client.search_pages)
	delete(client.search_query)
	for i in 0 ..< len(client.cover_queue) {artwork.free_image(&client.cover_queue[i].image)}
	delete(client.cover_queue)
	client^ = {}
}
