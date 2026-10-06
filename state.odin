// Persisted app state: preferences (window chrome, tab, sort) and session
// state (pins, recents, resume). Only UI state is stored, never credentials,
// tokens or signed URLs. Playlist URIs are the user's own pins and play
// history.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import library "spotify/library"

DEFAULT_SIDEBAR_WIDTH :: f32(360)
DEFAULT_VOLUME :: f32(0.5)
STATE_FILE :: "state"
MAX_PINNED :: 32
MAX_RECENT :: 60

State :: struct {
	sidebar_width:   f32,
	volume:          f32,
	tab:             library.Kind,
	sort:            [library.Kind]Sort, // per-tab card order
	pinned:          [dynamic]string, // pin order; drawn first
	recent:          [dynamic]string, // most recently played first
	last_track:      string, // last played track URI, resumed on launch
	last_title:      string, // track title for the footer
	last_artist:     string, // track artists for the footer
	last_cover:      string, // track cover URL
	last_collection: string, // spotify:<source>:<id> reopened on launch
	last_name:       string, // collection name for the optimistic header
}

free_state :: proc(app_state: ^State) {
	for uri in app_state.pinned {delete(uri)}
	for uri in app_state.recent {delete(uri)}
	delete(app_state.pinned)
	delete(app_state.recent)
	delete(app_state.last_track)
	delete(app_state.last_title)
	delete(app_state.last_artist)
	delete(app_state.last_cover)
	delete(app_state.last_collection)
	delete(app_state.last_name)
	app_state^ = {}
}

state_tab_name :: proc(kind: library.Kind) -> string {
	#partial switch kind {
	case .Albums:
		return "albums"
	case .Artists:
		return "artists"
	}
	return "playlists"
}

