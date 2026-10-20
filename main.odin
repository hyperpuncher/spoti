#+feature using-stmt
package main

import "base:runtime"
import c "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:time"
import "core:unicode"
import diagnostic "diagnostic"
import connect "spotify/connect"
import credential "spotify/credential"
import http "spotify/http"
import library "spotify/library"
import mpris "spotify/mpris"
import oauth "spotify/oauth"
import player "spotify/player"
import session "spotify/session"
import track "spotify/track"
import ui "ui"
import clay "vendor/clay"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// MPRIS and Connect workers use this event to wake the idle frame loop.
WAKE_EVENT: u32

// Browser approval URLs arrive from worker threads. Playback sign-in opens
// the browser directly; the library pane offers a button instead.
prompt_mutex: sync.Mutex
prompt_urls: [oauth.Prompt]string

prompt_arrived :: proc(kind: oauth.Prompt, url: string) {
	sync.mutex_guard(&prompt_mutex)
	delete(prompt_urls[kind])
	prompt_urls[kind] = len(url) > 0 ? strings.clone(url) : ""
}

prompt_pending :: proc(kind: oauth.Prompt) -> bool {
	sync.mutex_guard(&prompt_mutex)
	return prompt_urls[kind] != ""
}

open_prompt_url :: proc(kind: oauth.Prompt) -> bool {
	sync.mutex_guard(&prompt_mutex)
	url := prompt_urls[kind]
	if len(url) == 0 {return false}
	c_url := strings.clone_to_cstring(url)
	defer delete(c_url)
	return sdl.OpenURL(c_url)
}

// Native window controls receive their own clicks; only unused header
// space drags. SDL hit-test points are logical, Clay boxes are render pixels.
window_header_hit_test :: proc "c" (
	window: ^sdl.Window,
	point: ^sdl.Point,
	data: rawptr,
) -> sdl.HitTestResult {
	context = runtime.default_context()
	state := (^ui.State)(data)
	position := ui.mouse_position(state, f32(point.x), f32(point.y))
	d := ui.scale(state)
	controls := sdl.FRect{0, 0, 96 * d, 58 * d}
	when ODIN_OS == .Windows {
		width, _ := ui.size(state)
		caption := ui.windows_caption_width(window)
		controls = {f32(width) - caption, 0, caption, 58 * d}
		flags := sdl.GetWindowFlags(window)
		if .FULLSCREEN in flags {return .NORMAL}
		if .MAXIMIZED not_in flags && position.y < 6 * d {
			if position.x < 6 * d {return .RESIZE_TOPLEFT}
			if position.x >= f32(width) - 6 * d {return .RESIZE_TOPRIGHT}
			return .RESIZE_TOP
		}
	}
	if !header_can_drag(position, d, controls) {return .NORMAL}
	return .DRAGGABLE
}

header_can_drag :: proc(point: sdl.FPoint, d: f32, controls: sdl.FRect) -> bool {
	if point.y < 0 || point.y >= 58 * d {return false}
	if point.x >= controls.x &&
	   point.x < controls.x + controls.w &&
	   point.y >= controls.y &&
	   point.y < controls.y + controls.h {return false}
	for id in ([]string{"toolbar_back", "toolbar_forward", "track_input", "toolbar_releases"}) {
		if hit(id, point) {return false}
	}
	return true
}

@(private = "file")
wake_app :: proc "c" (_: rawptr) {
	event := sdl.Event {
		type = sdl.EventType(WAKE_EVENT),
	}
	_ = sdl.PushEvent(&event)
}

hit_index :: proc(id: string, point: sdl.FPoint, index: u32) -> bool {
	data := clay.GetElementData(clay.ID(id, index))
	return data.found && point_in_box(point, data.boundingBox)
}

hit :: proc(id: string, point: sdl.FPoint) -> bool {
	return hit_index(id, point, 0)
}

// Point test against a known box, for floating panels whose state is latched
// one frame behind the layout.
point_in_box :: proc(point: sdl.FPoint, box: clay.BoundingBox) -> bool {
	return(
		box.width > 0 &&
		box.height > 0 &&
		point.x >= box.x &&
		point.x < box.x + box.width &&
		point.y >= box.y &&
		point.y < box.y + box.height \
	)
}

// Overscan items can have rectangles outside their scroll viewport. Drawing
// is clipped by Clay, but explicit rectangle hit tests must check the clip too.
hit_clipped :: proc(id, clip: string, point: sdl.FPoint, index: u32 = 0) -> bool {
	return hit(clip, point) && hit_index(id, point, index)
}

// The grid card under the pointer, or -1. Overscan cards outside the viewport
// are skipped, so a drop or hover never lands on one the user cannot see.
grid_card_at :: proc(page: ^library.Page, visible: Visible_Items, point: sdl.FPoint) -> int {
	for index in visible.first ..< visible.last {
		if index >= len(page.items) {continue}
		if hit_clipped("card", "library_grid", point, u32(index)) {return index}
	}
	return -1
}

pointer_over :: proc(id: string, index: u32 = 0) -> bool {
	return clay.PointerOver(clay.ID(id, index))
}

range_hovered :: proc(id: string, visible: Visible_Items) -> bool {
	for index in visible.first ..< visible.last {
		if pointer_over(id, u32(index)) {return true}
	}
	return false
}

// One hover scan for both artist link namespaces: the hero uses its own id
// with base 0, track rows use the row slot compound ids.
artist_links_hovered :: proc(links: []library.Artist_Link, id: string, base: u32) -> bool {
	for ai in 0 ..< min(len(links), 64) {
		if len(links[ai].uri) == 0 {continue}
		if pointer_over(id, base + u32(ai)) {return true}
	}
	return false
}

// Follows the desktop theme through SDL; unknown means dark, and
// SPOTI_THEME forces light or dark for testing and user control.
system_dark :: proc() -> bool {
	value := os.get_env("SPOTI_THEME", context.temp_allocator)
	if value == "light" {return false}
	if value == "dark" {return true}
	return sdl.GetSystemTheme() != .LIGHT
}

update_cursor :: proc(
	state: ^ui.State,
	client: ^library.Client,
	resizing: bool,
	visible: Frame_Visible,
	seek_enabled: bool,
	search_mode: bool,
	link_album: bool,
	link_artist: bool,
) {
	if pointer_over("footer_devices") ||
	   pointer_over("footer_queue") ||
	   pointer_over("queue_close") ||
	   pointer_over("queue_current") ||
	   pointer_over("queue_scrollbar") ||
	   range_hovered("queue_item", visible.queue) {
		ui.set_cursor(state, .Pointer)
		return
	}
	for device, index in client.devices {
		if !device.restricted && pointer_over("device_item", u32(index)) {
			ui.set_cursor(state, .Pointer)
			return
		}
	}
	if seek_enabled && pointer_over("seek_slider") {ui.set_cursor(state, .Pointer); return}
	if pointer_over("library_scrollbar") || pointer_over("detail_scrollbar") {
		ui.set_cursor(state, .Pointer)
		return
	}
	if resizing || pointer_over("sidebar_handle") {
		ui.set_cursor(state, .Resize)
		return
	}
	if pointer_over("track_input") {
		ui.set_cursor(state, .Text)
		return
	}
	if pointer_over("setup_field") {
		ui.set_cursor(state, .Text)
		return
	}
	for id in ([]string{"toolbar_back", "toolbar_library", "toolbar_releases", "sort_button", "hero_like", "hero_play", "footer_play", "footer_previous", "footer_next", "footer_repeat", "footer_shuffle", "hero_shuffle", "volume_slider", "spotify_link", "hero_copy_link", "hero_pin", "autoscroll", "setup_redirect", "setup_dashboard", "setup_save", "detail_retry"}) {
		if (id == "hero_play" || id == "hero_shuffle") && !detail_play_enabled(client) {continue}
		if id == "hero_copy_link" && library.detail_loading_visible(client) {continue}
		if id == "hero_pin" &&
		   (client.detail.source != .Playlist || library.detail_loading_visible(client)) {continue}
		if id == "spotify_link" && client.detail_loading {continue}
		if pointer_over(id) {
			ui.set_cursor(state, .Pointer)
			return
		}
	}
	chip_count := search_mode ? len(SEARCH_TABS) : len(LIBRARY_TABS)
	for index in 0 ..< chip_count {
		if pointer_over("chip", u32(index)) {
			ui.set_cursor(state, .Pointer)
			return
		}
	}
	if range_hovered("card", visible.cards) {ui.set_cursor(state, .Pointer); return}
	if link_album && pointer_over("footer_title") {
		ui.set_cursor(state, .Pointer)
		return
	}
	if link_artist && pointer_over("footer_artist") {
		ui.set_cursor(state, .Pointer)
		return
	}
	if client.release_feed.open && range_hovered("feed_row", visible.feed) {
		ui.set_cursor(state, .Pointer)
		return
	}
	if client.detail.ready {
		if artist_links_hovered(client.detail.artist_links, "hero_artist_link", 0) {
			ui.set_cursor(state, .Pointer)
			return
		}
		if range_hovered("track_row", visible.tracks) ||
		   range_hovered("release_card", visible.releases) ||
		   range_hovered("single_card", visible.singles) {
			ui.set_cursor(state, .Pointer)
			return
		}
	}
	ui.set_cursor(state, .Default)
}

// Artist release cards use the same history and preview path as other albums.
open_release_card :: proc(
	ctx: ^Nav_Ctx,
	point: sdl.FPoint,
	id: string,
	items: []library.Entry,
	visible: Visible_Items,
) -> bool {
	for index in visible.first ..< min(visible.last, len(items)) {
		if hit_clipped(id, "detail_rows", point, u32(index)) {
			return open_entry_page(ctx, items[index])
		}
	}
	return false
}

// One value threads the navigation state through every click target instead
// of eleven params per call. input rides a pointer because row presses clear
// it mid-frame; everything else is only read.
Nav_Ctx :: struct {
	client:        ^library.Client,
	nav:           ^Nav,
	app_state:     ^State,
	textures:      ^Textures,
	detail_pinned: ^bool,
	scroll_armed:  ^bool,
	filter:        library.Kind,
	search_mode:   bool,
	search_kind:   library.Kind,
	input:         ^string,
}

// Shared by card clicks and row/footer links: opens the entry page unless it
// is already open, and records the navigation like any card click. The
// preview is only borrowed; the detail and history own their copies.
open_entry_page :: proc(ctx: ^Nav_Ctx, entry: library.Entry) -> bool {
	if detail_already_open(ctx.client, entry.uri) {return true}
	source, id, valid := parse_card_uri(entry.uri)
	if !valid {return false}
	nav_save_scroll(ctx.nav, detail_scroll_y())
	ctx.scroll_armed^ = false
	if !library.open_detail(ctx.client, source, id, entry) {return false}
	retry_failed_covers(ctx.textures)
	ctx.detail_pinned^ = state_is_pinned(ctx.app_state, entry.uri)
	nav_commit(
		ctx.nav,
		nav_capture(ctx.client, ctx.filter, ctx.search_mode, ctx.search_kind, ctx.input^),
	)
	return true
}

show_toast :: proc(app: ^App, message: string) {
	replace_string(&app.toast, message)
	app.toast_until = sdl.GetTicksNS() + 2_500_000_000
	app.pending_redraw = true
}

copy_link :: proc(app: ^App, uri: string) {
	show_toast(app, copy_spotify_uri(uri) ? "Link copied" : "Could not copy link")
}

open_dashboard :: proc() {
	c_url := strings.clone_to_cstring(SPOTIFY_DASHBOARD)
	defer delete(c_url)
	_ = sdl.OpenURL(c_url)
}

// Validate the pasted app key and store it in the system keyring. The
// library worker starts on the next frame; a bad key or an unavailable
// keyring stays on the setup screen with an error line.
submit_setup :: proc(app: ^App) {
	id := strings.trim_space(app.input)
	if !library.valid_client_id(id) {
		replace_string(&app.setup_error, "That key is not a 32-character client id.")
		return
	}
	if !credential.save(id, .Library_Client) {
		replace_string(&app.setup_error, "Could not store the key in the system keyring.")
		return
	}
	replace_string(&app.setup_error, "")
	delete(app.input)
	app.input = ""
	app.input_active = false
	_ = sdl.StopTextInput(app.state.window)
}

// Search accepts any text except control characters. Track links are
// validated on submit, so pasted URLs and Unicode queries share a field.
input_text_ok :: proc(value: string) -> bool {
	for rune in value {
		if unicode.is_control(rune) {return false}
	}
	return true
}

// The search and setup fields are single-line. Clipboard text often carries a
// trailing newline; join its lines with one space instead of rejecting all of it.
// Ordinary spaces stay untouched, including leading and trailing ones.
paste_text :: proc(value: string) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, 0, len(value), context.temp_allocator)
	pending_space := false
	for rune in value {
		if rune == '\r' || rune == '\n' || rune == '\t' {
			pending_space = true
			continue
		}
		if unicode.is_control(rune) {continue}
		if pending_space && rune != ' ' && strings.builder_len(builder) > 0 {
			strings.write_byte(&builder, ' ')
		}
		pending_space = false
		strings.write_rune(&builder, rune)
	}
	return strings.to_string(builder)
}

