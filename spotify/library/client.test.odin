package library

import oauth "../oauth"
import "core:mem/virtual"
import "core:strings"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
loaded_detail_retains_selected_card_cover :: proc(t: ^testing.T) {
	client: Client
	if virtual.arena_init_growing(&client.detail.arena) != nil {testing.fail_now(t, "arena")}
	preview_allocator := virtual.arena_allocator(&client.detail.arena)
	client.detail.image_preview = strings.clone("https://i.scdn.co/image/card", preview_allocator)
	client.detail.header_pending = true
	client.detail_request_id = strings.clone("album")
	client.detail_request_source = .Album
	client.detail_loading = true
	defer {
		free_detail(&client.detail)
		delete(client.detail_request_id)
	}

	incoming: Detail
	if virtual.arena_init_growing(&incoming.arena) != nil {testing.fail_now(t, "arena")}
	allocator := virtual.arena_allocator(&incoming.arena)
	incoming.ready = true
	incoming.id = strings.clone("album", allocator)
	incoming.source = .Album
	incoming.image = strings.clone("https://i.scdn.co/image/large", allocator)
	incoming.image_small = strings.clone("https://i.scdn.co/image/small", allocator)
	incoming.rows = make([dynamic]Track_Row, 0, 1, allocator)
	append(&incoming.rows, clone_row(Track_Row{name = "First"}, allocator))
	incoming.albums.items = make([dynamic]Entry, 0, 1, allocator)
	append(&incoming.albums.items, clone_entry(Entry{name = "First release"}, allocator))
	apply(
		&client,
		Result {
			kind = .Detail,
			source = .Album,
			id = strings.clone("album"),
			detail = incoming,
			ok = true,
			status = 200,
		},
	)

	testing.expect(
		t,
		!client.detail_loading && client.detail.ready && !client.detail.header_pending,
	)
	testing.expect_value(t, client.detail.image_preview, "https://i.scdn.co/image/card")
	testing.expect_value(t, client.detail.image, "https://i.scdn.co/image/large")
	testing.expect_value(t, client.detail.image_small, "https://i.scdn.co/image/small")

	more := Result {
		kind   = .More,
		source = .Album,
		id     = strings.clone("album"),
		ok     = true,
	}
	if virtual.arena_init_growing(&more.rows_arena) != nil {testing.fail_now(t, "arena")}
	more_allocator := virtual.arena_allocator(&more.rows_arena)
	more.rows = make([dynamic]Track_Row, 0, 1, more_allocator)
	append(&more.rows, clone_row(Track_Row{name = "Second"}, more_allocator))
	apply(&client, more)
	testing.expect_value(t, len(client.detail.rows), 2)
	testing.expect_value(t, client.detail.rows[0].name, "First")
	testing.expect_value(t, client.detail.rows[1].name, "Second")

	// An old request from another source must not append, even if its id matches.
	client.detail_loading = true
	stale := Result {
		kind   = .More,
		source = .Playlist,
		id     = strings.clone("album"),
		ok     = true,
	}
	if virtual.arena_init_growing(&stale.rows_arena) != nil {testing.fail_now(t, "arena")}
	stale_allocator := virtual.arena_allocator(&stale.rows_arena)
	stale.rows = make([dynamic]Track_Row, 0, 1, stale_allocator)
	append(&stale.rows, clone_row(Track_Row{name = "Wrong source"}, stale_allocator))
	apply(&client, stale)
	testing.expect_value(t, len(client.detail.rows), 2)
	testing.expect(t, client.detail_loading)

	// Discography arrays must also grow through the moved detail's arena.
	append(
		&client.detail.albums.items,
		clone_entry(Entry{name = "Second release"}, virtual.arena_allocator(&client.detail.arena)),
	)
	testing.expect_value(t, len(client.detail.albums.items), 2)
	testing.expect_value(t, client.detail.albums.items[0].name, "First release")
	testing.expect_value(t, client.detail.albums.items[1].name, "Second release")
}