state_tab_kind :: proc(name: string) -> library.Kind {
	switch name {
	case "albums":
		return .Albums
	case "artists":
		return .Artists
	case:
		return .Playlists
	}
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

SORT_SERIALS := [Sort]string {
	.Default = "default",
	.Played  = "played",
}

sort_name :: proc(sort: Sort) -> string {
	return SORT_NAMES[sort]
}

sort_kind :: proc(name: string) -> (Sort, bool) {
	for serial, index in SORT_SERIALS {
		if name == serial {return Sort(index), true}
	}
	return .Default, false
}

sort_serial :: proc(sort: Sort) -> string {
	return SORT_SERIALS[sort]
}

// Unknown or malformed lines fall back to defaults, so a corrupt state file
// can never stop the app from opening.
parse_state :: proc(data: string, allocator := context.allocator) -> State {
	app_state := State {
		sidebar_width = DEFAULT_SIDEBAR_WIDTH,
		volume        = DEFAULT_VOLUME,
		tab           = .Playlists,
	}
	for line in strings.split_lines(data, context.temp_allocator) {
		key, _, value := strings.partition(line, "=")
		switch strings.trim_space(key) {
		case "sidebar_width":
			if width, ok := strconv.parse_f32(strings.trim_space(value)); ok {
				app_state.sidebar_width = clamp(width, SIDEBAR_MIN, SIDEBAR_MAX)
			}
		case "tab":
			app_state.tab = state_tab_kind(strings.trim_space(value))
		case "volume":
			if gain, ok := strconv.parse_f32(strings.trim_space(value)); ok {
				app_state.volume = clamp(gain, 0, 1)
			}
		case "sort_playlists", "sort_albums", "sort_artists":
			tab := state_tab_kind(strings.trim_space(key)[len("sort_"):])
			if value, ok := sort_kind(strings.trim_space(value)); ok {
				app_state.sort[tab] = value
			}
		case "pin":
			uri := strings.trim_space(value)
			if len(uri) > 0 && len(app_state.pinned) < MAX_PINNED {
				append(&app_state.pinned, strings.clone(uri, allocator))
			}
		case "recent":
			uri := strings.trim_space(value)
			if len(uri) > 0 && len(app_state.recent) < MAX_RECENT {
				append(&app_state.recent, strings.clone(uri, allocator))
			}
		case "last_track":
			uri := strings.trim_space(value)
			if strings.has_prefix(uri, "spotify:track:") && len(uri) < 128 {
				delete(app_state.last_track)
				app_state.last_track = strings.clone(uri, allocator)
			}
		case "last_title":
			if len(value) > 0 && len(value) < 256 {
				delete(app_state.last_title)
				app_state.last_title = strings.clone(value, allocator)
			}
		case "last_artist":
			if len(value) > 0 && len(value) < 256 {
				delete(app_state.last_artist)
				app_state.last_artist = strings.clone(value, allocator)
			}
		case "last_cover":
			uri := strings.trim_space(value)
			if strings.has_prefix(uri, "https://") && len(uri) <= 512 {
				delete(app_state.last_cover)
				app_state.last_cover = strings.clone(uri, allocator)
			}
		case "last_collection":
			uri := strings.trim_space(value)
			if (strings.has_prefix(uri, "spotify:playlist:") ||
				   strings.has_prefix(uri, "spotify:album:") ||
				   strings.has_prefix(uri, "spotify:artist:")) &&
			   len(uri) < 128 {
				delete(app_state.last_collection)
				app_state.last_collection = strings.clone(uri, allocator)
			}
		case "last_name":
			if len(value) > 0 && len(value) < 256 {
				delete(app_state.last_name)
				app_state.last_name = strings.clone(value, allocator)
			}
		}
	}
	return app_state
}

format_state :: proc(app_state: ^State, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	_ = fmt.sbprintf(
		&builder,
		"sidebar_width=%v\ntab=%s\nvolume=%v\nsort_playlists=%s\nsort_albums=%s\nsort_artists=%s\n",
		app_state.sidebar_width,
		state_tab_name(app_state.tab),
		app_state.volume,
		sort_serial(app_state.sort[.Playlists]),
		sort_serial(app_state.sort[.Albums]),
		sort_serial(app_state.sort[.Artists]),
	)
	for uri in app_state.pinned {_ = fmt.sbprintf(&builder, "pin=%s\n", uri)}
	for uri in app_state.recent {_ = fmt.sbprintf(&builder, "recent=%s\n", uri)}
	if len(app_state.last_track) > 0 {
		_ = fmt.sbprintf(&builder, "last_track=%s\n", app_state.last_track)
	}
	if len(app_state.last_title) > 0 {
		_ = fmt.sbprintf(&builder, "last_title=%s\n", app_state.last_title)
	}
	if len(app_state.last_artist) > 0 {
		_ = fmt.sbprintf(&builder, "last_artist=%s\n", app_state.last_artist)
	}
	if len(app_state.last_cover) > 0 {
		_ = fmt.sbprintf(&builder, "last_cover=%s\n", app_state.last_cover)
	}
	if len(app_state.last_collection) > 0 {
		_ = fmt.sbprintf(&builder, "last_collection=%s\n", app_state.last_collection)
	}
	if len(app_state.last_name) > 0 {
		_ = fmt.sbprintf(&builder, "last_name=%s\n", app_state.last_name)
	}
	return strings.to_string(builder)
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

load_state :: proc() -> State {
	path, ok := state_path()
	if !ok {return {sidebar_width = DEFAULT_SIDEBAR_WIDTH, tab = .Playlists}}
	defer delete(path)
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {return {sidebar_width = DEFAULT_SIDEBAR_WIDTH, tab = .Playlists}}
	return parse_state(string(data))
}

save_state :: proc(app_state: ^State) {
	path, ok := state_path()
	if !ok {return}
	defer delete(path)
	data := format_state(app_state)
	defer delete(data)
	_ = os.write_entire_file(path, transmute([]u8)data)
}