// Debounce catalog searches while typing; Enter searches immediately.
SEARCH_DEBOUNCE_NS :: u64(300_000_000)

// One glide target per scroll container. Wheel ticks are sparse (a mouse
// detent is roughly one event) while frames are cheap, so the wheel only
// moves the target and each frame eases the real offset toward it.
Smooth :: struct {
	target: f32,
	active: bool,
}

smooth_for :: proc(container: string, grid, detail, queue: ^Smooth) -> ^Smooth {
	if container == "queue_rows" {return queue}
	return container == "library_grid" ? grid : detail
}

// Live detail_rows offset for history saves; zero when the page is closed.
detail_scroll_y :: proc() -> f32 {
	data := clay.GetScrollContainerData(clay.ID("detail_rows"))
	if !data.found || data.scrollPosition == nil {return 0}
	return data.scrollPosition.y
}

SCROLL_WHEEL_STEP :: 120.0

scroll_wheel :: proc(id: string, amount, d: f32, smooth: ^Smooth) -> bool {
	if amount == 0 || !pointer_over(id) {return false}
	scroll := clay.GetScrollContainerData(clay.ID(id))
	if !scroll.found || scroll.scrollPosition == nil {return false}
	if !smooth.active {
		smooth.target = scroll.scrollPosition.y
		smooth.active = true
	}
	minimum := min(
		f32(0),
		scroll.scrollContainerDimensions.height - scroll.contentDimensions.height,
	)
	smooth.target = clamp(smooth.target + amount * SCROLL_WHEEL_STEP * d, minimum, 0)
	return true
}

// One easing step toward the wheel target. Clamps every frame so content
// loads and view switches self-heal instead of whooshing to stale offsets.
SMOOTH_SNAP :: 0.5
SMOOTH_RATE :: 14.0

smooth_step :: proc(container: string, smooth: ^Smooth, dt: f32) -> bool {
	if !smooth.active {return false}
	data := clay.GetScrollContainerData(clay.ID(container))
	if !data.found || data.scrollPosition == nil {
		smooth.active = false
		return false
	}
	viewport := data.scrollContainerDimensions.height
	content := data.contentDimensions.height
	if viewport <= 0 || content <= viewport {
		smooth.active = false
		return false
	}
	minimum := viewport - content
	smooth.target = clamp(smooth.target, minimum, 0)
	next :=
		data.scrollPosition.y + (smooth.target - data.scrollPosition.y) * min(1, dt * SMOOTH_RATE)
	if abs(smooth.target - next) <= SMOOTH_SNAP {
		next = smooth.target
		smooth.active = false
	}
	data.scrollPosition.y = next
	return true
}

// Direct offset writes (drag, autoscroll) cancel the glide so they never
// fight it; the target re-arms from the new position on the next tick.
smooth_cancel :: proc(container: string, smooth: ^Smooth) {
	data := clay.GetScrollContainerData(clay.ID(container))
	if data.found && data.scrollPosition != nil {smooth.target = data.scrollPosition.y}
	smooth.active = false
}

// Middle-click autoscroll: the button parks an anchor, steering away scrolls
// with a velocity proportional to the distance, another click exits.
AUTOSCROLL_DEADZONE :: 10.0
AUTOSCROLL_SPEED :: 30.0

// Signed scroll px for this frame; zero inside the dead zone. Pure for tests.
autoscroll_delta :: proc(dy, dt, d: f32) -> f32 {
	remaining := abs(dy) - AUTOSCROLL_DEADZONE * d
	if remaining <= 0 || dt <= 0 {return 0}
	step := remaining * AUTOSCROLL_SPEED * min(dt, 0.1)
	return dy > 0 ? -step : step
}

autoscroll_step :: proc(container: string, dy, dt, d: f32) -> bool {
	data := clay.GetScrollContainerData(clay.ID(container))
	if !data.found || data.scrollPosition == nil {return false}
	viewport := data.scrollContainerDimensions.height
	content := data.contentDimensions.height
	if viewport <= 0 || content <= viewport {return false}
	delta := autoscroll_delta(dy, dt, d)
	if delta == 0 {return false}
	data.scrollPosition.y = clamp(data.scrollPosition.y + delta, viewport - content, 0)
	return true
}

load_more_near_bottom :: proc(client: ^library.Client, filter: library.Kind, d: f32) {
	page := &client.pages[filter]
	// A page that never loaded still has to be asked for again.
	if (page.ready && !page.has_more) || client.pending[filter] {return}
	scroll := clay.GetScrollContainerData(clay.ID("library_grid"))
	if !scroll.found || scroll.scrollPosition == nil {return}
	remaining :=
		scroll.contentDimensions.height -
		scroll.scrollContainerDimensions.height +
		scroll.scrollPosition.y
	if remaining <= 480 * d {library.more(client, filter)}
}

// Page the next detail chunk once the drawn rows reach the loaded end. Using
// the drawn range, not the full-total spacer, keeps paging to the viewport
// and stops a long playlist from flooding the single worker up front.
DETAIL_LOOKAHEAD :: 20

detail_needs_more :: proc(
	client: ^library.Client,
	visible: Frame_Visible,
	group: library.Album_Group = .Album,
) -> bool {
	if client.release_feed.open ||
	   !client.detail.ready ||
	   !client.detail.has_more ||
	   client.detail_loading {return false}
	detail := &client.detail
	if detail.source == .Artist {
		section, shown := &detail.albums, visible.releases
		if group == .Single {section, shown = &detail.singles, visible.singles}
		// Card ranges already include an extra row. A track-sized lookahead
		// fetched hidden sections and several extra ten-release pages.
		return section.has_more && shown.last > shown.first && shown.last >= len(section.items)
	}
	return group == .Album && visible.tracks.last >= len(detail.rows) - DETAIL_LOOKAHEAD
}

// Spend the frame's request budget only when the artwork worker accepts it.
ensure_cover :: proc(client: ^library.Client, textures: ^Textures, url: string, budget: ^int) {
	if budget^ == 0 || url == "" {return}
	key := cover_key(url)
	previous := textures.requested[key]
	if key in textures.by_key || previous.pending || previous.attempts >= 2 {return}
	if library.request_cover(client, url, key) {
		textures.requested[key] = {
			pending  = true,
			attempts = previous.attempts + 1,
		}
		budget^ -= 1
	}
}

ensure_covers :: proc(
	client: ^library.Client,
	textures: ^Textures,
	page: ^library.Page,
	player_cover: string,
	visible: Frame_Visible,
) {
	budget := 4
	ensure_cover(client, textures, player_cover, &budget)
	if client.covers_pending < 8 {
		for entry in page.items[visible.cards.first:visible.cards.last] {
			ensure_cover(client, textures, entry.image, &budget)
		}
	}
	if client.release_feed.open {
		if client.covers_pending < 8 {
			for release in client.release_feed.items[visible.feed.first:visible.feed.last] {
				ensure_cover(client, textures, release.entry.image, &budget)
			}
		}
		return
	}
	if client.detail.ready {
		ensure_cover(client, textures, client.detail.banner, &budget)
		ensure_cover(client, textures, client.detail.image, &budget)
		ensure_cover(client, textures, client.detail.image_preview, &budget)
		ensure_cover(client, textures, client.detail.image_small, &budget)
		// Rows stream in behind the visible window; never slice placeholders,
		// and stop prefetching while a backlog is still draining so fast
		// scrolling cannot queue the whole collection as textures.
		if client.covers_pending < 8 {
			track_first := min(visible.tracks.first, len(client.detail.rows))
			track_last := min(visible.tracks.last, len(client.detail.rows))
			for row in client.detail.rows[track_first:track_last] {
				ensure_cover(client, textures, row.image, &budget)
				ensure_cover(client, textures, row.image_small, &budget)
			}
			album_first := min(visible.releases.first, len(client.detail.albums.items))
			album_last := min(visible.releases.last, len(client.detail.albums.items))
			for release in client.detail.albums.items[album_first:album_last] {
				ensure_cover(client, textures, release.image, &budget)
			}
			single_first := min(visible.singles.first, len(client.detail.singles.items))
			single_last := min(visible.singles.last, len(client.detail.singles.items))
			for release in client.detail.singles.items[single_first:single_last] {
				ensure_cover(client, textures, release.image, &budget)
			}
		}
	}
}

clear_audio_stream :: proc(stream: ^^sdl.AudioStream) {
	if stream^ != nil {sdl.DestroyAudioStream(stream^); stream^ = nil}
}

// Keep unchanged strings; copy before freeing so the input may alias the owner.
replace_string :: proc(destination: ^string, value: string) {
	if destination^ == value {return}
	next := strings.clone(value)
	delete(destination^)
	destination^ = next
}

parse_card_uri :: proc(uri: string) -> (source: library.Source, id: string, ok: bool) {
	if strings.has_prefix(uri, "spotify:playlist:") {
		source, id = .Playlist, uri[len("spotify:playlist:"):]
	} else if strings.has_prefix(uri, "spotify:album:") {
		source, id = .Album, uri[len("spotify:album:"):]
	} else if strings.has_prefix(uri, "spotify:artist:") {
		source, id = .Artist, uri[len("spotify:artist:"):]
	} else {
		return {}, "", false
	}
	if !library.safe_id(id) {return {}, "", false}
	return source, id, true
}

// Pixels the pointer must travel before a press becomes a drag.
DRAG_THRESHOLD :: 6.0

drag_started :: proc(current, start: sdl.FPoint, threshold: f32) -> bool {
	dx := current.x - start.x
	dy := current.y - start.y
	return dx * dx + dy * dy >= threshold * threshold
}

// The whole program state in one value. main owns it and brings the
// fields into scope with `using`, so frame stages can split into procs
// without threading sixty locals through every signature.
App :: struct {
	state:                  ui.State,
	worker:                 ^thread.Thread,
	work:                   Login_Work,
	play_source:            Play_Source,
	preload_worker:         ^thread.Thread,
	preload_work:           Preload_Work,
	preload_attempted:      string,
	cancel:                 bool,
	stream:                 ^sdl.AudioStream,
	title:                  string,
	artist:                 string,
	selected:               string,
	player_cover:           string,
	displayed_cover:        string,
	play_queue:             [dynamic]Play_Item,
	play_index:             int,
	queue_detail:           string,
	queue_gen:              uint,
	queue_rows:             int, // collection rows already copied; excludes manual additions
	queue_restore_pending:  bool,
	using editor:           ui.Editor,
	search_mode:            bool,
	search_kind:            library.Kind,
	search_pending:         bool,
	search_deadline:        u64,
	textures:               Textures,
	theme_dark:             bool,
	mpris_active:           bool,
	library_client:         library.Client,
	connect_client:         connect.Client,
	connect_snapshot:       connect.Snapshot,
	connect_published_at:   u64,
	connect_repeat_context: bool,
	transfer_here:          bool,
	app_state:              State,
	filter:                 library.Kind,
	sidebar_width:          f32,
	state_dirty:            bool,
	order_dirty:            bool,
	pending_redraw:         bool,
	detail_pinned:          bool,
	nav:                    Nav,
	nav_ctx:                Nav_Ctx,
	nav_back_pressed:       bool,
	nav_forward_pressed:    bool,
	library_prompt_shown:   bool,
	playback_prompt_opened: bool,
	page_counts:            [library.Kind]int,
	menu:                   Context_Menu,
	device_open:            bool, // the Connect device panel is showing
	queue_open:             bool,
	resizing:               bool,
	scrollbar_drag:         Scrollbar_Drag,
	detail_scroll_target:   f32,
	detail_scroll_armed:    bool,
	last_detail_uri:        string,
	release_play_uri:       string,
	autoscroll_container:   string,
	autoscroll_anchor:      sdl.FPoint,
	autoscroll_moving:      bool,
	grid_smooth:            Smooth,
	detail_smooth:          Smooth,
	picker_smooth:          Smooth,
	device_smooth:          Smooth,
	queue_smooth:           Smooth,
	toast:                  string,
	setup_error:            string, // setup screen error, owned
	toast_until:            u64,
	last_write_pending:     bool,
	last_transfer_pending:  bool,
	remote_control:         bool, // the footer commands the API-active device
	remote_polled_at:       u64, // last player-state poll, ticks
	drag_candidate:         bool,
	dragging:               bool,
	drag_index:             int,
	drag_start:             sdl.FPoint,
	drag_uri:               string,
	drag_label:             string,
	drop_target:            int,
	stage_sum:              [3]f64,
	stage_max:              [3]f64,
	stage_n:                int,
	restore_pending:        bool,
	button_anims:           map[u32]Button_Fx,
	hero_cache:             Hero_Cache,
	stage:                  Stage,
	finished:               bool,
	repeat:                 bool,
	replay_pending:         bool,
	play_after_stop:        bool,
	fx_animating:           bool,
	shuffle:                bool,
	volume:                 f32,
	volume_dragging:        bool,
	seek_dragging:          bool,
	start_paused:           bool,
	seek_ms:                int,
	sent_frames:            int,
	sample_rate:            int,
	duration_ms:            int,
	displayed_ms:           int,
	last:                   u64,
	first_frame:            bool,
	running:                bool,
	width:                  c.int,
	height:                 c.int,
	queue:                  chan.Chan(player.Packet),
}