@(test)
index_pagination_grows_after_arena_ownership_transfer :: proc(t: ^testing.T) {
	client: Client
	destination := &client.pages[.Albums]
	defer free_page(destination)
	for batch in 0 ..< 3 {
		page: Page
		if virtual.arena_init_growing(&page.arena) != nil {testing.fail_now(t, "arena")}
		allocator := virtual.arena_allocator(&page.arena)
		page.ready = true
		page.items = make([dynamic]Entry, 0, 36, allocator)
		for _ in 0 ..< 36 {append(&page.items, clone_entry(Entry{name = "Album"}, allocator))}
		page.next_offset = (batch + 1) * 36
		page.total = 108
		page.has_more = batch < 2
		apply(&client, Result{kind = .Index, list = .Albums, page = page, ok = true})
		testing.expect_value(t, len(destination.items), (batch + 1) * 36)
		testing.expect_value(t, destination.items[0].name, "Album")
		testing.expect_value(t, destination.items[len(destination.items) - 1].name, "Album")
	}
	testing.expect(t, !destination.has_more && destination.next_offset == 108)
}

@(test)
discography_selection_clones_metadata_before_releasing_detail :: proc(t: ^testing.T) {
	client: Client
	if virtual.arena_init_growing(&client.detail.arena) != nil {testing.fail_now(t, "arena")}
	allocator := virtual.arena_allocator(&client.detail.arena)
	entry := clone_entry(
		Entry {
			name = "Release",
			uri = "spotify:album:album",
			subtitle = "2026",
			image = "https://i.scdn.co/image/card",
			total = 12,
		},
		allocator,
	)
	fake_worker: thread.Thread
	client.worker = &fake_worker
	client.state = .Ready
	requests, err := chan.create_buffered(chan.Chan(Request), 1, context.allocator)
	if err != nil {testing.fail_now(t, "channel")}
	client.requests = requests
	defer {
		chan.destroy(requests)
		free_detail(&client.detail)
		delete(client.detail_request_id)
	}

	opened := open_detail(&client, .Album, entry.uri[len("spotify:album:"):], entry)
	request, received := chan.try_recv(requests)
	if received {free_request(request)}
	testing.expect(t, opened && received && client.detail_loading && client.detail.ready)
	testing.expect(t, client.detail.header_pending && detail_loading_visible(&client))
	testing.expect_value(t, client.detail.name, "Release")
	testing.expect_value(t, client.detail_request_id, "album")
	testing.expect_value(t, client.detail.image_preview, "https://i.scdn.co/image/card")
	// Jumping to singles must not drain albums that are outside the viewport.
	client.detail.source = .Artist
	client.detail_loading = false
	client.detail.has_more, client.detail.albums.has_more = true, true
	client.detail.singles = {
		has_more    = true,
		next_offset = 10,
	}
	testing.expect(t, more_rows(&client, .Single))
	next, queued := chan.try_recv(requests)
	defer if queued {free_request(next)}
	testing.expect(t, queued && next.group == .Single && next.offset == 10)
	apply(
		&client,
		{
			kind = .More,
			source = .Artist,
			id = strings.clone("album"),
			group = .Single,
			status = 429,
		},
	)
	testing.expect(
		t,
		!client.detail_loading &&
		client.detail.singles.error == 429 &&
		client.detail.singles.has_more,
	)
	apply(
		&client,
		{kind = .More, source = .Artist, id = strings.clone("album"), group = .Single, ok = true},
	)
	testing.expect(
		t,
		client.detail.singles.error == 0 &&
		!client.detail.singles.has_more &&
		client.detail.albums.has_more,
	)
}

