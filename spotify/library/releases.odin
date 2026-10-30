package library

import http "../http"
import oauth "../oauth"
import session "../session"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:time"

RELEASE_PAGE_SIZE :: 50
RELEASE_INVALID_RESPONSE :: -4
// Verified with the streaming grant. Spotify can replace this query hash.
RELEASE_FEED_HASH :: "3b53dede3c6054e8b7c962dd280eb6761c5d1c82b06b039f4110d76a62b4966b"

New_Release :: struct {
	entry:        Entry,
	released_at:  time.Time,
	kind:         string, // static catalog label
	artist_links: []Artist_Link,
}

Release_Feed :: struct {
	open:        bool,
	arena:       virtual.Arena,
	items:       [dynamic]New_Release,
	offset:      int,
	pending:     bool,
	done:        bool,
	finished_at: time.Time,
	wait_until:  time.Time,
	error:       int,
}

free_release_feed :: proc(feed: ^Release_Feed) {
	virtual.arena_destroy(&feed.arena)
	feed^ = {}
}

open_releases :: proc(client: ^Client) {
	feed := &client.release_feed
	feed.open = true
	if feed.error != 0 {
		// A rate limit stops the feed. Reopening cannot bypass Retry-After.
		if time.since(feed.wait_until) < 0 {return}
		feed.done = false
		feed.error = 0
	} else if feed.done && time.since(feed.finished_at) >= PAGE_TTL {
		free_release_feed(feed)
		feed.open = true
	}
	advance_releases(client)
}

release_worker_ready :: proc(client: ^Client) -> bool {
	return(
		client.worker != nil &&
		(client.state == .Ready || client.state == .Loading || client.state == .Failed) \
	)
}

advance_releases :: proc(client: ^Client) {
	feed := &client.release_feed
	if !feed.open ||
	   feed.pending ||
	   feed.done ||
	   !release_worker_ready(client) ||
	   time.since(feed.wait_until) < 0 {return}
	request := Request {
		kind   = .Release_Feed,
		offset = feed.offset,
	}
	if queue_request(client, &request) {feed.pending = true}
}

read_release_feed :: proc(client: ^Client, tokens: ^oauth.Tokens, result: ^Result, reuse: rawptr) {
	if !authorize_session(client, tokens, interactive = false) {
		result.status = PLAYLIST_AUTH_REQUIRED
		return
	}
	account := session.account_name(tokens.access, &client.cancel)
	defer delete(account)
	if account == "" || virtual.arena_init_growing(&result.rows_arena) != nil {return}
	fetch_release_feed(tokens.access, account, result.offset, result, reuse, &client.cancel)
	if result.status == 401 &&
	   authorize_session(client, tokens, force = true, interactive = false) {
		fetch_release_feed(tokens.access, account, result.offset, result, reuse, &client.cancel)
	}
}

release_day :: proc(at: time.Time) -> string {
	year, month, day := time.date(at)
	return fmt.aprintf("%04d-%02d-%02d", year, int(month), day, allocator = context.temp_allocator)
}

parse_new_releases :: proc(
	body: []u8,
	offset: int,
	now: time.Time,
	allocator := context.allocator,
) -> (
	items: [dynamic]New_Release,
	next_offset: int,
	has_more: bool,
	ok: bool,
) {
	Album :: struct {
		kind:       string `json:"__typename"`,
		uri, name:  string,
		album_type: string `json:"albumType"`,
		date:       struct {
			iso: string `json:"isoString"`,
		},
		cover_art:  struct {
			sources: []Image,
		} `json:"coverArt"`,
		artists:    struct {
			items: []struct {
				uri:     string,
				profile: struct {
					name: string,
				},
			},
		},
		tracks:     struct {
			total: int `json:"totalCount"`,
		},
	}
	response: struct {
		errors: []struct {
			message: string,
		},
		data:   struct {
			feed: struct {
				total:  int `json:"totalCount"`,
				paging: struct {
					limit, offset: int,
				} `json:"pagingInfo"`,
				items:  []struct {
					content: struct {
						kind: string `json:"__typename"`,
						data: Album,
					},
				},
			} `json:"whatsNewFeedItems"`,
		},
	}
	if json.unmarshal(body, &response, allocator = context.temp_allocator) != nil ||
	   len(response.errors) != 0 {return}
	page := response.data.feed
	if !sane_page(page.total, len(page.items), page.paging.offset, RELEASE_PAGE_SIZE) ||
	   page.paging.offset != offset ||
	   page.paging.limit != RELEASE_PAGE_SIZE ||
	   (len(page.items) == 0 && offset < page.total) {return}
	today := release_day(now)
	cutoff := release_day(time.time_add(now, -7 * 24 * time.Hour))
	items = make([dynamic]New_Release, allocator)
	for item in page.items {
		album := item.content.data
		if item.content.kind != "AlbumResponseWrapper" ||
		   album.kind != "Album" ||
		   album.name == "" ||
		   !strings.has_prefix(album.uri, "spotify:album:") ||
		   !safe_id(album.uri[len("spotify:album:"):]) {continue}
		released_at, consumed := time.rfc3339_to_time_utc(album.date.iso)
		if consumed == 0 || consumed != len(album.date.iso) {continue}
		date := release_day(released_at)
		if date < cutoff || date > today {continue}
		artists := make([]Artist, len(album.artists.items), context.temp_allocator)
		for artist, index in album.artists.items {artists[index] = Artist {
				name = artist.profile.name,
				uri  = artist.uri,
			}}
		kind :=
			album.album_type == "EP" ? "EP" : release_kind(strings.to_lower(album.album_type, context.temp_allocator), album.tracks.total)
		append(
			&items,
			New_Release {
				entry = {
					name = strings.clone(album.name, allocator),
					uri = strings.clone(album.uri, allocator),
					image = strings.clone(cover_url(album.cover_art.sources, .Largest), allocator),
					subtitle = joined_artists(artists, allocator),
					year = release_year(date, allocator),
					total = album.tracks.total,
				},
				artist_links = artist_links_from(artists, allocator),
				released_at = released_at,
				kind = kind,
			},
		)
	}
	next_offset = offset + len(page.items)
	return items, next_offset, next_offset < page.total, true
}