// Per-frame scratch. Zeroed every iteration; stages share it instead of
// threading temps through signatures.
Frame :: struct {
	wheel:            sdl.FPoint,
	mouse_click:      sdl.FPoint,
	mouse_right:      sdl.FPoint,
	middle_click:     sdl.FPoint,
	clicked:          bool,
	click_count:      u8,
	right_clicked:    bool,
	space_pressed:    bool,
	stop_pressed:     bool,
	middle_clicked:   bool,
	input_changed:    bool,
	track_selected:   bool,
	restart_playback: bool,
	redraw:           bool,
	mouse:            sdl.FPoint,
	buttons:          sdl.MouseButtonFlags,
	density:          f32,
	seek_enabled:     bool,
	link_album:       bool,
	link_artist:      bool,
	queue_at:         bool,
	foot_album:       string,
	foot_album_uri:   string,
	foot_first:       string,
	foot_first_uri:   string,
	library_prompt:   bool,
	playback_prompt:  bool,
	display_page:     ^library.Page,
	display_kind:     library.Kind,
}

main :: proc() {
	verbose := false
	for arg in os.args[1:] {
		if arg == "-v" || arg == "--verbose" {verbose = true}
	}
	diagnostic.init(verbose)
	diagnostic.write("application starting")
	defer {
		diagnostic.write("clean shutdown")
		diagnostic.close()
	}
	app := App{}
	using app
	ok := false
	app.state, ok = ui.open("spoti", 1280, 820)
	if !ok {return}
	defer ui.close(&app.state)
	when ODIN_OS == .Darwin || ODIN_OS == .Windows {
		if !sdl.SetWindowHitTest(app.state.window, window_header_hit_test, &app.state) {
			fmt.eprintln("could not enable header dragging:", sdl.GetError())
		}
	}
	if !sdl.InitSubSystem(
		sdl.INIT_AUDIO,
	) {fmt.eprintln("could not initialize SDL3 audio:", sdl.GetError()); return}

	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	width, height = ui.size(&state)
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), &memory[0]),
		{f32(width), f32(height)},
		{handler = clay_error},
	)
	clay.SetMeasureTextFunction(measure_text, &state)
	selected = strings.clone(session.TRACK_URL)
	play_index = -1
	textures = Textures {
		by_key    = make(map[u64]^sdl.Texture),
		requested = make(map[u64]Cover_Request_State),
	}
	theme_dark = system_dark()
	apply_theme(theme_dark)
	when ODIN_OS == .Windows {ui.windows_frame_theme(state.window, theme_dark)}
	load_icons(&state, &textures, theme_dark)
	load_fades(&state, &textures)
	WAKE_EVENT = sdl.RegisterEvents(1)
	_ = ui.start_emoji(&state, WAKE_EVENT != 0 ? wake_app : nil)
	mpris_active = mpris.start(WAKE_EVENT != 0 ? wake_app : nil)
	oauth.set_prompt_handler(prompt_arrived)
	app_state = load_state()
	http.web_api_defer_until(time.from_nanoseconds(app_state.web_api_resume_ns))
	if app_state.connect_device == "" {
		app_state.connect_device = connect.new_id()
		save_state(&app_state)
	}
	session.set_device_id(app_state.connect_device)
	_ = connect.start(&connect_client, app_state.connect_device, WAKE_EVENT != 0 ? wake_app : nil)
	filter = app_state.tab
	sidebar_width = app_state.sidebar_width
	defer delete(last_detail_uri)
	defer delete(release_play_uri)
	defer delete(toast)
	defer delete(setup_error)
	drag_index = -1
	defer delete(drag_uri)
	defer delete(drag_label)
	drop_target = -1
	// Resume the last played track and reopen its collection. The footer
	// shows it without starting playback; pressing play resumes it.
	played := &app_state.last_played
	app_restore_play_queue(&app)
	if played.track != "" {replace_string(&selected, played.track)}
	replace_string(&title, played.title)
	replace_string(&artist, played.artist)
	replace_string(&player_cover, played.cover)
	restore_pending = len(app_state.last_collection) > 0
	button_anims = make(map[u32]Button_Fx)
	defer {
		if worker != nil {release_worker(worker, queue, &cancel)}
		if preload_worker != nil {
			sync.atomic_store(&preload_work.cancel, true)
			thread.destroy(preload_worker)
		}
		clear_preload(&preload_work)
		delete(preload_attempted)
		clear_play_source(&play_source)
		clear_audio_stream(&stream)
		library.stop(&library_client)
		// A request can receive its retry deadline while the worker shuts down.
		final_frame: Frame
		app_persist(&app, &final_frame)
		connect.stop(&connect_client)
		connect.free_snapshot(&connect_snapshot)
		session.clear_authorization()
		for _, texture in textures.by_key {sdl.DestroyTexture(texture)}
		delete(textures.by_key)
		delete(textures.requested)
		delete(title)
		delete(artist)
		delete(selected)
		delete(player_cover)
		delete(displayed_cover)
		free_play_queue(&play_queue)
		delete(queue_detail)
		delete(input)
		free_state(&app_state)
		free_context_menu(&menu)
		nav_free_all(&nav)
		delete(button_anims)
		free_hero_cache(&hero_cache)
		if mpris_active {mpris.close()}
	}
	volume = app_state.volume
	last = sdl.GetTicksNS()
	first_frame = true
	running = true
	for running {
		defer free_all(context.temp_allocator)
		frame := Frame{}
		using frame
		has_event, fades_animating := app_events(&app, &frame)
		redraw = has_event || first_frame || fx_animating || fades_animating || pending_redraw
		pending_redraw = false
		first_frame = false
		if !running {break}
		app_navigate(&app, &frame)
		app_search(&app, &frame)
		app_library(&app, &frame)
		if remote_control {
			now := sdl.GetTicksNS()
			if now - remote_polled_at >= 5_000_000_000 {
				remote_polled_at = now
				_ = library.refresh_player_state(&library_client)
			}
		}
		if library_client.remote_gone {
			library_client.remote_gone = false
			remote_control = false
		}
		app_playback(&app, &frame)
		// Glide wheel targets toward their offsets before the idle check so
		// a settling glide keeps frames (and redraws) coming by itself.
		app_glide(&app, &frame)
		if len(toast) > 0 && sdl.GetTicksNS() >= toast_until {
			replace_string(&toast, "")
			redraw = true
		}
		if !redraw && stage != .Playing {continue}

		visible := app_layout(&app, &frame)
		app_covers(&app, &frame, visible)
		nav_ctx = Nav_Ctx {
			client        = &library_client,
			nav           = &nav,
			app_state     = &app_state,
			textures      = &textures,
			detail_pinned = &detail_pinned,
			scroll_armed  = &detail_scroll_armed,
			filter        = filter,
			search_mode   = search_mode,
			search_kind   = search_kind,
			input         = &input,
		}
		app_click(&app, &frame, visible)
		// A track-row press arms a drag; a released press either drops the
		// track on a playlist card or plays the row. Dragging never plays.
		app_transport(&app, &frame, visible)
		app_connect_publish(&app)
		app_persist(&app, &frame)
	}
}

PLAYBACK_FRAME_NS :: u64(1_000_000_000 / 30)