@(test)
like_toggle_syncs_sidebar_membership :: proc(t: ^testing.T) {
	client: Client
	if virtual.arena_init_growing(&client.pages[.Albums].arena) != nil {
		testing.fail_now(t, "arena")
	}
	defer free_page(&client.pages[.Albums])
	page_allocator := virtual.arena_allocator(&client.pages[.Albums].arena)
	client.pages[.Albums].items = make([dynamic]Entry, 0, 2, page_allocator)
	append(
		&client.pages[.Albums].items,
		Entry{uri = strings.clone("spotify:album:gone", page_allocator)},
	)
	client.pages[.Albums].total = 1
	if virtual.arena_init_growing(&client.detail.arena) != nil {testing.fail_now(t, "arena")}
	defer free_detail(&client.detail)
	detail_allocator := virtual.arena_allocator(&client.detail.arena)
	client.detail.source = .Album
	client.detail.id = strings.clone("fresh", detail_allocator)
	client.detail.name = strings.clone("Fresh Album", detail_allocator)
	client.detail.subtitle = strings.clone("Some Artist", detail_allocator)
	client.detail.image = strings.clone("https://i.scdn.co/image/fresh", detail_allocator)
	client.detail.total = 10

	// Unlike drops the card and decrements the server total.
	sync_library_membership(&client, .Album, "gone", false)
	testing.expect_value(t, len(client.pages[.Albums].items), 0)
	testing.expect_value(t, client.pages[.Albums].total, 0)

	// Like prepends the card built from the open detail when it is current.
	sync_library_membership(&client, .Album, "fresh", true)
	testing.expect_value(t, len(client.pages[.Albums].items), 1)
	testing.expect_value(t, client.pages[.Albums].items[0].uri, "spotify:album:fresh")
	testing.expect_value(t, client.pages[.Albums].items[0].name, "Fresh Album")
	testing.expect_value(t, client.pages[.Albums].total, 1)

	// Repeating either direction is a no-op.
	sync_library_membership(&client, .Album, "fresh", true)
	testing.expect_value(t, len(client.pages[.Albums].items), 1)
	sync_library_membership(&client, .Album, "missing", false)
	testing.expect_value(t, len(client.pages[.Albums].items), 1)

	// Liked Songs has no sidebar membership to sync.
	sync_library_membership(&client, .Liked, "anything", true)
	testing.expect_value(t, len(client.pages[.Playlists].items), 0)
}

@(test)
failed_worker_requests_keep_owned_identity_and_finish_once :: proc(t: ^testing.T) {
	client := Client {
		cancel = true,
	}
	client.results, _ = chan.create_buffered(chan.Chan(Result), 1, context.allocator)
	defer chan.destroy(client.results)
	tokens := oauth.Tokens {
		expires_at = time.unix(1, 0),
	}
	streaming: oauth.Tokens
	// Expired tokens plus cancellation cannot start auth or make a request.
	for kind in Request_Kind {
		if kind == .Auth {continue}
		request := Request {
			kind          = kind,
			source        = .Playlist,
			list          = .Albums,
			group         = .Single,
			id            = strings.clone("page"),
			query         = strings.clone("query"),
			cursor        = strings.clone("cursor"),
			account       = strings.clone("account"),
			command_state = strings.clone("context"),
			serial        = 7,
			playlist_id   = strings.clone("playlist"),
			playlist_name = strings.clone("name"),
			item_uri      = strings.clone("spotify:track:item"),
			device_id     = strings.clone("device"),
			command       = .Next,
			liked         = true,
			refresh       = true,
		}
		handle(&client, &tokens, &streaming, request) // consumes the owned request
		result, received := chan.try_recv(client.results)
		if !testing.expect(t, received) {continue}
		defer free_result(result)
		testing.expect(t, !result.ok && result.kind == kind)
		testing.expect_value(t, result.status, kind == .Release_Feed ? PLAYLIST_AUTH_REQUIRED : -1)
		testing.expect_value(t, result.id, "page")
		testing.expect_value(t, result.query, "query")
		testing.expect_value(t, result.serial, u64(7))
		testing.expect_value(t, result.playlist_id, "playlist")
		testing.expect_value(t, result.playlist_name, "name")
		testing.expect_value(t, result.item_uri, "spotify:track:item")
		_, extra := chan.try_recv(client.results)
		testing.expect(t, !extra)
	}
	// Rejection leaves the write idle and must release its owned strings.
	for remove in ([]bool{false, true}) {
		testing.expect(
			t,
			!queue_playlist_write(&client, "playlist", "name", "spotify:track:item", remove),
		)
		testing.expect(t, !client.write_pending)
	}
	// Partially created workers still own their queues, even with no thread.
	client.requests, _ = chan.create_buffered(chan.Chan(Request), 1, context.allocator)
	_ = chan.send(client.requests, Request{kind = .Detail, id = strings.clone("queued")})
	fake_worker: thread.Thread
	client.worker, client.state = &fake_worker, .Ready
	for remove in ([]bool{false, true}) {
		testing.expect(
			t,
			!queue_playlist_write(&client, "playlist", "name", "spotify:track:item", remove),
		)
	}
	client.worker = nil
	_ = chan.send(client.results, Result{kind = .Detail, id = strings.clone("reply")})
	stop_workers(&client)
	testing.expect(t, client.requests.impl == nil && client.results.impl == nil)
	// A closed result queue and a result-only request must release owned input.
	client.results, _ = chan.create_buffered(chan.Chan(Result), 1, context.allocator)
	chan.close(client.results)
	for kind in ([]Request_Kind{.Search, .Release_Feed, .Auth}) {
		handle(
			&client,
			&tokens,
			&streaming,
			Request{kind = kind, id = strings.clone("closed"), query = strings.clone("query")},
		)
	}
}

