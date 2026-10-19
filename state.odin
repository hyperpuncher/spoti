// Persisted app state as one JSON document: preferences (window chrome, tab,
// sort) and session state (pins, recents, resume, API retry deadline).
// Never store credentials, tokens or signed URLs. Playlist URIs are the user's
// own pins and play history. Enum names keep the file readable and stable
// across reorder; a corrupt file falls back to defaults, so it can never
// stop the app from opening.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import connect "spotify/connect"
import library "spotify/library"

DEFAULT_SIDEBAR_WIDTH :: f32(360)
DEFAULT_VOLUME :: f32(0.5)
STATE_FILE :: "state.json"
MAX_PINNED :: 32
MAX_RECENT :: 60

// Everything the footer resumes: display strings plus both links. Future
// resume data lands inside this object instead of new top-level keys.
Last_Played :: struct {
	track:        string, // spotify:track:<id>
	title:        string,
	artist:       string, // joined display names
	cover:        string,
	album:        string,
	album_uri:    string, // spotify:album:<id>
	first_artist: string,
	artist_uri:   string, // spotify:artist:<id>
	queue:        [dynamic]Play_Item, // loaded metadata; moved to playback on restore
	queue_index:  int,
	collection:   string, // playing source, independent of the browsed page
	shuffle:      bool,
}

State :: struct {
	connect_device:    string, // public persistent device identity, not a credential
	sidebar_width:     f32,
	volume:            f32,
	tab:               library.Kind,
	sort:              [library.Kind]Sort, // per-tab card order
	pinned:            [dynamic]string, // pin order; drawn first
	recent:            [dynamic]string, // most recently played first
	last_played:       Last_Played, // footer resume
	last_collection:   string, // spotify:<source>:<id> reopened on launch
	last_name:         string, // collection name for the optimistic header
	last_saved:        bool, // membership of that collection, for the hero heart
	web_api_resume_ns: i64, // Unix nanoseconds; shared Web API retry deadline
}

free_state :: proc(app_state: ^State) {
	for uri in app_state.pinned {delete(uri)}
	for uri in app_state.recent {delete(uri)}
	delete(app_state.pinned)
	delete(app_state.recent)
	delete(app_state.last_played.track)
	delete(app_state.last_played.title)
	delete(app_state.last_played.artist)
	delete(app_state.last_played.cover)
	delete(app_state.last_played.album)
	delete(app_state.last_played.album_uri)
	delete(app_state.last_played.first_artist)
	delete(app_state.last_played.artist_uri)
	free_play_queue(&app_state.last_played.queue)
	delete(app_state.last_played.collection)
	delete(app_state.last_collection)
	delete(app_state.last_name)
	delete(app_state.connect_device)
	app_state^ = {}
}

// Card order per library tab. Spotify's own order leads with the newest
// additions on every tab; recently played uses local play history, so both
// options cost nothing.
Sort :: enum {
	Default, // what Spotify returns
	Played, // recently played first; unplayed last
}

SORT_NAMES := [Sort]string {
	.Default = "Recently added",
	.Played  = "Recently played",
}

sort_name :: proc(sort: Sort) -> string {
	return SORT_NAMES[sort]
}

parse_state :: proc(data: string, allocator := context.allocator) -> State {
	// Defaults first, so missing keys behave like the old absent lines.
	loaded := default_state()
	if json.unmarshal_string(data, &loaded, allocator = allocator) != nil {
		free_state(&loaded)
		return default_state()
	}
	sanitize_state(&loaded)
	return loaded
}

// The file is our own output, but clamps and prefix checks keep a
// hand-edited or truncated file from breaking layout, playback or calls.
// Unknown enum names already decode as their zero values, which match the
// historical defaults.
sanitize_state :: proc(app_state: ^State) {
	if !connect.valid_id(app_state.connect_device) {
		delete(app_state.connect_device)
		app_state.connect_device = ""
	}
	app_state.sidebar_width = clamp(app_state.sidebar_width, SIDEBAR_MIN, SIDEBAR_MAX)
	app_state.volume = clamp(app_state.volume, 0, 1)
	app_state.web_api_resume_ns = max(0, app_state.web_api_resume_ns)
	prune_strings(&app_state.pinned, MAX_PINNED)
	prune_strings(&app_state.recent, MAX_RECENT)
	clear_unless_uri(
		&app_state.last_collection,
		"spotify:playlist:",
		"spotify:album:",
		"spotify:artist:",
	)
	cap_string(&app_state.last_name, 256)
	played := &app_state.last_played
	clear_unless_uri(&played.track, "spotify:track:")
	cap_string(&played.title, 256)
	cap_string(&played.artist, 256)
	clear_unless_cover(&played.cover)
	cap_string(&played.album, 256)
	clear_unless_uri(&played.album_uri, "spotify:album:")
	cap_string(&played.first_artist, 256)
	clear_unless_uri(&played.artist_uri, "spotify:artist:")
	clear_unless_uri(&played.collection, "spotify:playlist:", "spotify:album:", "spotify:artist:")
	valid_queue := played.queue_index >= 0 && played.queue_index < len(played.queue)
	for &item in played.queue {
		clear_unless_uri(&item.uri, "spotify:track:")
		if item.uri == "" {valid_queue = false}
		cap_string(&item.artist, 256)
		cap_string(&item.album, 256)
		clear_unless_uri(&item.album_uri, "spotify:album:")
		clear_unless_cover(&item.cover)
		for &link in item.artist_links {
			cap_string(&link.name, 256)
			clear_unless_uri(&link.uri, "spotify:artist:")
		}
	}
	if valid_queue {valid_queue = played.queue[played.queue_index].uri == played.track}
	if !valid_queue {free_play_queue(&played.queue); played.queue_index = 0}
}