// Event wait plus the drain switch. Fills the frame flags the later stages
// read and reports whether anything arrived plus whether fades animate.
app_events :: proc(app: ^App, frame: ^Frame) -> (bool, bool) {
	using app
	using frame
	event: sdl.Event
	wait_ms: i32 = -1 // no redraw while idle; SDL events wake the window
	emoji_poll := WAKE_EVENT == 0 && ui.emoji_pending(&state)
	fades_animating :=
		(textures.fade_top_alpha != 0 && textures.fade_top_alpha != 1) ||
		(textures.fade_bottom_alpha != 0 && textures.fade_bottom_alpha != 1) ||
		(textures.fade_detail_top_alpha != 0 && textures.fade_detail_top_alpha != 1) ||
		(textures.fade_detail_bottom_alpha != 0 && textures.fade_detail_bottom_alpha != 1)
	// Anything animating renders at the display rate, so the idle poll
	// below can never throttle a scroll glide or a button spring.
	if editor.selecting ||
	   autoscroll_moving ||
	   grid_smooth.active ||
	   detail_smooth.active ||
	   picker_smooth.active ||
	   device_smooth.active ||
	   queue_smooth.active ||
	   resizing ||
	   dragging ||
	   seek_dragging ||
	   volume_dragging ||
	   scrollbar_drag.container != "" ||
	   fx_animating ||
	   fades_animating ||
	   first_frame ||
	   pending_redraw {
		wait_ms = 0
	} else {
		// Idle work still polls for results so they appear promptly.
		if stage == .Signing_In ||
		   stage == .Buffering ||
		   stage == .Stopping ||
		   (stage == .Ended && replay_pending) ||
		   (stage == .Failed && worker != nil) {wait_ms = 40}
		if library_client.state == .Authorizing ||
		   library_client.state == .Loading ||
		   library_client.detail_loading ||
		   library_client.search_loading ||
		   library_client.covers_pending > 0 ||
		   (library_client.release_feed.open &&
				   !library_client.release_feed.done &&
				   library.release_worker_ready(&library_client)) {wait_ms = 40}
		for pending in library_client.pending {
			if pending {wait_ms = 40; break}
		}
		if preload_worker != nil && stage != .Playing {wait_ms = 40}
	}
	// Only steady playback uses 30 fps. Count from the last layout start,
	// so rendering and presentation time are part of the frame budget.
	if stage == .Playing && wait_ms != 0 {
		elapsed := sdl.GetTicksNS() - last
		remaining_ms := i32(0)
		if elapsed < PLAYBACK_FRAME_NS {
			remaining_ms = i32((PLAYBACK_FRAME_NS - elapsed + 999_999) / 1_000_000)
		}
		wait_ms = wait_ms < 0 ? remaining_ms : min(wait_ms, remaining_ms)
	}
	if (connect_client.worker != nil && WAKE_EVENT == 0) ||
	   emoji_poll ||
	   library_client.devices_pending ||
	   library_client.transfer_pending ||
	   remote_control {
		wait_ms = wait_ms < 0 ? 40 : min(wait_ms, 40)
	}
	// If the wake event could not be registered, poll the bus instead.
	if mpris_active && WAKE_EVENT == 0 && wait_ms < 0 {wait_ms = 100}
	if search_pending {
		tick := sdl.GetTicksNS()
		remaining_ms := i32(0)
		if search_deadline > tick {
			remaining_ms = i32((search_deadline - tick) / 1_000_000)
		}
		wait_ms = wait_ms < 0 ? remaining_ms : min(wait_ms, remaining_ms)
	}
	page_wait :=
		wait_ms != 0 && library_client.state == .Ready && time.since(library_client.page_at) < 0
	if page_wait {
		delay := -time.since(library_client.page_at)
		remaining_ms := i32(
			clamp(int((delay + time.Millisecond - 1) / time.Millisecond), 1, int(max(i32))),
		)
		wait_ms = wait_ms < 0 ? remaining_ms : min(wait_ms, remaining_ms)
	}
	if blink_wait := ui.editor_blink_delay(&editor, sdl.GetTicks()); blink_wait >= 0 {
		wait_ms = wait_ms < 0 ? blink_wait : min(wait_ms, blink_wait)
	}
	has_event := sdl.WaitEventTimeout(&event, wait_ms)
	if has_event {
		for {
			#partial switch event.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				running = false
			case .SYSTEM_THEME_CHANGED:
				next_dark := system_dark()
				if next_dark != theme_dark {
					theme_dark = next_dark
					apply_theme(theme_dark)
					when ODIN_OS == .Windows {ui.windows_frame_theme(state.window, theme_dark)}
					retint_icons(&textures, theme_dark)
					retint_fades(&textures)
					first_frame = true
				}
			case .MOUSE_BUTTON_UP:
				if event.button.button == sdl.BUTTON_LEFT {
					if resizing {
						app_state.sidebar_width = sidebar_width
						state_dirty = true
					}
					resizing = false
				}
			case .KEY_DOWN:
				if input_active {
					key_mod := event.key.mod
					gui := .LGUI in key_mod || .RGUI in key_mod
					alt := .LALT in key_mod || .RALT in key_mod
					shift := .LSHIFT in key_mod || .RSHIFT in key_mod
					cmd := .LCTRL in key_mod || .RCTRL in key_mod || gui
					switch event.key.key {
					case sdl.K_ESCAPE:
						ui.editor_move(&editor, editor.caret)
						editor.selecting = false
						input_active = false
						_ = sdl.StopTextInput(state.window)
						if len(strings.trim_space(input)) == 0 && search_mode {
							library.clear_search(&library_client)
							search_mode, search_pending = false, false
							delete(input)
							input = {}
							nav_replace(
								&nav,
								nav_capture(&library_client, filter, false, search_kind, ""),
							)
						}
					case sdl.K_BACKSPACE, sdl.K_DELETE, sdl.K_W:
						if event.key.key == sdl.K_W && !cmd {break}
						low, high := ui.editor_bounds(&editor)
						if low == high {
							backward := event.key.key != sdl.K_DELETE
							at := ui.editor_step(input, editor.caret, backward)
							if cmd || alt {
								if gui && !alt {
									at = backward ? 0 : len(input)
								} else {at = ui.editor_word_step(input, editor.caret, backward)}
							}
							ui.editor_move(&editor, at, true)
						}
						input_changed = ui.editor_insert(&editor, "", 512) || input_changed
					case sdl.K_LEFT, sdl.K_RIGHT, sdl.K_HOME, sdl.K_END:
						backward := event.key.key == sdl.K_LEFT || event.key.key == sdl.K_HOME
						low, high := ui.editor_bounds(&editor)
						at := backward ? low : high
						if event.key.key == sdl.K_HOME || event.key.key == sdl.K_END || gui {
							at = backward ? 0 : len(input)
						} else if cmd || alt {
							at = ui.editor_word_step(input, editor.caret, backward)
						} else if shift ||
						   low == high {at = ui.editor_step(input, editor.caret, backward)}
						ui.editor_move(&editor, at, shift)
					case sdl.K_A:
						if cmd {ui.editor_select_all(&editor)}
					case sdl.K_U:
						if cmd {
							ui.editor_select_all(&editor)
							input_changed = ui.editor_insert(&editor, "", 512) || input_changed
						}
					case sdl.K_C, sdl.K_X, sdl.K_V, sdl.K_INSERT:
						inserting := event.key.key == sdl.K_INSERT
						if !cmd && !(inserting && shift) {break}
						cutting := event.key.key == sdl.K_X
						copying := event.key.key == sdl.K_C || inserting && !shift
						if copying || cutting {
							low, high := ui.editor_bounds(&editor)
							if low != high {
								c_input := strings.clone_to_cstring(input[low:high])
								defer delete(c_input)
								if sdl.SetClipboardText(c_input) && cutting {
									input_changed =
										ui.editor_insert(&editor, "", 512) || input_changed
								}
							}
						} else {
							clipboard := sdl.GetClipboardText()
							if clipboard != nil {
								value := paste_text(string(cstring(clipboard)))
								limit := library_client.state == .Missing_Client_ID ? 64 : 512
								if len(value) > 0 {
									input_changed =
										ui.editor_insert(&editor, value, limit) || input_changed
								}
								sdl.free(rawptr(clipboard))
							}
						}
					case sdl.K_RETURN, sdl.K_KP_ENTER:
						ui.editor_move(&editor, editor.caret)
						if library_client.state == .Missing_Client_ID {
							submit_setup(app)
							break
						}
						_, valid := track.parse_id(input)
						if valid {
							delete(selected)
							selected = strings.clone(strings.trim_space(input))
							delete(player_cover)
							player_cover = {}
							delete(displayed_cover)
							displayed_cover = {}
							free_play_queue(&play_queue)
							delete(queue_detail)
							queue_detail = ""
							queue_rows = 0
							play_index = -1
							delete(input)
							input = {}
							input_active = false
							_ = sdl.StopTextInput(state.window)
							library.clear_search(&library_client)
							search_mode = false
							search_pending = false
						} else if len(strings.trim_space(input)) > 0 {
							search_pending = false
							if library.search(&library_client, input) {
								search_mode = true
								nav_save_scroll(&nav, detail_scroll_y())
								nav_record_search(
									&nav,
									&library_client,
									filter,
									search_kind,
									input,
								)
							}
						}
					}
				} else if !event.key.repeat {
					switch event.key.key {
					case sdl.K_SPACE:
						space_pressed = true
					case sdl.K_LEFT:
						if .LALT in event.key.mod {nav_back_pressed = true}
					case sdl.K_RIGHT:
						if .LALT in event.key.mod {nav_forward_pressed = true}
					case sdl.K_K:
						mod := event.key.mod
						if .LCTRL in mod || .RCTRL in mod || .LGUI in mod || .RGUI in mod {
							if !input_active {
								input_active = sdl.StartTextInput(state.window)
								ui.editor_move(&editor, len(input))
							}
						}
					}
				}
			case .TEXT_INPUT:
				if input_active &&
				   .LCTRL not_in sdl.GetModState() &&
				   .RCTRL not_in sdl.GetModState() &&
				   .LGUI not_in sdl.GetModState() &&
				   .RGUI not_in sdl.GetModState() {
					added := string(event.text.text)
					// The setup field holds at most a 32-character key;
					// search keeps its longer limit.
					limit := library_client.state == .Missing_Client_ID ? 64 : 512
					if input_text_ok(added) {
						input_changed = ui.editor_insert(&editor, added, limit) || input_changed
					}
				}
			case .MOUSE_WHEEL:
				autoscroll_container = ""
				wheel.x += event.wheel.x; wheel.y += event.wheel.y
			case .MOUSE_BUTTON_DOWN:
				if event.button.button == sdl.BUTTON_MIDDLE {
					// Steering lasts while the button is held; releasing it
					// lands the anchor. Pressing again while held re-parks.
					if autoscroll_container == "" {
						middle_click = ui.mouse_position(&state, event.button.x, event.button.y)
						middle_clicked = true
					}
				} else if autoscroll_container != "" {
					// Any other button lands the anchor; the click is swallowed.
					autoscroll_container = ""
				} else if event.button.button == sdl.BUTTON_LEFT {
					mouse_click = ui.mouse_position(&state, event.button.x, event.button.y)
					clicked = true
					click_count = event.button.clicks
				} else if event.button.button == sdl.BUTTON_RIGHT {
					mouse_right = ui.mouse_position(&state, event.button.x, event.button.y)
					right_clicked = true
				} else if event.button.button == sdl.BUTTON_X1 {
					nav_back_pressed = true
				} else if event.button.button == sdl.BUTTON_X2 {
					nav_forward_pressed = true
				}
			}
			if !sdl.PollEvent(&event) {break}
		}
	}
	// A page backoff must expire without requiring mouse movement to wake it.
	return has_event ||
		emoji_poll ||
		page_wait && time.since(library_client.page_at) >= 0 ||
		ui.editor_blink_delay(&editor, sdl.GetTicks()) == 0,
		fades_animating
}

// History moves plus the banked scroll offset that follows them.
app_navigate :: proc(app: ^App, frame: ^Frame) {
	using app
	using frame
	if nav_back_pressed || nav_forward_pressed {
		nav_state: Nav_State
		moved := false
		// The container vanishes while the next page loads, so the
		// offset is banked before leaving and restored after.
		nav_save_scroll(&nav, detail_scroll_y())
		if nav_back_pressed {
			nav_back_pressed = false
			nav_state, moved = nav_back(&nav)
		} else {
			nav_forward_pressed = false
			nav_state, moved = nav_forward(&nav)
		}
		if moved {
			nav_restore(
				nav_state,
				&library_client,
				&app_state,
				&state_dirty,
				&filter,
				&search_mode,
				&search_kind,
				&input,
				&detail_pinned,
			)
			ui.editor_move(&editor, len(input))
			editor.selecting = false
			if len(nav_state.detail.uri) == 0 {
				detail_scroll_armed = false
			} else {
				detail_scroll_target = nav_state.detail_scroll
				detail_scroll_armed = true
			}
			redraw = true
		}
	}
}

// Debounced catalog search driven by input edits.
app_search :: proc(app: ^App, frame: ^Frame) {
	using app
	using frame
	if input_changed {
		input_changed = false
		trimmed := strings.trim_space(input)
		if len(trimmed) == 0 {
			library.clear_search(&library_client)
			search_mode = false
			search_pending = false
			nav_replace(&nav, nav_capture(&library_client, filter, false, search_kind, ""))
		} else if _, valid := track.parse_id(trimmed); valid {
			// A pasted link waits for Enter; never catalog-search it.
			library.clear_search(&library_client)
			search_mode = false
			search_pending = false
			nav_replace(&nav, nav_capture(&library_client, filter, false, search_kind, input))
		} else {
			search_pending = true
			search_deadline = sdl.GetTicksNS() + SEARCH_DEBOUNCE_NS
		}
	}
	if search_pending && sdl.GetTicksNS() >= search_deadline {
		search_pending = false
		if library.search(&library_client, input) {
			search_mode = true
			nav_save_scroll(&nav, detail_scroll_y())
			nav_record_search(&nav, &library_client, filter, search_kind, input)
		}
	}
}

// Worker joins, library polling and sorting, cover uploads and the
// reopened-collection restore.
app_library :: proc(app: ^App, frame: ^Frame) {
	using app
	using frame
	if preload_worker != nil && thread.is_done(preload_worker) {
		thread.destroy(preload_worker)
		preload_worker = nil
	}
	if library_client.worker == nil {
		_ = library.start(&library_client)
	}
	if library.poll(&library_client) {redraw = true}
	library.advance_releases(&library_client)
	if sync.atomic_exchange(&connect_client.pending, false) {redraw = true}
	// Stop local audio before entering remote control. This must happen
	// before app_playback, not in layout, where the frame flag is lost.
	if last_transfer_pending && !library_client.transfer_pending {
		delete(toast)
		if library_client.transfer_ok && !transfer_here {
			toast = strings.clone("Playback transferred")
			if preload_worker != nil {sync.atomic_store(&preload_work.cancel, true)}
			play_after_stop, replay_pending = false, false
			seek_dragging, start_paused = false, false
			seek_ms = 0
			if worker != nil && stage != .Stopping {
				cancel_worker(queue, &cancel)
				clear_audio_stream(&stream)
				stage = .Stopping
			}
			remote_control = true
			remote_polled_at = 0
			_ = library.refresh_devices(&library_client)
		} else {
			toast = strings.clone(
				library_client.transfer_ok ? "Playback transferred" : "Couldn't transfer playback",
			)
		}
		toast_until = sdl.GetTicksNS() + 2_500_000_000
	}
	last_transfer_pending = library_client.transfer_pending
	// Sort before layout so a landed revalidation or a fresh pin paints in
	// the correct order on the same frame instead of the next one.
	sort_library_pages(&library_client, &app_state, &page_counts, order_dirty)
	order_dirty = false
	library_prompt = prompt_pending(.Library)
	if library_prompt != library_prompt_shown {
		library_prompt_shown = library_prompt
		redraw = true
	}
	playback_prompt = prompt_pending(.Playback)
	if playback_prompt {
		if !playback_prompt_opened {
			playback_prompt_opened = true
			_ = open_prompt_url(.Playback)
			redraw = true
		}
	} else if playback_prompt_opened {
		playback_prompt_opened = false
		redraw = true
	}
	if queue_restore_pending &&
	   library_client.detail.ready &&
	   !library_client.detail_loading &&
	   detail_matches_uri(library_client.detail, queue_detail) {
		queue_gen = library_client.detail.generation
		queue_restore_pending = false
	}
	// Playback can start before the last page lands; newly arrived rows
	// extend the live queue in place when it still mirrors this page.
	if len(queue_detail) > 0 &&
	   library_client.detail.ready &&
	   detail_matches_uri(library_client.detail, queue_detail) &&
	   queue_gen == library_client.detail.generation &&
	   queue_rows < len(library_client.detail.rows) {
		append_play_queue_tail(
			&play_queue,
			library_client.detail.rows[queue_rows:],
			library_client.detail.image_small,
		)
		queue_rows = len(library_client.detail.rows)
		stamp_queue_album(&play_queue, &library_client.detail)
		state_dirty = true
		redraw = true
	}
	// Spread texture uploads across frames; draining a backlog at once
	// stalls a frame for every rounded corner and GPU upload in it.
	uploads := 6
	for uploads > 0 {
		cover, received := library.take_cover(&library_client)
		if !received {break}
		uploads -= 1
		redraw = true
		request := textures.requested[cover.key]
		request.pending = false
		textures.requested[cover.key] = request
		if len(cover.image.pixels) > 0 {
			ui.round_image_pixels(cover.image.pixels, cover.image.width, cover.image.height)
			texture := ui.create_texture(
				&state,
				cover.image.pixels,
				cover.image.width,
				cover.image.height,
			)
			if texture != nil {
				textures.by_key[cover.key] = texture
				request.bytes = cover.image.width * cover.image.height * 4
				request.used = textures.cover_frame + 1
				textures.requested[cover.key] = request
				textures.cover_bytes += request.bytes
			}
			delete(cover.image.pixels)
		}
	}
	if restore_pending && library_client.state == .Ready {
		restore_pending = false
		// The library root is always the first history entry, so a restored
		// collection lands on top of it and back closes it again.
		nav_commit(&nav, nav_capture(&library_client, filter, search_mode, search_kind, input))
		if !library_client.detail.ready &&
		   !library_client.detail_loading &&
		   len(app_state.last_collection) > 0 {
			source, id, valid := parse_card_uri(app_state.last_collection)
			if valid {
				preview := state_collection_preview(&app_state, &library_client)
				if library.open_detail(&library_client, source, id, preview) {
					detail_pinned = state_is_pinned(&app_state, app_state.last_collection)
					nav_commit(
						&nav,
						nav_capture(&library_client, filter, search_mode, search_kind, input),
					)
				}
			}
		}
	}
}

