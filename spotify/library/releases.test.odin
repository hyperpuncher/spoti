package library

import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
release_feed_request_uses_the_music_feed :: proc(t: ^testing.T) {
	body, ok := release_feed_request(50)
	if !testing.expect(t, ok) {return}
	request: struct {
		operationName: string,
		variables:     struct {
			offset, limit:        int,
			onlyUnPlayedItems:    bool,
			includedContentTypes: []string,
		},
		extensions:    struct {
			persistedQuery: struct {
				version:    int,
				sha256Hash: string,
			},
		},
	}
	if !testing.expect(
		t,
		json.unmarshal(body, &request, allocator = context.temp_allocator) == nil,
	) {return}
	testing.expect_value(t, request.operationName, "queryWhatsNewFeed")
	testing.expect_value(t, request.variables.offset, 50)
	testing.expect_value(t, request.variables.limit, 50)
	testing.expect(t, !request.variables.onlyUnPlayedItems)
	if testing.expect_value(t, len(request.variables.includedContentTypes), 1) {
		testing.expect_value(t, request.variables.includedContentTypes[0], "ALBUM")
	}
	testing.expect_value(t, request.extensions.persistedQuery.version, 1)
	testing.expect_value(t, request.extensions.persistedQuery.sha256Hash, RELEASE_FEED_HASH)
}

@(test)
release_feed_filters_a_week_of_music_and_owns_results :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {return}
	defer virtual.arena_destroy(&arena)
	body := `{"data":{"whatsNewFeedItems":{"totalCount":6,"pagingInfo":{"offset":0,"limit":50},"items":[
		{"content":{"__typename":"AlbumResponseWrapper","data":{"__typename":"Album","uri":"spotify:album:AAAAAAAAAAAAAAAAAAAAAA","name":"Single","albumType":"SINGLE","date":{"isoString":"2026-10-14T02:00:00+02:00"},"artists":{"items":[{"uri":"spotify:artist:CCCCCCCCCCCCCCCCCCCCCC","profile":{"name":"Artist"}}]}}}},
		{"content":{"__typename":"AlbumResponseWrapper","data":{"__typename":"Album","uri":"spotify:album:BBBBBBBBBBBBBBBBBBBBBB","name":"EP","albumType":"EP","date":{"isoString":"2026-10-07T00:00:00Z"}}}},
		{"content":{"__typename":"AlbumResponseWrapper","data":{"__typename":"Album","uri":"spotify:album:CCCCCCCCCCCCCCCCCCCCCC","name":"Old","date":{"isoString":"2026-10-06T00:00:00Z"}}}},
		{"content":{"__typename":"AlbumResponseWrapper","data":{"__typename":"Album","uri":"spotify:album:DDDDDDDDDDDDDDDDDDDDDD","name":"Future","date":{"isoString":"2026-10-15T00:00:00Z"}}}},
		{"content":{"__typename":"EpisodeResponseWrapper","data":{"__typename":"Episode","uri":"spotify:episode:EEEEEEEEEEEEEEEEEEEEEE","name":"Podcast","date":{"isoString":"2026-10-14T00:00:00Z"}}}},
		{"content":{"__typename":"AlbumResponseWrapper","data":{"__typename":"Album","uri":"spotify:album:AAAAAAAAAAAAAAAAAAAAAA","name":"Single","albumType":"SINGLE","date":{"isoString":"2026-10-14T00:00:00Z"}}}}
	]}}}`
	items, next, more, ok := parse_new_releases(
		transmute([]u8)body,
		0,
		time.unix(1791979200, 0),
		virtual.arena_allocator(&arena),
	)
	if !testing.expect(t, ok && len(items) == 3) {return}
	testing.expect_value(t, next, 6)
	testing.expect(t, !more)
	testing.expect_value(t, items[0].released_at, time.unix(1791936000, 0))
	testing.expect_value(t, items[0].kind, "Single")
	testing.expect_value(t, items[0].entry.subtitle, "Artist")
	testing.expect_value(t, items[1].kind, "EP")
	feed: Release_Feed
	defer free_release_feed(&feed)
	merge_new_releases(&feed, items[:])
	merge_new_releases(&feed, items[:])
	testing.expect_value(t, len(feed.items), 2)
	virtual.arena_destroy(&arena)
	arena = {}
	testing.expect_value(t, feed.items[0].entry.name, "Single")
	if testing.expect_value(t, len(feed.items[0].artist_links), 1) {
		testing.expect_value(t, feed.items[0].artist_links[0].name, "Artist")
		testing.expect_value(
			t,
			feed.items[0].artist_links[0].uri,
			"spotify:artist:CCCCCCCCCCCCCCCCCCCCCC",
		)
	}
	testing.expect_value(t, feed.items[1].released_at, time.unix(1791331200, 0))
	for invalid in ([]string{"{\"errors\":[{\"message\":\"PersistedQueryNotFound\"}]}", "{\"data\":{\"whatsNewFeedItems\":null}}", "{\"data\":{\"whatsNewFeedItems\":{\"totalCount\":1,\"pagingInfo\":{\"offset\":0,\"limit\":50},\"items\":[]}}}"}) {
		_, _, _, parsed := parse_new_releases(transmute([]u8)invalid, 0, time.now())
		testing.expect(t, !parsed)
	}
}

