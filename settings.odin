// Persisted presentation preferences: window chrome and library ordering. Only
// UI state is stored, never credentials, tokens or signed URLs. Playlist URIs
// are the user's own pins and play history.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import library "spotify/library"

DEFAULT_SIDEBAR_WIDTH :: f32(360)
DEFAULT_VOLUME :: f32(0.5)
SETTINGS_FILE :: "settings"
MAX_PINNED :: 32
MAX_RECENT :: 60

Settings :: struct {
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

free_settings :: proc(settings: ^Settings) {
	for uri in settings.pinned {delete(uri)}
	for uri in settings.recent {delete(uri)}
	delete(settings.pinned)
	delete(settings.recent)
	delete(settings.last_track)
	delete(settings.last_title)
	delete(settings.last_artist)
	delete(settings.last_cover)
	delete(settings.last_collection)
	delete(settings.last_name)
	settings^ = {}
}

settings_tab_name :: proc(kind: library.Kind) -> string {
	#partial switch kind {
	case .Albums:
		return "albums"
	case .Artists:
		return "artists"
	}
	return "playlists"
}

settings_tab_kind :: proc(name: string) -> library.Kind {
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

// Unknown or malformed lines fall back to defaults, so a corrupt settings file
// can never stop the app from opening.
parse_settings :: proc(data: string, allocator := context.allocator) -> Settings {
	settings := Settings {
		sidebar_width = DEFAULT_SIDEBAR_WIDTH,
		volume        = DEFAULT_VOLUME,
		tab           = .Playlists,
	}
	for line in strings.split_lines(data, context.temp_allocator) {
		key, _, value := strings.partition(line, "=")
		switch strings.trim_space(key) {
		case "sidebar_width":
			if width, ok := strconv.parse_f32(strings.trim_space(value)); ok {
				settings.sidebar_width = clamp(width, SIDEBAR_MIN, SIDEBAR_MAX)
			}
		case "tab":
			settings.tab = settings_tab_kind(strings.trim_space(value))
		case "volume":
			if gain, ok := strconv.parse_f32(strings.trim_space(value)); ok {
				settings.volume = clamp(gain, 0, 1)
			}
		case "sort_playlists", "sort_albums", "sort_artists":
			tab := settings_tab_kind(strings.trim_space(key)[len("sort_"):])
			if value, ok := sort_kind(strings.trim_space(value)); ok {
				settings.sort[tab] = value
			}
		case "pin":
			uri := strings.trim_space(value)
			if len(uri) > 0 && len(settings.pinned) < MAX_PINNED {
				append(&settings.pinned, strings.clone(uri, allocator))
			}
		case "recent":
			uri := strings.trim_space(value)
			if len(uri) > 0 && len(settings.recent) < MAX_RECENT {
				append(&settings.recent, strings.clone(uri, allocator))
			}
		case "last_track":
			uri := strings.trim_space(value)
			if strings.has_prefix(uri, "spotify:track:") && len(uri) < 128 {
				delete(settings.last_track)
				settings.last_track = strings.clone(uri, allocator)
			}
		case "last_title":
			if len(value) > 0 && len(value) < 256 {
				delete(settings.last_title)
				settings.last_title = strings.clone(value, allocator)
			}
		case "last_artist":
			if len(value) > 0 && len(value) < 256 {
				delete(settings.last_artist)
				settings.last_artist = strings.clone(value, allocator)
			}
		case "last_cover":
			uri := strings.trim_space(value)
			if strings.has_prefix(uri, "https://") && len(uri) <= 512 {
				delete(settings.last_cover)
				settings.last_cover = strings.clone(uri, allocator)
			}
		case "last_collection":
			uri := strings.trim_space(value)
			if (strings.has_prefix(uri, "spotify:playlist:") ||
				   strings.has_prefix(uri, "spotify:album:") ||
				   strings.has_prefix(uri, "spotify:artist:")) &&
			   len(uri) < 128 {
				delete(settings.last_collection)
				settings.last_collection = strings.clone(uri, allocator)
			}
		case "last_name":
			if len(value) > 0 && len(value) < 256 {
				delete(settings.last_name)
				settings.last_name = strings.clone(value, allocator)
			}
		}
	}
	return settings
}

format_settings :: proc(settings: ^Settings, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	_ = fmt.sbprintf(
		&builder,
		"sidebar_width=%v\ntab=%s\nvolume=%v\nsort_playlists=%s\nsort_albums=%s\nsort_artists=%s\n",
		settings.sidebar_width,
		settings_tab_name(settings.tab),
		settings.volume,
		sort_serial(settings.sort[.Playlists]),
		sort_serial(settings.sort[.Albums]),
		sort_serial(settings.sort[.Artists]),
	)
	for uri in settings.pinned {_ = fmt.sbprintf(&builder, "pin=%s\n", uri)}
	for uri in settings.recent {_ = fmt.sbprintf(&builder, "recent=%s\n", uri)}
	if len(settings.last_track) > 0 {
		_ = fmt.sbprintf(&builder, "last_track=%s\n", settings.last_track)
	}
	if len(settings.last_title) > 0 {
		_ = fmt.sbprintf(&builder, "last_title=%s\n", settings.last_title)
	}
	if len(settings.last_artist) > 0 {
		_ = fmt.sbprintf(&builder, "last_artist=%s\n", settings.last_artist)
	}
	if len(settings.last_cover) > 0 {
		_ = fmt.sbprintf(&builder, "last_cover=%s\n", settings.last_cover)
	}
	if len(settings.last_collection) > 0 {
		_ = fmt.sbprintf(&builder, "last_collection=%s\n", settings.last_collection)
	}
	if len(settings.last_name) > 0 {
		_ = fmt.sbprintf(&builder, "last_name=%s\n", settings.last_name)
	}
	return strings.to_string(builder)
}

settings_is_pinned :: proc(settings: ^Settings, uri: string) -> bool {
	for pinned in settings.pinned {if pinned == uri {return true}}
	return false
}

settings_rank :: proc(list: [dynamic]string, uri: string) -> int {
	for entry, index in list {if entry == uri {return index}}
	return max(int)
}

// Returns the new pinned state.
settings_toggle_pin :: proc(settings: ^Settings, uri: string) -> bool {
	if len(uri) == 0 {return false}
	for pinned, index in settings.pinned {
		if pinned != uri {continue}
		ordered_remove(&settings.pinned, index)
		delete(pinned)
		return false
	}
	if len(settings.pinned) < MAX_PINNED {
		append(&settings.pinned, strings.clone(uri))
		return true
	}
	return false
}

settings_note_recent :: proc(settings: ^Settings, uri: string) {
	if len(uri) == 0 {return}
	for recent, index in settings.recent {
		if recent != uri {continue}
		if index > 0 {
			ordered_remove(&settings.recent, index)
			inject_at(&settings.recent, 0, recent)
		}
		return
	}
	if len(settings.recent) >= MAX_RECENT {
		delete(settings.recent[len(settings.recent) - 1])
		resize(&settings.recent, MAX_RECENT - 1)
	}
	inject_at(&settings.recent, 0, strings.clone(uri))
}

settings_path :: proc() -> (path: string, ok: bool) {
	base, err := os.user_state_dir(context.allocator)
	if err != nil {return "", false}
	defer delete(base)
	dir := fmt.aprintf("%s/spoti", base)
	defer delete(dir)
	if dir_error := os.make_directory_all(dir); dir_error != nil && dir_error != .Exist {
		return "", false
	}
	return fmt.aprintf("%s/%s", dir, SETTINGS_FILE), true
}

load_settings :: proc() -> Settings {
	path, ok := settings_path()
	if !ok {return {sidebar_width = DEFAULT_SIDEBAR_WIDTH, tab = .Playlists}}
	defer delete(path)
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {return {sidebar_width = DEFAULT_SIDEBAR_WIDTH, tab = .Playlists}}
	return parse_settings(string(data))
}

save_settings :: proc(settings: ^Settings) {
	path, ok := settings_path()
	if !ok {return}
	defer delete(path)
	data := format_settings(settings)
	defer delete(data)
	_ = os.write_entire_file(path, transmute([]u8)data)
}