// Playback worker lifecycle, decoder packets, end-of-track advance and
// next-track preload.
app_playback :: proc(app: ^App, frame: ^Frame) {
	using app
	using frame
	if stop_pressed {
		if preload_worker != nil {sync.atomic_store(&preload_work.cancel, true)}
		seek_dragging, start_paused = false, false
		seek_ms = 0
		play_after_stop, replay_pending = false, false
	}
	if stop_pressed && worker != nil && stage != .Stopping {
		cancel_worker(queue, &cancel)
		clear_audio_stream(&stream)
		stage = .Stopping
	}
	if stage == .Stopping && thread.is_done(worker) {
		redraw = true
		release_worker(worker, queue, &cancel)
		worker = nil
		finished = false
		sent_frames, sample_rate = 0, 0
		displayed_ms = seek_ms
		stage = .Idle
		if play_after_stop {
			// Cleared when the new worker starts, so the footer holds
			// pause across the idle handoff frame instead of flickering.
			space_pressed = true
		}
	}
	if stage == .Failed && worker != nil {
		start_paused = false
		cancel_worker(queue, &cancel)
		if thread.is_done(worker) {
			release_worker(worker, queue, &cancel)
			worker = nil
		}
	}
	if stage != .Paused &&
	   stage != .Stopping &&
	   stage != .Failed &&
	   worker != nil &&
	   (stream == nil || sdl.GetAudioStreamQueued(stream) < player.PCM_BYTES * 2) {
		packet, received := chan.try_recv(queue)
		if received {
			redraw = true
			switch packet.kind {
			case .Ready:
				diagnostic.write("playback metadata ready")
				delete(title)
				title = packet.name
				// Update the artist with the title, not while the next track loads.
				ready_artist := ""
				if play_index >= 0 &&
				   play_index < len(play_queue) &&
				   play_queue[play_index].uri == selected {
					ready_artist = play_queue[play_index].artist
					replace_string(&play_queue[play_index].name, title)
					play_queue[play_index].duration_ms = packet.duration_ms
				}
				replace_string(&artist, ready_artist)
				duration_ms = packet.duration_ms
				stage = .Buffering
			case .Audio:
				if stream == nil {
					spec := sdl.AudioSpec {
						format   = .S16,
						channels = 2,
						freq     = c.int(packet.sample_rate),
					}
					stream = sdl.OpenAudioDeviceStream(
						sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK,
						&spec,
						nil,
						nil,
					)
					if stream != nil {
						_ = sdl.SetAudioStreamGain(stream, volume)
						if !start_paused {_ = sdl.ResumeAudioStreamDevice(stream)}
					}
					sent_frames = packet.position_frames
					sample_rate = packet.sample_rate
				}
				if stream == nil ||
				   !sdl.PutAudioStreamData(
						   stream,
						   raw_data(packet.pcm),
						   c.int(packet.frames * 2 * size_of(i16)),
					   ) {
					fmt.eprintln("SDL3 audio device or stream failed:", sdl.GetError())
					stage = .Failed
				} else {
					sent_frames += packet.frames
					stage = start_paused ? .Paused : .Playing
					start_paused = false
				}
				delete(packet.pcm)
			case .End:
				diagnostic.write("playback decoder reached end")
				finished = true
				if stream != nil {_ = sdl.FlushAudioStream(stream)} else {stage = .Ended}
			case .Unavailable:
				diagnostic.write("playback skipped unavailable track")
				library.discard_unavailable_track(&library_client, selected)
				play_after_stop = discard_play_track(
					&play_queue,
					selected,
					&play_index,
					&queue_rows,
				)
				if !play_after_stop && connect_repeat_context && len(play_queue) > 0 {
					play_index, play_after_stop = 0, true
				}
				if play_after_stop {
					_ = select_play_item(play_queue[:], play_index, &selected, &player_cover)
				} else {
					replace_string(&selected, "")
					replace_string(&title, "")
					replace_string(&artist, "")
				}
				start_paused, replay_pending, seek_dragging = false, false, false
				seek_ms = 0
				clear_audio_stream(&stream)
				cancel_worker(queue, &cancel)
				stage = .Stopping
				state_dirty = true
				show_toast(app, "Unavailable track removed")
			case .Failed:
				diagnostic.write("playback worker failed")
				fmt.eprintln("sign-in, CDN stream, or Vorbis decoding failed")
				stage = .Failed
			}
		}
	}
	if finished && stage == .Playing && stream != nil && sdl.GetAudioStreamQueued(stream) == 0 {
		stage = .Ended
		if !seek_dragging {
			if repeat ||
			   advance_play_item(play_queue[:], &play_index, 1, &selected, &player_cover) {
				replay_pending = true
			} else if connect_repeat_context && len(play_queue) > 0 {
				play_index = 0
				replay_pending = select_play_item(
					play_queue[:],
					play_index,
					&selected,
					&player_cover,
				)
			} else {
				app_finish_queue(app)
			}
		}
		redraw = true
	}
	if replay_pending && stage == .Ended && worker != nil && thread.is_done(worker) {
		// Cleared on worker start like play_after_stop.
		space_pressed = true
		redraw = true
	}
	if stage == .Playing && play_index >= 0 && play_index + 1 < len(play_queue) {
		next_uri := play_queue[play_index + 1].uri
		if preload_worker != nil && preload_work.track != next_uri {
			sync.atomic_store(&preload_work.cancel, true)
		}
		if preload_worker == nil && next_uri != preload_attempted && next_uri != selected {
			clear_preload(&preload_work)
			delete(preload_attempted)
			preload_attempted = strings.clone(next_uri)
			preload_work = {
				track = strings.clone(next_uri),
			}
			preload_worker = thread.create_and_start_with_data(&preload_work, preload_track)
		}
	}
}

// Wheel glides ease toward their targets before the idle check so a
// settling glide keeps frames coming by itself.
app_glide :: proc(app: ^App, frame: ^Frame) {
	using app
	using frame
	smooth_dt := f32(sdl.GetTicksNS() - last) / 1e9
	if smooth_step("playlist_picker", &picker_smooth, smooth_dt) {redraw = true}
	if smooth_step("device_picker", &device_smooth, smooth_dt) {redraw = true}
	if smooth_step("queue_rows", &queue_smooth, smooth_dt) {redraw = true}
	if smooth_step("library_grid", &grid_smooth, smooth_dt) {redraw = true}
	if smooth_step("detail_rows", &detail_smooth, smooth_dt) {redraw = true}
	// The autoscroll step runs after layout, so a gliding frame must
	// not take the idle continue. Last frame's flag keeps held-still
	// autoscroll advancing until it parks in the dead zone.
	if autoscroll_moving || editor.selecting {redraw = true}
}