@(test)
release_feed_pages_raw_items_not_filtered_music :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	body := `{"data":{"whatsNewFeedItems":{"totalCount":2,"pagingInfo":{"offset":0,"limit":50},"items":[{"content":{"__typename":"EpisodeResponseWrapper"}}]}}}`
	items, next, more, ok := parse_new_releases(
		transmute([]u8)body,
		0,
		time.now(),
		virtual.arena_allocator(&arena),
	)
	testing.expect(t, ok && len(items) == 0 && next == 1 && more)
	_, _, _, ok = parse_new_releases(
		transmute([]u8)body,
		50,
		time.now(),
		virtual.arena_allocator(&arena),
	)
	testing.expect(t, !ok, "a mismatched offset cannot repeat a page")
}

@(test)
release_feed_stops_on_rate_limit_and_resumes_only_when_opened :: proc(t: ^testing.T) {
	fake_worker: thread.Thread
	client := Client {
		state  = .Failed,
		worker = &fake_worker,
	}
	client.requests, _ = chan.create_buffered(chan.Chan(Request), 4, context.allocator)
	defer chan.destroy(client.requests)
	defer free_release_feed(&client.release_feed)
	// A personal Web API error or wait must not block the native feed.
	client.page_at = time.time_add(time.now(), time.Hour)
	open_releases(&client)
	request, received := chan.try_recv(client.requests)
	if !testing.expect(t, received) {return}
	testing.expect_value(t, request.kind, Request_Kind.Release_Feed)
	free_request(request)
	advance_releases(&client)
	_, received = chan.try_recv(client.requests)
	testing.expect(t, !received)
	apply(&client, Result{kind = .Release_Feed, ok = true, next_offset = 50, has_more = true})
	client.release_feed.open = false
	advance_releases(&client)
	_, received = chan.try_recv(client.requests)
	testing.expect(t, !received, "a closed feed must not request another page")
	open_releases(&client)
	request, received = chan.try_recv(client.requests)
	if !testing.expect(t, received) {return}
	testing.expect_value(t, request.offset, 50)
	free_request(request)
	apply(&client, Result{kind = .Release_Feed, status = 429, retry_after = 2})
	testing.expect(t, client.release_feed.done && !client.release_feed.pending)
	open_releases(&client)
	_, received = chan.try_recv(client.requests)
	testing.expect(t, !received, "opening the feed cannot bypass Retry-After")
	client.release_feed.wait_until = {}
	advance_releases(&client)
	_, received = chan.try_recv(client.requests)
	testing.expect(t, !received, "the feed must not retry automatically")
	open_releases(&client)
	request, received = chan.try_recv(client.requests)
	if !testing.expect(t, received) {return}
	testing.expect_value(t, request.offset, 50)
	free_request(request)
	apply(&client, Result{kind = .Release_Feed, ok = true, next_offset = 75})
	testing.expect(t, client.release_feed.done && client.release_feed.error == 0)
}

@(test)
release_feed_save_updates_only_after_confirmation :: proc(t: ^testing.T) {
	fake_worker: thread.Thread
	client := Client {
		state  = .Ready,
		worker = &fake_worker,
	}
	client.requests, _ = chan.create_buffered(chan.Chan(Request), 4, context.allocator)
	defer {
		for request in chan.try_recv(client.requests) {free_request(request)}
		chan.destroy(client.requests)
		for pending in client.likes_pending {delete(pending.id)}
		delete(client.likes_pending)
	}
	first :: "AAAAAAAAAAAAAAAAAAAAAA"
	second :: "BBBBBBBBBBBBBBBBBBBBBB"
	testing.expect(t, toggle_like(&client, .Album, first, true))
	testing.expect(t, like_pending(&client, .Album, first))
	testing.expect(t, !like_pending(&client, .Album, second))
	testing.expect(t, !toggle_like(&client, .Album, first, true))
	testing.expect(t, toggle_like(&client, .Album, second, true))
	defer free_release_feed(&client.release_feed)
	page := &client.pages[.Albums]
	if !testing.expect(t, virtual.arena_init_growing(&page.arena) == nil) {return}
	defer free_page(page)
	page.ready = true
	page.items = make([dynamic]Entry, virtual.arena_allocator(&page.arena))
	merge_new_releases(
		&client.release_feed,
		[]New_Release {
			{
				entry = {name = "Release", uri = "spotify:album:AAAAAAAAAAAAAAAAAAAAAA"},
				kind = "Single",
			},
		},
	)
	apply(
		&client,
		Result {
			kind = .Like,
			source = .Album,
			id = strings.clone("AAAAAAAAAAAAAAAAAAAAAA"),
			liked = true,
			status = 403,
		},
	)
	testing.expect(t, !client.release_feed.items[0].entry.saved)
	testing.expect_value(t, len(page.items), 0)
	testing.expect(t, !like_pending(&client, .Album, first))
	testing.expect(t, like_pending(&client, .Album, second))
	testing.expect(t, toggle_like(&client, .Album, first, true))
	apply(
		&client,
		Result {
			kind = .Like,
			source = .Album,
			id = strings.clone("AAAAAAAAAAAAAAAAAAAAAA"),
			liked = true,
			ok = true,
			status = 200,
		},
	)
	testing.expect(t, client.release_feed.items[0].entry.saved)
	testing.expect(t, !like_pending(&client, .Album, first))
	testing.expect(t, like_pending(&client, .Album, second))
	if !testing.expect_value(t, len(page.items), 1) {return}
	testing.expect_value(t, page.items[0].name, "Release")
	apply(
		&client,
		Result {
			kind = .Like,
			source = .Album,
			id = strings.clone("AAAAAAAAAAAAAAAAAAAAAA"),
			liked = false,
			ok = true,
			status = 200,
		},
	)
	testing.expect(t, !client.release_feed.items[0].entry.saved)
	testing.expect_value(t, len(page.items), 0)
}