@(test)
transient_page_failure_keeps_the_session_usable :: proc(t: ^testing.T) {
	client: Client
	defer stop(&client)
	client.state = .Ready
	client.pages[.Albums].ready = true
	client.pending[.Albums] = true

	// A rate-limited page backs off but must not freeze covers or search,
	// which both require a ready session.
	apply(&client, Result{kind = .Index, list = .Albums, status = 429})
	testing.expect_value(t, client.state, State.Ready)
	testing.expect(t, !client.pending[.Albums] && !client.failed)
	testing.expect(t, time.since(client.page_at) < 0)

	// A failed first load still ends the loading state so the tab retries.
	client.remaining_initial = 1
	apply(&client, Result{kind = .Index, list = .Playlists, status = 503})
	testing.expect_value(t, client.remaining_initial, 0)
	testing.expect_value(t, client.state, State.Ready)

	// Authorization failures still stop the session.
	apply(&client, Result{kind = .Index, list = .Artists, status = 401})
	testing.expect_value(t, client.state, State.Failed)
	testing.expect(t, client.failed)
}

@(test)
detail_buffer_replays_last_page_without_requests :: proc(t: ^testing.T) {
	client: Client
	defer {
		free_detail(&client.detail)
		free_detail(&client.prev_detail)
		delete(client.detail_request_id)
	}
	make_rows := proc(id, name: string, total: int) -> Detail {
		detail: Detail
		if virtual.arena_init_growing(&detail.arena) != nil {return {}}
		allocator := virtual.arena_allocator(&detail.arena)
		detail.ready = true
		detail.source = .Playlist
		detail.id = strings.clone(id, allocator)
		detail.name = strings.clone(name, allocator)
		detail.total = total
		detail.rows = make([dynamic]Track_Row, 0, 2, allocator)
		append(
			&detail.rows,
			clone_row(Track_Row{name = strings.clone("one", allocator)}, allocator),
		)
		append(
			&detail.rows,
			clone_row(Track_Row{name = strings.clone("two", allocator)}, allocator),
		)
		return detail
	}
	client.detail = make_rows("p", "Playlist P", 100)
	client.detail.generation = 7
	detail_buffer_stash(&client)
	testing.expect(t, len(client.detail.rows) == 0)
	testing.expect_value(t, len(client.prev_detail.rows), 2)

	// Leaving for another page and coming back restores the buffered rows.
	client.detail = make_rows("q", "Playlist Q", 40)
	for &row, i in client.detail.rows {row.name = i == 0 ? "three" : "four"}
	testing.expect(
		t,
		detail_buffer_take(
			&client,
			.Playlist,
			"p",
			Entry{uri = "spotify:playlist:p", total = 100},
		),
	)
	testing.expect_value(t, len(client.detail.rows), 2)
	testing.expect_value(t, client.detail.rows[0].name, "one")
	testing.expect_value(t, client.detail.generation, 8)
	testing.expect_value(t, client.detail_request_id, "p")
	testing.expect(t, !client.detail_loading)
	// Ping-pong: the outgoing page is banked for the trip back.
	testing.expect_value(t, len(client.prev_detail.rows), 2)
	testing.expect_value(t, client.prev_detail.id, "q")

	// Unknown pages, stale buffers and changed totals fall through.
	testing.expect(
		t,
		!detail_buffer_take(&client, .Playlist, "zzz", Entry{uri = "spotify:playlist:zzz"}),
	)
	client.prev_at = time.time_add(time.now(), -(PAGE_TTL + time.Minute))
	testing.expect(
		t,
		!detail_buffer_take(
			&client,
			.Playlist,
			"q",
			Entry{uri = "spotify:playlist:q", total = 40},
		),
	)
	client.prev_at = time.now()
	testing.expect(
		t,
		!detail_buffer_take(
			&client,
			.Playlist,
			"q",
			Entry{uri = "spotify:playlist:q", total = 41},
		),
	)
	testing.expect(
		t,
		detail_buffer_take(&client, .Playlist, "q", Entry{uri = "spotify:playlist:q", total = 40}),
	)
	testing.expect_value(t, client.detail.rows[0].name, "three")
}