// Progress, view assembly, layout, cursor and render. Returns what the
// click and cover stages walk.
app_layout :: proc(app: ^App, frame: ^Frame) -> Frame_Visible {
	using app
	using frame
	mouse_x, mouse_y: f32
	buttons = sdl.GetMouseState(&mouse_x, &mouse_y)
	mouse = ui.mouse_position(&state, mouse_x, mouse_y)
	if editor.selecting {
		ui.editor_drag(&state, &editor, mouse.x)
		if .LEFT not_in buttons {editor.selecting = false}
	}
	clay.SetPointerState({mouse.x, mouse.y}, .LEFT in buttons)
	previous_density := ui.scale(&state)
	density = ui.update_scale(&state)
	if density != previous_density {clay.ResetMeasureTextCache()}
	progress := f32(0)
	if duration_ms > 0 {
		// Kept times hold the bar steady across worker swaps; live audio
		// refines it below.
		progress = f32(displayed_ms) / f32(duration_ms)
		if sample_rate > 0 && stream != nil {
			queued := max(0, sdl.GetAudioStreamQueued(stream))
			measured_ms := (sent_frames - int(queued) / 4) * 1000 / sample_rate
			displayed_ms = max(displayed_ms, clamp(measured_ms, 0, duration_ms))
			progress = f32(displayed_ms) / f32(duration_ms)
		}
	}
	shown_ms := displayed_ms
	if remote_control {
		// The bar tracks the polled remote position; the drag preview
		// below still wins while scrubbing.
		shown_ms = library_client.remote_progress
		if duration_ms > 0 {progress = f32(shown_ms) / f32(duration_ms)}
	}
	seek_enabled =
		duration_ms > 0 &&
		(remote_control || stage == .Playing || stage == .Paused || stage == .Ended)
	if seek_dragging && seek_enabled {
		box := clay.GetElementData(clay.ID("seek_slider")).boundingBox
		preview_x: f32
		_ = sdl.GetMouseState(&preview_x, nil)
		point := ui.mouse_position(&state, preview_x, 0)
		preview := seek_position_ms(point.x, box.x, box.width, duration_ms)
		progress = f32(preview) / f32(duration_ms)
		shown_ms = preview
	}
	button := "play"
	if stage == .Paused {button = "resume"}
	// Transitional stages keep the pause icon while a (re)start is in
	// flight, so next/previous never flicker through the play triangle.
	if stage == .Playing ||
	   stage == .Signing_In ||
	   stage == .Buffering ||
	   (play_after_stop && (stage == .Stopping || stage == .Idle)) ||
	   (replay_pending && stage == .Ended) {button = "pause"}
	// A seek from paused lands back on paused, so its handoff keeps
	// the resume icon instead of flashing pause.
	if start_paused && button == "pause" {button = "resume"}
	if remote_control {button = library_client.remote_playing ? "pause" : "play"}
	status := "Ready to play"
	switch stage {
	case .Signing_In:
		status = playback_prompt ? "Approve playback in your browser" : "Loading track..."
	case .Buffering:
		status = "Buffering audio..."
	case .Playing:
		status = "Playing from Spotify"
	case .Paused:
		status = "Paused"
	case .Ended:
		status = "Track ended. Press play to replay."
	case .Failed:
		status = "Could not play. Press play to retry."
	case .Stopping:
		status = "Stopping..."
	case .Idle:
		// No history yet shows nothing, not a placeholder.
		status = len(title) > 0 ? "Ready to play" : ""
	}
	shown_title := title
	// The footer names the artist like spotifast; the status line only
	// surfaces while nothing is known or when playback failed.
	shown_status := status
	if stage != .Failed && len(artist) > 0 && !(stage == .Signing_In && playback_prompt) {
		shown_status = artist
	}
	if remote_control && len(library_client.remote_device) > 0 {
		shown_status = fmt.aprintf(
			"Controlling %s",
			library_client.remote_device,
			allocator = context.temp_allocator,
		)
	}
	shown_input := input
	if library_client.state != .Missing_Client_ID {
		if len(shown_input) == 0 {
			shown_input = input_active ? "" : "Search Spotify or paste a track link"
		}
	}
	times: [2][16]u8
	retain_player_cover(&displayed_cover, player_cover, &textures)
	// The footer links the playing collection: the title its album, the
	// artist its artist. Search queues carry no URIs and stay silent.
	// The live queue is the truth, even when it links nothing; the
	// persisted record only serves the queue-less resumed footer.
	queue_at = play_index >= 0 && play_index < len(play_queue)
	foot_album, foot_album_uri = "", ""
	foot_first, foot_first_uri = "", ""
	if queue_at {
		item := play_queue[play_index]
		foot_album, foot_album_uri = item.album, item.album_uri
		if len(item.artist_links) > 0 {
			foot_first, foot_first_uri = item.artist_links[0].name, item.artist_links[0].uri
		}
	} else {
		foot_album, foot_album_uri = app_state.last_played.album, app_state.last_played.album_uri
		foot_first, foot_first_uri =
			app_state.last_played.first_artist, app_state.last_played.artist_uri
	}
	link_album = len(foot_album_uri) > 0
	link_artist = len(foot_first_uri) > 0
	devices_active := false
	for device in library_client.devices {
		if device.active {devices_active = true; break}
	}
	// A finished write shows its outcome for a moment; the toast is the
	// only signal that a change the user cannot see actually landed.
	if last_write_pending && !library_client.write_pending {
		verb := library_client.write_removed ? "Removed from" : "Added to"
		if !library_client.write_ok {
			verb =
				library_client.write_partial ? "Some tracks added; couldn't finish adding to" : library_client.write_removed ? "Couldn't remove from" : "Couldn't add to"
		}
		delete(toast)
		toast = fmt.aprintf("%s %s", verb, library_client.write_name)
		toast_until = sdl.GetTicksNS() + 2_500_000_000
	}
	last_write_pending = library_client.write_pending
	width, height = ui.size(&state)
	// The picker submenu opens while the pointer is over the add row and
	// stays open while it is over the menu or the panel, so the pointer
	// can cross the small gap between them. Boxes are one frame old.
	if menu.open {
		add_index := menu_add_index(&menu)
		add_box := clay.GetElementData(clay.ID("menu_item", u32(max(add_index, 0)))).boundingBox
		menu_box := clay.GetElementData(clay.ID("context_menu")).boundingBox
		panel_box := clay.GetElementData(clay.ID("playlist_picker_panel")).boundingBox
		corridor := menu_box
		corridor.width += 8 * density
		over_add := add_index >= 0 && point_in_box(mouse, add_box)
		over_picker := point_in_box(mouse, panel_box) || point_in_box(mouse, corridor)
		menu.picker_open = over_add || (menu.picker_open && over_picker)
	} else {
		menu.picker_open = false
	}
	if menu.picker_open {rebuild_picker_items(&menu, &library_client)}
	// A picker is an explicit ask for the full list, so keep paging the
	// sidebar's playlist tab while it is open; the page interval paces it.
	if menu.picker_open {library.more(&library_client, .Playlists)}
	view := View {
		title          = shown_title,
		status         = shown_status,
		album_linked   = link_album,
		artist_linked  = link_artist,
		button         = button,
		progress       = progress,
		elapsed        = duration_text(shown_ms, times[0][:]),
		total          = duration_text(duration_ms, times[1][:]),
		input          = shown_input,
		cover          = displayed_cover,
		repeat         = repeat,
		shuffle        = shuffle,
		volume         = volume,
		input_active   = input_active,
		input_editor   = &editor,
		pinned         = detail_pinned,
		search_mode    = search_mode,
		releases       = library_client.release_feed.open,
		sign_in        = library_prompt,
		setup_error    = setup_error,
		can_back       = nav_can_back(&nav),
		can_forward    = nav_can_forward(&nav),
		search_kind    = search_kind,
		menu           = &menu,
		queue_open     = queue_open,
		queue_items    = play_queue[:],
		queue_index    = play_index,
		device_open    = device_open,
		device_active  = devices_active,
		device_rows    = library_client.devices[:],
		device_loading = library_client.devices_pending,
		device_error   = library_client.devices_error,
		drag_active    = dragging,
		drag_x         = mouse.x,
		drag_y         = mouse.y,
		drag_label     = drag_label,
		drop_target    = drop_target,
		toast          = toast,
		scroll_active  = autoscroll_container != "",
		scroll_x       = autoscroll_anchor.x,
		scroll_y       = autoscroll_anchor.y,
		current_uri    = selected,
		playing        = stage == .Playing,
	}
	wheel_used := scroll_wheel("device_picker", wheel.y, density, &device_smooth)
	if !wheel_used {wheel_used = scroll_wheel("playlist_picker", wheel.y, density, &picker_smooth)}
	if !wheel_used {wheel_used = scroll_wheel("queue_rows", wheel.y, density, &queue_smooth)}
	if !wheel_used {wheel_used = scroll_wheel("library_grid", wheel.y, density, &grid_smooth)}
	if !wheel_used {
		wheel_used = scroll_wheel("detail_rows", wheel.y, density, &detail_smooth)
		if wheel_used {detail_scroll_armed = false}
	}
	t0 := sdl.GetTicksNS()
	now := sdl.GetTicksNS()
	dt := f32(now - last) / 1e9
	last = now
	clay.UpdateScrollContainers(false, {}, dt)
	card_text_height :=
		f32(ttf.GetFontHeight(ui.font_for_size(&state, 14 * density))) +
		f32(ttf.GetFontHeight(ui.font_for_size(&state, 12 * density)))
	t1 := sdl.GetTicksNS()
	fx := Button_Fx_Ctx {
		anims      = &button_anims,
		mouse_down = .LEFT in buttons,
	}
	// Fresh pages start at the top. Warm opens keep the scroll
	// container alive across the switch, so without this the
	// previous page's offset (and glide) would carry over and a
	// long playlist would reopen at its bottom skeleton tail.
	detail_changed :=
		library_client.release_feed.open ? last_detail_uri != "spoti:releases" : !detail_matches_uri(library_client.detail, last_detail_uri)
	if detail_changed {
		delete(last_detail_uri)
		last_detail_uri = strings.clone(
			library_client.release_feed.open ? "spoti:releases" : detail_card_uri(library_client.detail),
		)
		if data := clay.GetScrollContainerData(clay.ID("detail_rows"));
		   data.found && data.scrollPosition != nil {
			data.scrollPosition.y = 0
		}
		detail_smooth.target = 0
		detail_smooth.active = false
	}
	when ODIN_OS == .Windows {view.caption_width = ui.windows_caption_width(state.window)}
	commands: clay.ClayArray(clay.RenderCommand)
	visible: Frame_Visible
	for pass in 0 ..< 2 {
		commands, visible = layout(
			view,
			&library_client,
			&app_state,
			filter,
			&textures,
			&fx,
			sidebar_width,
			f32(width),
			f32(height),
			card_text_height,
			pass == 0 ? dt : 0,
			density,
			&state,
			&hero_cache,
		)
		// Current dimensions are known only after layout. If history changes
		// the offset, rebuild the visible rows and commands before drawing.
		// The second pass must not advance animations again.
		if !detail_scroll_armed ||
		   !library_client.detail.ready ||
		   library.detail_loading_visible(&library_client) {break}
		scroll_data := clay.GetScrollContainerData(clay.ID("detail_rows"))
		if !scroll_data.found || scroll_data.scrollPosition == nil {break}
		viewport := scroll_data.scrollContainerDimensions.height
		content := scroll_data.contentDimensions.height
		if viewport <= 0 {break}
		loaded := !library_client.detail_loading && !library_client.detail.has_more
		pos := clamp(detail_scroll_target, min(0, viewport - content), 0)
		previous := scroll_data.scrollPosition.y
		scroll_data.scrollPosition.y = pos
		detail_smooth.target = pos
		detail_smooth.active = false
		// Keep the target while a partial page is still too short to reach it.
		if pos == detail_scroll_target || loaded {detail_scroll_armed = false}
		if pos == previous {break}
	}
	fx_animating = fx.animating
	if middle_clicked {
		middle_clicked = false
		for id in ([]string{"queue_rows", "library_grid", "detail_rows"}) {
			if !hit(id, middle_click) {continue}
			data := clay.GetScrollContainerData(clay.ID(id))
			if data.found &&
			   data.contentDimensions.height > data.scrollContainerDimensions.height {
				autoscroll_container = id
				autoscroll_anchor = middle_click
				if id == "detail_rows" {detail_scroll_armed = false}
				break
			}
		}
	}
	if autoscroll_container != "" {
		smooth_cancel(
			autoscroll_container,
			smooth_for(autoscroll_container, &grid_smooth, &detail_smooth, &queue_smooth),
		)
		data := clay.GetScrollContainerData(clay.ID(autoscroll_container))
		if !data.found || .MIDDLE not_in buttons {
			autoscroll_container = ""
			autoscroll_moving = false
		} else {
			autoscroll_moving = autoscroll_step(
				autoscroll_container,
				mouse.y - autoscroll_anchor.y,
				dt,
				density,
			)
			if autoscroll_moving {redraw = true}
		}
	} else {autoscroll_moving = false}
	t2 := sdl.GetTicksNS()
	update_cursor(
		&state,
		&library_client,
		resizing,
		visible,
		seek_enabled,
		search_mode,
		link_album,
		link_artist,
	)
	_ = sdl.SetRenderDrawColor(state.renderer, 18, 18, 18, 255)
	_ = sdl.RenderClear(state.renderer)
	render(&commands, &state, &textures)
	ui.frame_done(&state)
	trim_cover_textures(&textures, displayed_cover, player_cover)
	t3 := sdl.GetTicksNS()
	stage_sum[0] += f64(t1 - t0) / 1e6
	stage_sum[1] += f64(t2 - t1) / 1e6
	stage_sum[2] += f64(t3 - t2) / 1e6
	stage_max[0] = max(stage_max[0], f64(t1 - t0) / 1e6)
	stage_max[1] = max(stage_max[1], f64(t2 - t1) / 1e6)
	stage_max[2] = max(stage_max[2], f64(t3 - t2) / 1e6)
	stage_n += 1
	if stage_n >= 240 {
		diagnostic.frame(
			stage_sum[0] / f64(stage_n),
			stage_sum[1] / f64(stage_n),
			stage_sum[2] / f64(stage_n),
			stage_max[0],
			stage_max[1],
			stage_max[2],
		)
		diagnostic.writef("text measures per frame=%d", state.text_measures / u64(stage_n))
		state.text_measures = 0
		stage_sum, stage_max, stage_n = {}, {}, 0
	}
	return visible
}

// Right-click menu plus the whole left-click cascade: toolbar, chips,
// cards, hero, rows and the click-away input release.
app_input_click :: proc(app: ^App, frame: ^Frame) {
	using app
	if !input_active {input_active = sdl.StartTextInput(state.window)}
	mod := sdl.GetModState()
	ui.editor_press(
		&state,
		&editor,
		frame.mouse_click.x,
		frame.click_count,
		.LSHIFT in mod || .RSHIFT in mod,
	)
	pending_redraw = true
}

