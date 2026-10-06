package library

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
	incoming.releases = make([dynamic]Entry, 0, 1, allocator)
	append(&incoming.releases, clone_entry(Entry{name = "First release"}, allocator))
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

	testing.expect(t, !client.detail_loading && client.detail.ready)
	testing.expect_value(t, client.detail.image_preview, "https://i.scdn.co/image/card")
	testing.expect_value(t, client.detail.image, "https://i.scdn.co/image/large")
	testing.expect_value(t, client.detail.image_small, "https://i.scdn.co/image/small")
	testing.expect_value(t, client.detail.rows.allocator.data, rawptr(&client.detail.arena))
	testing.expect_value(t, client.detail.releases.allocator.data, rawptr(&client.detail.arena))

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
		&client.detail.releases,
		clone_entry(Entry{name = "Second release"}, virtual.arena_allocator(&client.detail.arena)),
	)
	testing.expect_value(t, len(client.detail.releases), 2)
	testing.expect_value(t, client.detail.releases[0].name, "First release")
	testing.expect_value(t, client.detail.releases[1].name, "Second release")
}

@(test)
index_pagination_grows_after_arena_ownership_transfer :: proc(t: ^testing.T) {
	client: Client
	destination := &client.pages[.Albums]
	defer free_page(destination)
	first_name: rawptr
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
		if destination.items.allocator.data != rawptr(&destination.arena) {
			testing.fail_now(t, "moved array retained the source arena address")
		}
		if batch == 0 {first_name = raw_data(destination.items[0].name)}
		testing.expect_value(t, len(destination.items), (batch + 1) * 36)
		testing.expect_value(t, rawptr(raw_data(destination.items[0].name)), first_name)
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
	testing.expect_value(t, client.detail.name, "Release")
	testing.expect_value(t, client.detail_request_id, "album")
	testing.expect_value(t, client.detail.image_preview, "https://i.scdn.co/image/card")
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

	// Like appends a card built from the open detail when it is current.
	sync_library_membership(&client, .Album, "fresh", true)
	testing.expect_value(t, len(client.pages[.Albums].items), 1)
	testing.expect_value(t, client.pages[.Albums].items[0].uri, "spotify:album:fresh")
	testing.expect_value(t, client.pages[.Albums].items[0].name, "Fresh Album")
	testing.expect_value(t, len(client.pages[.Albums].items[0].added_at), 20)
	testing.expect_value(t, client.pages[.Albums].total, 1)

	// Repeating either direction is a no-op.
	sync_library_membership(&client, .Album, "fresh", true)
	testing.expect_value(t, len(client.pages[.Albums].items), 1)
	sync_library_membership(&client, .Album, "missing", false)
	testing.expect_value(t, len(client.pages[.Albums].items), 1)

	// Liked Songs has no sidebar membership to sync.
	sync_library_membership(&client, .Liked, "anything", true)
	testing.expect_value(t, len(client.pages[.Playlists].items), 0)

	kind, kind_ok := source_kind(.Playlist)
	testing.expect(t, kind_ok)
	testing.expect_value(t, kind, Kind.Playlists)
	_, liked_ok := source_kind(.Liked)
	testing.expect(t, !liked_ok)
}

@(test)
failed_sign_in_offers_retry_through_state :: proc(t: ^testing.T) {
	client: Client
	defer stop(&client)
	apply(&client, Result{kind = .Auth, auth = .Unavailable})
	testing.expect_value(t, client.state, State.Sign_In_Failed)
	apply(&client, Result{kind = .Auth, auth = .Missing_Client_ID})
	testing.expect_value(t, client.state, State.Missing_Client_ID)
	// Retry is only meaningful for a completed failed attempt.
	testing.expect(t, !restart(&client))
}

@(test)
rate_limit_backoff_honors_retry_after_and_escalates :: proc(t: ^testing.T) {
	client: Client
	// The server's Retry-After wins, and any rejection advances the escalation.
	testing.expect_value(t, rate_limit_delay(&client, 30), 30 * time.Second)
	testing.expect_value(t, rate_limit_delay(&client, 0), PAGE_RATE_LIMIT_BACKOFF * 2)
	testing.expect_value(t, rate_limit_delay(&client, 0), PAGE_RATE_LIMIT_BACKOFF * 4)
	testing.expect_value(t, rate_limit_delay(&client, 0), PAGE_RATE_LIMIT_BACKOFF * 8)
	testing.expect_value(t, rate_limit_delay(&client, 0), PAGE_RATE_LIMIT_BACKOFF * 8)
	// A successful page clears the streak.
	client.rate_limited = 0
	testing.expect_value(t, rate_limit_delay(&client, 0), PAGE_RATE_LIMIT_BACKOFF)
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
