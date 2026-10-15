// The saved playlist list over the streaming session. Decorated rootlist
// rows include Spotify-owned playlists that the personal Web API omits.
package library

import ap "../ap"
import "core:encoding/hex"
import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:strings"

ROOTLIST_PAGE_SIZE :: 36
ROOTLIST_ACCOUNT_KEY :: "rootlist-account"

// The account marker locates the same cached native page before authorization.
// It contains no credential; the response itself keeps its existing cache key.
cached_rootlist :: proc() -> (page: Page, ok: bool) {
	account, known := cache_read("api", ROOTLIST_ACCOUNT_KEY, API_STALE)
	defer delete(account)
	if !known || !safe_id(string(account[:]), account = true) {return}
	body, found := cache_read("api", rootlist_address(string(account[:]), 0), API_STALE)
	defer delete(body)
	if !found {return}
	return parse_rootlist(body[:], string(account[:]), 0)
}

rootlist_address :: proc(account: string, offset: int) -> string {
	encoded := net.percent_encode(account, context.temp_allocator)
	return fmt.aprintf(
		"https://spclient.wg.spotify.com/playlist/v2/user/%s/rootlist?decorate=revision,attributes,length,owner,capabilities,status_code&from=%d&length=%d",
		encoded,
		offset,
		ROOTLIST_PAGE_SIZE,
		allocator = context.temp_allocator,
	)
}

fetch_rootlist :: proc(
	access, account: string,
	offset: int,
	reuse: rawptr = nil,
	refresh: bool = false,
) -> (
	page: Page,
	status: int,
	ok: bool,
) {
	if !safe_id(account, account = true) || offset < 0 || offset > 1_000_000 {return}
	body, code, fetched := api_get(
		access,
		rootlist_address(account, offset),
		1024 * 1024,
		reuse,
		ttl = PAGE_TTL,
		refresh = refresh,
	)
	defer delete(body)
	if !fetched || code != 200 {return {}, code, false}
	page, ok = parse_rootlist(body[:], account, offset)
	if ok && offset == 0 {cache_write("api", ROOTLIST_ACCOUNT_KEY, transmute([]u8)account)}
	return page, ok ? 200 : PLAYLIST_INVALID_RESPONSE, ok
}

parse_rootlist :: proc(body: []u8, account: string, offset: int) -> (result: Page, ok: bool) {
	page: Page
	if offset < 0 || offset > 1_000_000 {return}
	if virtual.arena_init_growing(&page.arena) != nil {return}
	defer if !ok {free_page(&page)}
	contents, found, valid := ap.get_bytes(body, 5)
	if !found || !valid {return}
	position, present, readable := ap.get_number(contents, 1)
	truncated, marked, decoded := ap.get_number(contents, 2)
	total, total_found, total_valid := ap.get_number(body, 2)
	if !total_found ||
	   !present ||
	   !readable ||
	   position != u64(offset) ||
	   !marked ||
	   !decoded ||
	   truncated > 1 ||
	   !total_valid ||
	   total > 1_000_000 {return}
	items := make([dynamic][]u8, context.temp_allocator)
	metadata := make([dynamic][]u8, context.temp_allocator)
	pos := 0
	for pos < len(contents) {
		field, wire, bytes, _, field_valid := ap.next_field(contents, &pos)
		if !field_valid {return}
		if field != 3 && field != 4 {continue}
		if wire != 2 {return}
		if field == 3 {append(&items, bytes)} else {append(&metadata, bytes)}
		if len(items) > ROOTLIST_PAGE_SIZE || len(metadata) > ROOTLIST_PAGE_SIZE {return}
	}
	if len(items) != len(metadata) || truncated != 0 && len(items) == 0 {return}
	allocator := virtual.arena_allocator(&page.arena)
	page.items = make([dynamic]Entry, 0, len(items), allocator)
	for item, index in items {
		uri, has_uri, uri_valid := ap.get_bytes(item, 1)
		if !has_uri || !uri_valid {return}
		// Folder markers occupy positions but are not playlist cards.
		if !strings.has_prefix(string(uri), "spotify:playlist:") {continue}
		id := string(uri)[len("spotify:playlist:"):]
		if len(id) != 22 || !safe_id(id) {return}
		attributes, _, attr_valid := ap.get_bytes(metadata[index], 2)
		owner, _, owner_valid := ap.get_bytes(metadata[index], 5)
		length, _, length_valid := ap.get_number(metadata[index], 3)
		status, _, status_valid := ap.get_number(metadata[index], 9)
		if !attr_valid ||
		   !owner_valid ||
		   !length_valid ||
		   length > 1_000_000 ||
		   !status_valid {return}
		if status != 0 && status != 400 {continue} 	// sint32 status 200
		ref, parsed := playlist_attributes(attributes)
		if !parsed {return}
		if ref.name == "" {continue}
		ref.uri, ref.owner = string(uri), Owner {
				id           = string(owner),
				display_name = string(owner),
			}
		ref.items.total = int(length)
		append_entry(&page.items, ref, allocator)
	}
	page.ready = true
	page.account = strings.clone(account, allocator)
	page.total, page.next_offset, page.has_more = int(total), offset + len(items), truncated != 0
	for &entry in page.items {entry.saved = true}
	ok = true
	return page, true
}

// ListAttributes is shared by rootlist decorations and playlist headers.
// Preserve the supplied artwork URL. Only spotify:image references are
// converted to their equivalent HTTPS image address.
playlist_attributes :: proc(body: []u8) -> (ref: Playlist_Ref, ok: bool) {
	name, _, name_valid := ap.get_bytes(body, 1)
	collaborative, _, collab_valid := ap.get_number(body, 4)
	picture, _, picture_valid := ap.get_bytes(body, 3)
	if !name_valid || !collab_valid || !picture_valid {return}
	ref.name, ref.collaborative = string(name), collaborative != 0
	images := make([dynamic]Image, context.temp_allocator)
	pos := 0
	for pos < len(body) {
		field, wire, bytes, _, valid := ap.next_field(body, &pos)
		if !valid {return}
		if field == 12 {
			if wire != 2 {return}
			key, _, key_valid := ap.get_bytes(bytes, 1)
			value, _, value_valid := ap.get_bytes(bytes, 2)
			if !key_valid || !value_valid {return}
			if string(key) == "header_image_url_desktop" &&
			   strings.has_prefix(string(value), "https://") {
				ref.banner = string(value)
			}
			continue
		}
		if field != 13 {continue}
		if wire != 2 || len(images) >= 32 {return}
		target, _, target_valid := ap.get_bytes(bytes, 1)
		url, _, url_valid := ap.get_bytes(bytes, 2)
		if !target_valid || !url_valid {return}
		address := string(url)
		if strings.has_prefix(address, "spotify:image:") {
			address = fmt.aprintf(
				"https://i.scdn.co/image/%s",
				address[len("spotify:image:"):],
				allocator = context.temp_allocator,
			)
		}
		width := 300
		switch string(target) {
		case "small":
			width = 64
		case "large":
			width = 640
		}
		append(&images, Image{url = address, width = width})
	}
	if len(images) == 0 && len(picture) == 20 {
		encoded := hex.encode(picture, context.temp_allocator)
		append(
			&images,
			Image {
				url = fmt.aprintf(
					"https://i.scdn.co/image/%s",
					string(encoded),
					allocator = context.temp_allocator,
				),
				width = 300,
			},
		)
	}
	ref.images = images[:]
	return ref, true
}