app_click :: proc(app: ^App, frame: ^Frame, visible: Frame_Visible) {
	using app
	using frame
	if right_clicked && queue_open && hit("queue_panel", mouse_right) {
		if index := queue_item_at(play_index, visible.queue, mouse_right);
		   index >= 0 && index < len(play_queue) {
			open_link_menu(&menu, mouse_right, play_queue[index].uri)
		} else {menu.open = false}
	} else if right_clicked {
		open_menu_at(
			&menu,
			&library_client,
			display_page,
			display_kind,
			visible,
			mouse_right,
			&app_state,
		)
	}
	track_selected = false
	if clicked && menu.open {
		picked := false
		if menu.picker_open {
			for entry, index in menu.picker_items {
				if !hit_index("picker_item", mouse_click, u32(index)) {continue}
				if strings.has_prefix(entry.uri, "spotify:playlist:") {
					_ = library.queue_playlist_write(
						&library_client,
						entry.uri[len("spotify:playlist:"):],
						entry.name,
						menu.uri,
					)
				}
				picked = true
				break
			}
		}
		keep_open := false
		if !picked {
			for index in 0 ..< menu.count {
				if !hit_index("menu_item", mouse_click, u32(index)) {continue}
				switch menu.items[index] {
				case .Pin:
					_ = state_toggle_pin(&app_state, menu.uri)
					if menu.uri == detail_card_uri(library_client.detail) {
						detail_pinned = state_is_pinned(&app_state, menu.uri)
					}
					order_dirty = true
					state_dirty = true
				case .Pick_Sort:
					app_state.sort[filter] = menu.sorts[index]
					order_dirty = true
					state_dirty = true
				case .Copy_Link:
					copy_link(app, menu.uri)
				case .Open_In_Spotify:
					open_spotify_uri(menu.uri)
				case .Save_Album:
					if release := release_feed_find(&library_client, menu.uri);
					   release != nil && !library_client.like_pending {
						_ = library.toggle_like(
							&library_client,
							.Album,
							menu.uri[len("spotify:album:"):],
							!release_feed_saved(&library_client, release),
						)
					}
				case .Play:
					if release := release_feed_find(&library_client, menu.uri);
					   menu.track < 0 && release != nil {
						if release_feed_load_playback(&library_client, release.entry) {
							replace_string(&release_play_uri, menu.uri)
						}
					} else if menu.track >= 0 && menu.track < len(library_client.detail.rows) {
						track_selected = app_queue_detail(app, menu.track)
					}
				case .Add_To_Queue:
					_ = app_enqueue_uri(app, menu.uri)
				case .Add_To_Playlist:
					menu.picker_open = true
					keep_open = true
				case .Remove_From_Playlist:
					if len(library_client.detail.id) > 0 {
						_ = library.queue_playlist_write(
							&library_client,
							library_client.detail.id,
							library_client.detail.name,
							menu.uri,
							remove = true,
						)
					}
				}
				break
			}
		}
		if !keep_open {menu.open = false}
	} else if clicked {
		toggle_queue := hit("footer_queue", mouse_click)
		if toggle_queue || hit("queue_close", mouse_click) {
			queue_open = toggle_queue && !queue_open
			queue_smooth = {}
			if data := clay.GetScrollContainerData(clay.ID("queue_rows"));
			   data.found && data.scrollPosition != nil {data.scrollPosition.y = 0}
			pending_redraw = true
		} else if queue_open && hit("queue_scrollbar", mouse_click) {
			begin_scrollbar_drag(&scrollbar_drag, "queue_rows", mouse_click.y)
		} else if queue_open && hit("queue_panel", mouse_click) {
			index := queue_item_at(play_index, visible.queue, mouse_click)
			if index >= 0 && index < len(play_queue) {
				play_index = index
				track_selected = select_play_item(play_queue[:], index, &selected, &player_cover)
				pending_redraw = true
			}
		} else if hit("toolbar_releases", mouse_click) {
			if !library_client.release_feed.open {nav_save_scroll(&nav, detail_scroll_y())}
			was_open := library_client.release_feed.open
			library.open_releases(&library_client)
			if !was_open {
				detail_scroll_armed = false
				nav_commit(
					&nav,
					nav_capture(&library_client, filter, search_mode, search_kind, input),
				)
			}
		} else if library_client.release_feed.open && hit("detail_rows", mouse_click) {
			for index in visible.feed.first ..< visible.feed.last {
				if !hit_clipped("feed_row", "detail_rows", mouse_click, u32(index)) {continue}
				release := &library_client.release_feed.items[index]
				if hit(release_feed_action("save", index), mouse_click) {
					if !library_client.like_pending {
						_ = library.toggle_like(
							&library_client,
							.Album,
							release.entry.uri[len("spotify:album:"):],
							!release_feed_saved(&library_client, release),
						)
					}
				} else if hit(release_feed_action("play", index), mouse_click) {
					if release_feed_load_playback(&library_client, release.entry) {
						replace_string(&release_play_uri, release.entry.uri)
					}
				} else {
					_ = open_entry_page(&nav_ctx, release.entry)
				}
				break
			}
		} else if hit("library_scrollbar", mouse_click) {
			begin_scrollbar_drag(&scrollbar_drag, "library_grid", mouse_click.y)
		} else if hit("detail_scrollbar", mouse_click) {
			detail_scroll_armed = false
			begin_scrollbar_drag(&scrollbar_drag, "detail_rows", mouse_click.y)
		} else if hit("sidebar_handle", mouse_click) {
			resizing = true
		} else if hit("sort_button", mouse_click) {
			open_sort_menu(&menu, mouse_click, app_state.sort[filter])
		} else if hit("setup_field", mouse_click) {
			app_input_click(app, frame)
		} else if hit("setup_redirect", mouse_click) {
			c_uri := strings.clone_to_cstring(oauth.WEB_REDIRECT_URI)
			defer delete(c_uri)
			show_toast(
				app,
				sdl.SetClipboardText(c_uri) ? "Redirect URI copied" : "Could not copy redirect URI",
			)
		} else if hit("setup_dashboard", mouse_click) {
			open_dashboard()
		} else if hit("setup_save", mouse_click) {
			submit_setup(app)
		} else if hit("library_sign_in", mouse_click) {
			_ = open_prompt_url(.Library)
		} else if hit("library_retry", mouse_click) {
			if library.restart(&library_client) {redraw = true}
		} else if hit("detail_retry", mouse_click) {
			detail := &library_client.detail
			if library.open_detail(
				&library_client,
				detail.source,
				detail.id,
				{
					name = detail.name,
					image = detail.image,
					subtitle = detail.subtitle,
					year = detail.year,
					saved = detail.liked,
					total = detail.total,
				},
			) {redraw = true}
		} else {
			handled := false
			if hit("toolbar_back", mouse_click) {
				nav_back_pressed = true
				handled = true
			} else if hit("toolbar_forward", mouse_click) {
				nav_forward_pressed = true
				handled = true
			} else if hit("track_input", mouse_click) {
				app_input_click(app, frame)
				handled = true
			}
			if !handled {
				library_tabs, search_tabs := LIBRARY_TABS, SEARCH_TABS
				tabs := library_tabs[:]
				if search_mode {tabs = search_tabs[:]}
				for tab, index in tabs {
					if !hit_index("chip", mouse_click, u32(index)) {continue}
					current := search_mode ? search_kind : filter
					if current != tab {
						if search_mode {search_kind = tab} else {
							filter, app_state.tab = tab, tab
							state_dirty = true
						}
						nav_save_scroll(&nav, detail_scroll_y())
						nav_commit(
							&nav,
							nav_capture(&library_client, filter, search_mode, search_kind, input),
						)
					}
					if !search_mode {retry_failed_covers(&textures)}
					handled = true
					break
				}
			}
			if !handled {
				for index in visible.cards.first ..< visible.cards.last {
					entry := display_page.items[index]
					if !hit_clipped("card", "library_grid", mouse_click, u32(index)) {continue}
					if search_mode && display_kind == .Tracks {
						build_play_queue(&play_queue, display_page.items[:])
						queue_rows = len(display_page.items)
						delete(queue_detail)
						queue_detail = ""
						play_index =
							shuffle ? reorder_play_queue(play_queue[:], index, true) : index
						track_selected = select_play_item(
							play_queue[:],
							play_index,
							&selected,
							&player_cover,
						)
						handled = track_selected
					} else {
						handled = open_entry_page(&nav_ctx, entry)
					}
					break
				}
			}
			if !handled && library_client.detail.ready {
				for ai in 0 ..< min(len(library_client.detail.artist_links), 64) {
					link := library_client.detail.artist_links[ai]
					if len(link.uri) == 0 {continue}
					if !hit_index("hero_artist_link", mouse_click, u32(ai)) {continue}
					preview := library.Entry {
						name = link.name,
						uri  = link.uri,
					}
					handled = open_entry_page(&nav_ctx, preview)
					break
				}
			}
			if !handled && library_client.detail.ready {
				if hit("hero_like", mouse_click) {
					detail := library_client.detail
					if detail.source != .Liked &&
					   !library_client.detail_loading &&
					   !library_client.like_pending &&
					   library.toggle_like(
						   &library_client,
						   detail.source,
						   detail.id,
						   !detail.liked,
					   ) {
						handled = true
					}
				} else if hit("hero_pin", mouse_click) {
					detail_pinned = state_toggle_pin(
						&app_state,
						detail_card_uri(library_client.detail),
					)
					order_dirty = true
					state_dirty = true
					handled = true
				} else if hit("hero_copy_link", mouse_click) &&
				   !library.detail_loading_visible(&library_client) {
					copy_link(app, detail_card_uri(library_client.detail))
					handled = true
				} else if hit("spotify_link", mouse_click) && !library_client.detail_loading {
					open_spotify_uri(detail_card_uri(library_client.detail))
					handled = true
				} else if library_client.detail.source == .Artist {
					handled =
						open_release_card(
							&nav_ctx,
							mouse_click,
							"release_card",
							library_client.detail.albums.items[:],
							visible.releases,
						) ||
						open_release_card(
							&nav_ctx,
							mouse_click,
							"single_card",
							library_client.detail.singles.items[:],
							visible.singles,
						)
				}
				if !handled {
					for index in visible.tracks.first ..< visible.tracks.last {
						if !hit_clipped(
							"track_row",
							"detail_rows",
							mouse_click,
							u32(index),
						) {continue}
						// A linked artist opens its own page instead of
						// playing the row. Same compound IDs as the layout.
						if index < len(library_client.detail.rows) {
							row := library_client.detail.rows[index]
							slot := u32(index - visible.tracks.first)
							for ai in 0 ..< min(len(row.artist_links), 64) {
								link := row.artist_links[ai]
								if len(link.uri) == 0 {continue}
								if !hit_clipped(
									"artist_link",
									"detail_rows",
									mouse_click,
									artist_link_id(slot, ai),
								) {continue}
								preview := library.Entry {
									name = link.name,
									uri  = link.uri,
								}
								handled = open_entry_page(&nav_ctx, preview)
								break
							}
							if !handled &&
							   row.album_uri != "" &&
							   hit_clipped("album_link", "detail_rows", mouse_click, u32(index)) {
								handled = open_entry_page(
									&nav_ctx,
									library.Entry {
										name = row.album,
										uri = row.album_uri,
										image = row.image,
									},
								)
							}
							if handled {break}
						}
						// Arm a drag instead of playing: the play only fires
						// on release without a drag, so a drop onto a
						// playlist never also starts the track.
						delete(input)
						input = {}
						drag_candidate = true
						dragging = false
						drag_index = index
						drag_start = mouse_click
						delete(drag_uri)
						drag_uri = strings.clone(library_client.detail.rows[index].uri)
						delete(drag_label)
						drag_label = strings.clone(library_client.detail.rows[index].name)
						handled = true
						break
					}
				}
			}
			if !handled && input_active {
				input_active = false
				editor.selecting = false
				ui.editor_move(&editor, editor.caret)
				_ = sdl.StopTextInput(state.window)
			}
		}
	}
}