// Only bounded HTTPS artwork URLs belong in saved playback metadata.
clear_unless_cover :: proc(cover: ^string) {
	if strings.has_prefix(cover^, "https://") && len(cover^) <= 512 {return}
	delete(cover^)
	cover^ = ""
}

// Blanks an owned string that outgrows its bound.
cap_string :: proc(value: ^string, cap: int) {
	if len(value^) >= cap {
		delete(value^)
		value^ = ""
	}
}

// Blanks an owned URI unless it carries one of the expected prefixes.
clear_unless_uri :: proc(uri: ^string, prefixes: ..string) {
	if len(uri^) == 0 {return}
	if len(uri^) < 128 {
		for prefix in prefixes {
			if strings.has_prefix(uri^, prefix) {return}
		}
	}
	delete(uri^)
	uri^ = ""
}

// Drops empties and caps the length, keeping the surviving order.
prune_strings :: proc(list: ^[dynamic]string, cap: int) {
	kept := 0
	for i in 0 ..< len(list) {
		if len(list[i]) == 0 || kept >= cap {
			delete(list[i])
			continue
		}
		list[kept] = list[i]
		kept += 1
	}
	resize(list, kept)
}

format_state :: proc(app_state: ^State, allocator := context.allocator) -> string {
	data, err := json.marshal(app_state^, {pretty = true, use_enum_names = true}, allocator)
	if err != nil {return ""}
	return string(data)
}

// Borrow the reopened collection's card, never the footer's track artwork.
// Without a matching card, keep the saved name and show a placeholder.
state_collection_preview :: proc(app_state: ^State, client: ^library.Client) -> library.Entry {
	for page in client.pages {
		for entry in page.items {
			if entry.uri == app_state.last_collection {return entry}
		}
	}
	return {
		name = app_state.last_name,
		uri = app_state.last_collection,
		saved = app_state.last_saved,
	}
}

state_is_pinned :: proc(app_state: ^State, uri: string) -> bool {
	for pinned in app_state.pinned {if pinned == uri {return true}}
	return false
}

state_rank :: proc(list: [dynamic]string, uri: string) -> int {
	for entry, index in list {if entry == uri {return index}}
	return max(int)
}

// Returns the new pinned state.
state_toggle_pin :: proc(app_state: ^State, uri: string) -> bool {
	if len(uri) == 0 {return false}
	for pinned, index in app_state.pinned {
		if pinned != uri {continue}
		ordered_remove(&app_state.pinned, index)
		delete(pinned)
		return false
	}
	if len(app_state.pinned) < MAX_PINNED {
		append(&app_state.pinned, strings.clone(uri))
		return true
	}
	return false
}

state_note_recent :: proc(app_state: ^State, uri: string) {
	if len(uri) == 0 {return}
	for recent, index in app_state.recent {
		if recent != uri {continue}
		if index > 0 {
			ordered_remove(&app_state.recent, index)
			inject_at(&app_state.recent, 0, recent)
		}
		return
	}
	if len(app_state.recent) >= MAX_RECENT {
		delete(app_state.recent[len(app_state.recent) - 1])
		resize(&app_state.recent, MAX_RECENT - 1)
	}
	inject_at(&app_state.recent, 0, strings.clone(uri))
}

state_directory :: proc() -> (dir: string, ok: bool) {
	base, err := os.user_state_dir(context.allocator)
	if err != nil {return "", false}
	defer delete(base)
	dir = fmt.aprintf("%s/spoti", base)
	directory_error := os.make_directory_all(dir)
	if directory_error != nil && directory_error != .Exist {
		delete(dir)
		return "", false
	}
	return dir, true
}

state_path :: proc() -> (path: string, ok: bool) {
	dir, has_dir := state_directory()
	if !has_dir {return "", false}
	defer delete(dir)
	return fmt.aprintf("%s/%s", dir, STATE_FILE), true
}

default_state :: proc() -> State {
	return State{sidebar_width = DEFAULT_SIDEBAR_WIDTH, volume = DEFAULT_VOLUME, tab = .Playlists}
}

load_state :: proc() -> State {
	path, ok := state_path()
	if !ok {return default_state()}
	defer delete(path)
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {return default_state()}
	return parse_state(string(data))
}

save_state :: proc(app_state: ^State) {
	path, ok := state_path()
	if !ok {return}
	defer delete(path)
	data := format_state(app_state)
	defer delete(data)
	if len(data) == 0 {return}
	// A crash mid-write must not leave a truncated file behind.
	tmp := fmt.aprintf("%s.tmp", path)
	defer delete(tmp)
	if os.write_entire_file(tmp, transmute([]u8)data) == nil {
		os.rename(tmp, path)
	} else {
		os.remove(tmp)
	}
}