release_feed_request :: proc(offset: int) -> (body: []u8, ok: bool) {
	variables := struct {
		offset, limit: int,
		only_unplayed: bool `json:"onlyUnPlayedItems"`,
		content_types: [1]string `json:"includedContentTypes"`,
	} {
		offset        = offset,
		limit         = RELEASE_PAGE_SIZE,
		content_types = {"ALBUM"},
	}
	return persisted_query_request("queryWhatsNewFeed", RELEASE_FEED_HASH, variables)
}

// The cache is account-specific and stores only validated feed responses.
// GraphQL can return errors with HTTP 200; those must never replace good data.
fetch_release_feed :: proc(
	access, account: string,
	offset: int,
	result: ^Result,
	reuse: rawptr,
	cancel: ^bool,
) {
	if !safe_id(account, account = true) || offset < 0 || offset > 1_000_000 {return}
	allocator := virtual.arena_allocator(&result.rows_arena)
	key := fmt.aprintf(
		"native-release-feed:%s:%s:%d",
		account,
		RELEASE_FEED_HASH,
		offset,
		allocator = context.temp_allocator,
	)
	if cached, found := cache_read("api", key, PAGE_TTL); found {
		defer delete(cached)
		result.new_releases, result.next_offset, result.has_more, result.ok = parse_new_releases(
			cached[:],
			offset,
			time.now(),
			allocator,
		)
		if result.ok {result.status = 200; return}
	}
	request, encoded := release_feed_request(offset)
	if !encoded {result.status = RELEASE_INVALID_RESPONSE; return}
	body, status, fetched := http.json_request(
		"POST",
		PATHFINDER_QUERY_ADDRESS,
		string(request),
		{
			bearer = access,
			limit = 2 * 1024 * 1024,
			retry_after = &result.retry_after,
			cancel = cancel,
		},
		reuse,
	)
	defer delete(body)
	result.status = status
	if !fetched || status != 200 {return}
	result.new_releases, result.next_offset, result.has_more, result.ok = parse_new_releases(
		body[:],
		offset,
		time.now(),
		allocator,
	)
	if !result.ok {result.status = RELEASE_INVALID_RESPONSE; return}
	cache_write("api", key, body[:])
}

newer_release :: proc(a, b: New_Release) -> bool {
	if a.released_at != b.released_at {return time.diff(a.released_at, b.released_at) < 0}
	return a.entry.uri < b.entry.uri
}

merge_new_releases :: proc(feed: ^Release_Feed, incoming: []New_Release) {
	if feed.items.allocator.procedure == nil {
		if virtual.arena_init_growing(&feed.arena) != nil {return}
	}
	allocator := virtual.arena_allocator(&feed.arena)
	feed.items.allocator = allocator
	for release in incoming {
		duplicate := false
		for existing in feed.items {if existing.entry.uri == release.entry.uri {duplicate = true; break}}
		if duplicate {continue}
		append(
			&feed.items,
			New_Release {
				clone_entry(release.entry, allocator),
				release.released_at,
				release.kind,
				clone_artist_links(release.artist_links, allocator),
			},
		)
	}
	slice.sort_by(feed.items[:], newer_release)
}

apply_releases :: proc(client: ^Client, result: ^Result) {
	feed := &client.release_feed
	feed.pending = false
	if !result.ok {
		feed.error = result.status != 0 ? result.status : -1
		feed.done = true
		if result.status == 429 {
			seconds := result.retry_after > 0 ? result.retry_after : 60
			feed.wait_until = time.time_add(time.now(), time.Duration(seconds) * time.Second)
		}
		return
	}
	feed.error = 0
	merge_new_releases(feed, result.new_releases[:])
	feed.offset = result.next_offset
	feed.done = !result.has_more
	if feed.done {feed.finished_at = time.now()}
}