// Drag and drop, volume, shuffle, repeat, MPRIS commands, footer links,
// seeking and the play/pause/next/previous transport.
app_transport :: proc(app: ^App, frame: ^Frame, visible: Frame_Visible) {
	using app
	using frame
	incoming_load := false
	if drag_candidate && .LEFT in buttons {
		if !dragging && drag_started(mouse, drag_start, DRAG_THRESHOLD * density) {
			dragging = true
		}
	}
	if drag_candidate && .LEFT not_in buttons {
		if dragging {
			if display_kind == .Playlists {
				if index := grid_card_at(display_page, visible.cards, mouse); index >= 0 {
					entry := display_page.items[index]
					if strings.has_prefix(entry.uri, "spotify:playlist:") {
						_ = library.queue_playlist_write(
							&library_client,
							entry.uri[len("spotify:playlist:"):],
							entry.name,
							drag_uri,
						)
					}
				}
			}
		} else if drag_index >= 0 && drag_index < len(library_client.detail.rows) {
			index := drag_index
			track_selected = app_queue_detail(app, index)
			if track_selected {
				state_note_recent(&app_state, detail_card_uri(library_client.detail))
				order_dirty = true
				state_dirty = true
			}
		}
		drag_candidate = false
		dragging = false
		drag_index = -1
	}
	if resizing {
		if .LEFT not_in buttons {
			resizing = false
			state_dirty = true
		} else {
			sidebar_width = clamp(mouse.x / density, SIDEBAR_MIN, SIDEBAR_MAX)
		}
		redraw = true
	}
	if scrollbar_drag.container != "" {
		if .LEFT not_in buttons {
			scrollbar_drag = {}
		} else if drag_scrollbar(&scrollbar_drag, mouse.y, density) {
			smooth_cancel(
				scrollbar_drag.container,
				smooth_for(scrollbar_drag.container, &grid_smooth, &detail_smooth, &queue_smooth),
			)
			redraw = true
		}
	}
	if clicked && hit("volume_slider", mouse_click) {volume_dragging = true}
	if volume_dragging {
		box := clay.GetElementData(clay.ID("volume_slider")).boundingBox
		if box.width > 0 {
			volume = clamp((mouse.x - box.x) / box.width, 0, 1)
			app_state.volume = volume
			if stream != nil {_ = sdl.SetAudioStreamGain(stream, volume)}
			if remote_control {
				_ = library.send_player_command(&library_client, .Volume, int(volume * 100))
			}
		}
		if .LEFT not_in buttons {
			volume_dragging = false
			// Save once when the drag ends; the live value already feeds audio.
			state_dirty = true
		}
		first_frame = true
	}
	if clicked &&
	   (hit("footer_shuffle", mouse_click) ||
			   detail_play_enabled(&library_client) && hit("hero_shuffle", mouse_click)) {
		shuffle = !shuffle
		play_index = reorder_play_queue(play_queue[:], play_index, shuffle)
		if remote_control {
			_ = library.send_player_command(&library_client, .Shuffle, shuffle ? 1 : 0)
		}
	}
	if clicked && hit("footer_repeat", mouse_click) {
		repeat = !repeat
		replay_pending = repeat && stage == .Ended
		if remote_control {
			_ = library.send_player_command(
				&library_client,
				.Repeat,
				0,
				repeat ? "context" : "off",
			)
		}
	}
	if clicked && hit("footer_devices", mouse_click) {
		device_open = !device_open
		if device_open {_ = library.refresh_devices(&library_client)}
	}
	if device_open && clicked {
		for device, index in library_client.devices {
			if device.restricted ||
			   !hit_clipped("device_item", "device_picker", mouse_click, u32(index)) {continue}
			if !library.transfer_to_device(&library_client, device.id, stage == .Playing) {break}
			transfer_here = device.id == app_state.connect_device
			device_open = false
			break
		}
		if device_open {
			panel := clay.GetElementData(clay.ID("device_panel")).boundingBox
			if panel.width > 0 &&
			   !hit("footer_devices", mouse_click) &&
			   !point_in_box(mouse_click, panel) {device_open = false}
		}
	}
	track_delta := 0
	requested_ms := 0
	seek_requested := false
	for {
		command, value, received := mpris.poll()
		if !received {break}
		switch command {
		case .Play:
			if remote_control && worker == nil {
				if !library_client.remote_playing {
					_ = library.send_player_command(&library_client, .Play)
				}
			} else if stage != .Playing {space_pressed = true}
		case .Pause:
			if remote_control && worker == nil {
				if library_client.remote_playing {
					_ = library.send_player_command(&library_client, .Pause)
				}
			} else if stage == .Playing {space_pressed = true}
		case .Play_Pause:
			space_pressed = true
		case .Stop:
			stop_pressed = true
		case .Next:
			track_delta += 1
		case .Previous:
			track_delta -= 1
		case .Seek:
			requested_ms, seek_requested = displayed_ms + value, true
		case .Set_Position:
			requested_ms, seek_requested = value, true
		case .Quit:
			running = false
		}
	}
	if remote_control && stop_pressed {
		_ = library.send_player_command(&library_client, .Pause)
		stop_pressed = false
	}
	for {
		event, received := connect.take_event(&connect_client)
		if !received {break}
		accepted := true
		switch event.action {
		case .Load:
			remote_control = false
			free_play_queue(&play_queue)
			for uri, index in event.tracks {
				append(&play_queue, Play_Item{uri = strings.clone(uri), order = index})
			}
			replace_string(&queue_detail, "")
			queue_rows = len(play_queue)
			play_index = 0
			track_selected = select_play_item(play_queue[:], play_index, &selected, &player_cover)
			incoming_load = track_selected
			seek_ms, start_paused = event.position, event.paused
			shuffle, repeat, connect_repeat_context =
				event.shuffle, event.repeat_track, event.repeat_context
			accepted = track_selected
		case .Resume:
			if incoming_load {start_paused = false} else if remote_control || stage == .Idle && len(play_queue) == 0 {accepted = false} else if stage != .Playing {space_pressed = true}
		case .Pause:
			if incoming_load {start_paused = true} else if remote_control {accepted = false} else if stage == .Playing && stream != nil {
				accepted = sdl.PauseAudioStreamDevice(stream)
				if accepted {stage = .Paused}
			} else if stage == .Buffering || stage == .Signing_In {start_paused = true}
		case .Seek:
			accepted = !remote_control && duration_ms > 0
			if accepted {requested_ms, seek_requested = event.position, true}
		case .Next, .Previous:
			accepted =
				!remote_control &&
				(event.action == .Next ? play_index >= 0 && play_index < len(play_queue) : play_index > 0 || displayed_ms >= PREVIOUS_RESTART_MS)
			if accepted {track_delta = event.action == .Next ? 1 : -1}
		case .Volume:
			volume = event.volume
			app_state.volume = volume
			state_dirty = true
			if stream != nil {_ = sdl.SetAudioStreamGain(stream, volume)}
		case .Options:
			if event.set_shuffle {
				shuffle = event.shuffle
				play_index = reorder_play_queue(play_queue[:], play_index, shuffle)
			}
			if event.set_repeat_track {repeat = event.repeat_track}
			if event.set_repeat_context {connect_repeat_context = event.repeat_context}
		case .Inactive:
			if worker != nil && stage != .Stopping {
				cancel_worker(queue, &cancel)
				clear_audio_stream(&stream)
				stage = .Stopping
			}
			play_after_stop, replay_pending = false, false
			remote_control = false
		}
		connect.acknowledge(&connect_client, event, accepted)
		connect.free_event(event)
	}
	if clicked && hit("footer_previous", mouse_click) {track_delta = -1}
	if clicked && hit("footer_next", mouse_click) {track_delta = 1}
	if remote_control && track_delta != 0 {
		_ = library.send_player_command(&library_client, track_delta > 0 ? .Next : .Previous)
		track_delta = 0
	}
	// All local previous commands share the seek path and preserve pause state.
	if track_delta < 0 && displayed_ms >= PREVIOUS_RESTART_MS {
		track_delta += 1
		requested_ms, seek_requested = 0, true
		displayed_ms = 0 // a second press can now select the previous track
	}
	if seek_requested {
		seek_ms = clamp(requested_ms, 0, max(0, duration_ms))
		start_paused = stage == .Paused
		mpris.seeked(seek_ms)
		if remote_control {
			_ = library.send_player_command(&library_client, .Seek, seek_ms)
			seek_requested = false
		}
	}
	if clicked && seek_enabled && hit("seek_slider", mouse_click) {seek_dragging = true}
	if seek_dragging {
		if !seek_enabled {seek_dragging = false} else {
			if .LEFT not_in buttons {
				box := clay.GetElementData(clay.ID("seek_slider")).boundingBox
				seek_ms = seek_position_ms(mouse.x, box.x, box.width, duration_ms)
				start_paused = stage == .Paused
				if remote_control {
					_ = library.send_player_command(&library_client, .Seek, seek_ms)
				} else {
					seek_requested = true
				}
				seek_dragging = false
			}
			first_frame = true
		}
	}
	hero_start := clicked && hit("hero_play", mouse_click) && detail_play_enabled(&library_client)
	if release_play_uri != "" {
		if track_selected ||
		   stop_pressed ||
		   !detail_matches_uri(library_client.detail, release_play_uri) ||
		   library_client.detail_error != 0 {
			replace_string(&release_play_uri, "")
		} else if detail_rows_ready(&library_client) {
			hero_start = true
			replace_string(&release_play_uri, "")
		}
	}
	restart_playback = track_selected || hero_start
	if remote_control && (track_selected || hero_start) {
		// An explicit local pick takes the room back; quiet the remote first.
		_ = library.send_player_command(&library_client, .Pause)
		remote_control = false
	}
	if hero_start {
		_ = app_queue_detail(app, 0)
		state_note_recent(&app_state, detail_card_uri(library_client.detail))
		order_dirty = true
		state_dirty = true
	}
	if clicked && hit("footer_title", mouse_click) {
		if !link_album {
			// Lengths only: URIs never reach the log.
			diagnostic.writef("footer title dead queue=%v items=%d", queue_at, len(play_queue))
		} else {
			preview := library.Entry {
				name  = foot_album,
				uri   = foot_album_uri,
				image = player_cover,
			}
			_ = open_entry_page(&nav_ctx, preview)
		}
	}
	if clicked && hit("footer_artist", mouse_click) {
		if !link_artist {
			diagnostic.writef("footer artist dead queue=%v items=%d", queue_at, len(play_queue))
		} else {
			preview := library.Entry {
				name = foot_first,
				uri  = foot_first_uri,
			}
			_ = open_entry_page(&nav_ctx, preview)
		}
	}
	if track_delta > 0 && play_index >= 0 && play_index + track_delta >= len(play_queue) {
		app_finish_queue(app)
		restart_playback, seek_requested = false, false
		space_pressed = false
	} else if track_delta != 0 &&
	   advance_play_item(play_queue[:], &play_index, track_delta, &selected, &player_cover) {
		restart_playback = true
	}
	if restart_playback {
		if track_selected || hero_start {queue_restore_pending = false}
		if !incoming_load {seek_ms = 0; start_paused = false}
		seek_dragging = false
	}
	if restart_playback || seek_requested {
		replay_pending = false
		if worker != nil {
			cancel_worker(queue, &cancel)
			clear_audio_stream(&stream)
			stage = .Stopping
			play_after_stop = true
		} else {
			space_pressed = true
		}
	}
	play_pressed := space_pressed || clicked && hit("footer_play", mouse_click)
	if remote_control && play_pressed {
		// The room plays elsewhere; the button resumes or pauses it.
		// Local worker starts always go through the switch below.
		_ = library.send_player_command(
			&library_client,
			library_client.remote_playing ? .Pause : .Play,
		)
		space_pressed = false
		play_pressed = false
	}
	if play_pressed {
		#partial switch stage {
		case .Idle, .Ended, .Failed:
			if worker == nil || thread.is_done(worker) {
				if worker != nil {release_worker(worker, queue, &cancel); worker = nil}
				alloc_error: runtime.Allocator_Error
				queue, alloc_error = chan.create_buffered(
					chan.Chan(player.Packet),
					4,
					context.allocator,
				)
				if alloc_error != nil {
					play_after_stop, replay_pending = false, false
					stage = .Failed
				} else {
					sync.atomic_store(&cancel, false)
					work = Login_Work {
						queue     = queue,
						cancel    = &cancel,
						track_url = strings.clone(selected),
						start_ms  = seek_ms,
						source    = &play_source,
					}
					if preload_worker == nil &&
					   preload_work.track == selected &&
					   preload_work.source.url != "" {
						work.preloaded = preload_work.source
						preload_work.source = {}
					} else if preload_worker != nil {
						sync.atomic_store(&preload_work.cancel, true)
					}
					diagnostic.write("playback worker starting")
					worker = thread.create_and_start_with_data(&work, login_and_decode)
					if worker == nil {
						delete(work.track_url)
						session.close_source(&work.preloaded)
						chan.destroy(queue)
						play_after_stop, replay_pending = false, false
						stage = .Failed
					} else {
						clear_audio_stream(&stream)
						finished = false
						play_after_stop, replay_pending = false, false
						sent_frames, sample_rate = 0, 0
						displayed_ms = seek_ms
						seek_ms = 0
						stage = .Signing_In
					}
				}
			}
		case .Playing:
			if stream != nil && sdl.PauseAudioStreamDevice(stream) {stage = .Paused}
		case .Paused:
			if stream != nil && sdl.ResumeAudioStreamDevice(stream) {stage = .Playing}
		}
	}
	if mpris_active {
		mpris.update(
			{
				title = title,
				artist = artist,
				duration_ms = duration_ms,
				position_ms = displayed_ms,
				playing = stage == .Playing,
				shuffle = shuffle,
				repeat = repeat,
				volume = volume,
				can_seek = seek_enabled,
				can_next = play_index >= 0 && play_index < len(play_queue),
				can_previous = play_index > 0 ||
				!remote_control && displayed_ms >= PREVIOUS_RESTART_MS,
			},
		)
	}
}

// End-of-frame bookkeeping: redraw bump, last-played persist, footer link
// carry-over, state save and the click feedback frame.
app_persist :: proc(app: ^App, frame: ^Frame) {
	using app
	using frame
	resume := time.time_to_unix_nano(http.web_api_resume_at())
	if resume > app_state.web_api_resume_ns {
		app_state.web_api_resume_ns = resume
		state_dirty = true
	}
	if order_dirty {pending_redraw = true}
	// Persist the last played track. Title and artist change together on
	// the Ready packet, so watch every field, not only the URI.
	// The state holds the saved copy; no shadow variables.
	detail_ready := library_client.detail.ready
	collection_changed :=
		detail_ready && !detail_matches_uri(library_client.detail, app_state.last_collection)
	played_state := &app_state.last_played
	if selected != played_state.track ||
	   title != played_state.title ||
	   artist != played_state.artist ||
	   player_cover != played_state.cover ||
	   (detail_ready &&
			   (collection_changed || app_state.last_saved != library_client.detail.liked)) {
		replace_string(&played_state.track, selected)
		replace_string(&played_state.title, title)
		replace_string(&played_state.artist, artist)
		replace_string(&played_state.cover, player_cover)
		if detail_ready {
			collection := detail_card_uri(library_client.detail)
			replace_string(&app_state.last_collection, collection)
			replace_string(&app_state.last_name, library_client.detail.name)
			app_state.last_saved = library_client.detail.liked
		}
		state_dirty = true
	}
	// Links persist only from a live queue item, never blanked by its
	// absence: the resumed footer keeps linking until a new track lands.
	if queue_at {
		item := play_queue[play_index]
		item_first, item_first_uri := "", ""
		if len(item.artist_links) > 0 {
			item_first, item_first_uri = item.artist_links[0].name, item.artist_links[0].uri
		}
		if item.album != played_state.album ||
		   item.album_uri != played_state.album_uri ||
		   item_first != played_state.first_artist ||
		   item_first_uri != played_state.artist_uri {
			replace_string(&played_state.album, item.album)
			replace_string(&played_state.album_uri, item.album_uri)
			replace_string(&played_state.first_artist, item_first)
			replace_string(&played_state.artist_uri, item_first_uri)
			state_dirty = true
		}
	}
	if restart_playback ||
	   played_state.queue_index != play_index ||
	   played_state.shuffle != shuffle ||
	   played_state.collection != queue_detail {
		played_state.queue_index = play_index
		played_state.shuffle = shuffle
		replace_string(&played_state.collection, queue_detail)
		state_dirty = true
	}
	if state_dirty {
		state_dirty = false
		// Borrow the live queue for this synchronous save; playback remains its owner.
		view := app_state
		view.last_played.queue = play_queue
		save_state(&view)
	}
	if clicked {first_frame = true}
}

// Display page selection, drag target, on-demand paging and cover uploads
// for what layout made visible.
app_covers :: proc(app: ^App, frame: ^Frame, visible: Frame_Visible) {
	using app
	using frame
	display_page = &library_client.pages[filter]
	display_kind = filter
	if search_mode {
		display_page = &library_client.search_pages[search_kind]
		display_kind = search_kind
	}
	drop_target = -1
	if dragging && display_kind == .Playlists {
		drop_target = grid_card_at(display_page, visible.cards, mouse)
	}
	// Pages stream in as the grid nears the bottom; sorting applies to what
	// is loaded, exactly like the reference client. Walking the whole
	// collection would burn the dev-mode quota bucket on every launch.
	if !search_mode {load_more_near_bottom(&library_client, filter, density)}
	queue_needs_more :=
		worker != nil &&
		play_index >= 0 &&
		queue_detail != "" &&
		detail_matches_uri(library_client.detail, queue_detail) &&
		library_client.detail.source != .Artist &&
		play_index + DETAIL_LOOKAHEAD >= len(play_queue)
	for group in library.Album_Group {
		if detail_needs_more(&library_client, visible, group) ||
		   group == .Album && queue_needs_more {
			if library.more_rows(&library_client, group) {redraw = true; break}
		}
	}
	ensure_covers(&library_client, &textures, display_page, player_cover, visible)
}
