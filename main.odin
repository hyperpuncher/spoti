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
import artwork "spotify/artwork"
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
	if WAKE_EVENT != 0 {wake_app(nil)}
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

// The caller checks the containing row or clip before looking for a link.
artist_link_at :: proc(
	links: []library.Artist_Link,
	id: string,
	base: u32,
	point: sdl.FPoint,
) -> ^library.Artist_Link {
	for index in 0 ..< min(len(links), 64) {
		if links[index].uri != "" && hit_index(id, point, base + u32(index)) {return &links[index]}
	}
	return nil
}

// Follows the desktop theme through SDL; unknown means dark, and
// SPOTI_THEME forces light or dark for testing and user control.
system_dark :: proc() -> bool {
	value := os.get_env("SPOTI_THEME", context.temp_allocator)
	if value == "light" {return false}
	if value == "dark" {return true}
	return sdl.GetSystemTheme() != .LIGHT
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
	ui.editor_set_text(&app.editor, "")
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

// Ask the decoder to stop and drop queued audio. The worker reports
// .Stopping finished through the packet queue.
app_stop_audio :: proc(app: ^App) {
	cancel_worker(app.queue, &app.cancel)
	clear_audio_stream(&app.stream)
	app.stage = .Stopping
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
	source, id = library.split_uri(uri) or_return
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
	next_track:             Next_Track, // shared with the decode worker
	tracks_started:         int, // Ready packets from the current worker
	// A gapless next track whose audio is queued behind the current one.
	// The footer switches when playback reaches boundary_frames.
	upcoming:               struct {
		active:          bool,
		name:            string, // owned
		uri:             string, // owned
		duration_ms:     int,
		boundary_frames: int, // sent_frames where the next track starts
		base_frames:     int, // position_frames of its first packet
		pending:         bool, // Ready arrived; its first Audio packet has not
	},
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
	input_changed:          bool, // clicks run after app_search; consume next frame
	textures:               Textures,
	theme_dark:             bool,
	mpris_active:           bool,
	library_client:         library.Client,
	connect_client:         connect.Client,
	connect_snapshot:       connect.Snapshot,
	connect_published_at:   u64,
	connect_settle_key:     u64, // candidate state waiting to settle
	connect_settle_at:      u64, // tick to send it, or 0
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
	smooth:                 [Scroll_Area]Smooth,
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
	fx_next_frame:          u64, // tick of the next stepped animation frame, or 0
	shuffle:                bool,
	volume:                 f32,
	volume_dragging:        bool,
	seek_dragging:          bool,
	start_paused:           bool,
	seek_ms:                int,
	sent_frames:            int, // stream position after the last queued packet
	origin_frames:          int, // stream position where the shown track's frame 0 lies
	sample_rate:            int,
	duration_ms:            int,
	displayed_ms:           int,
	last:                   u64,
	playback_tick:          u64, // last 30 fps playback wake, even while hidden
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
	track_selected:   bool,
	restart_playback: bool,
	redraw:           bool,
	mouse:            sdl.FPoint,
	buttons:          sdl.MouseButtonFlags,
	density:          f32,
	seek_enabled:     bool,
	link_album:       bool,
	queue_at:         bool,
	foot_album:       string,
	foot_album_uri:   string,
	foot_artists:     []library.Artist_Link,
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
	ui.editor_init(&editor)
	selected = strings.clone(session.TRACK_URL)
	play_index = -1
	textures = Textures {
		by_key    = make(map[u64]^sdl.Texture),
		requested = make(map[u64]Cover_Request_State),
	}
	theme_dark = system_dark()
	apply_theme(theme_dark)
	when ODIN_OS == .Windows {ui.windows_frame_theme(state.window, theme_dark)}
	load_app_icon(&state)
	retint_icons(&textures, theme_dark)
	load_icons(&state, &textures)
	load_fades(&state, &textures)
	WAKE_EVENT = sdl.RegisterEvents(1)
	mpris_active = mpris.start(WAKE_EVENT != 0 ? wake_app : nil)
	if WAKE_EVENT != 0 {library_client.wake = wake_app}
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
		clear_next_track(&next_track)
		clear_upcoming(&app)
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
		ui.editor_destroy(&editor)
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
			if now - remote_polled_at >= REMOTE_POLL_NS {
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
		// A hidden window still feeds audio from the stages above, but its
		// progress bar needs no frames. SDL sends EXPOSED when it returns.
		if !redraw && (stage != .Playing || !window_visible(&state)) {continue}

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
				&editor,
				&detail_pinned,
			)
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
	if library.poll(&library_client, app_library_result, app) {redraw = true}
	library.advance_releases(&library_client)
	if sync.atomic_exchange(&connect_client.pending, false) {redraw = true}
	// Stop local audio before entering remote control. This must happen
	// before app_playback, not in layout, where the frame flag is lost.
	if last_transfer_pending && !library_client.transfer_pending {
		if library_client.transfer_ok && !transfer_here {
			show_toast(app, "Playback transferred")
			if preload_worker != nil {sync.atomic_store(&preload_work.cancel, true)}
			play_after_stop, replay_pending = false, false
			seek_dragging, start_paused = false, false
			seek_ms = 0
			if worker != nil && stage != .Stopping {
				app_stop_audio(app)
			}
			remote_control = true
			remote_polled_at = 0
			_ = library.refresh_devices(&library_client)
		} else {
			show_toast(
				app,
				library_client.transfer_ok ? "Playback transferred" : "Couldn't transfer playback",
			)
		}
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
		if cover.image != nil {
			texture := ui.create_texture(&state, cover.image)
			if texture != nil {
				textures.by_key[cover.key] = texture
				request.bytes = int(cover.image.w) * int(cover.image.h) * 4
				request.used = textures.cover_frame + 1
				textures.requested[cover.key] = request
				textures.cover_bytes += request.bytes
			}
			artwork.free_image(&cover.image)
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
		app_stop_audio(app)
	}
	if stage == .Stopping && thread.is_done(worker) {
		redraw = true
		release_worker(worker, queue, &cancel)
		worker = nil
		finished = false
		sent_frames, origin_frames, sample_rate = 0, 0, 0
		clear_upcoming(app)
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
				tracks_started += 1
				if stream != nil && sent_frames > 0 {
					// The worker continued into the offered track. Its audio
					// follows the current track in the same stream.
					diagnostic.write("playback continues gaplessly")
					clear_upcoming(app)
					upcoming = {
						active          = true,
						pending         = true,
						name            = packet.name,
						uri             = packet.uri,
						duration_ms     = packet.duration_ms,
						boundary_frames = sent_frames,
					}
					break
				}
				delete(packet.uri)
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
						_ = sdl.SetAudioStreamGain(stream, volume_gain(volume))
						if !start_paused {_ = sdl.ResumeAudioStreamDevice(stream)}
					}
					sent_frames = packet.position_frames
					sample_rate = packet.sample_rate
				}
				if upcoming.pending {
					upcoming.pending = false
					upcoming.base_frames = packet.position_frames
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
				app_stop_audio(app)
				state_dirty = true
				show_toast(app, "Unavailable track removed")
			case .Failed:
				diagnostic.write("playback worker failed")
				fmt.eprintln("sign-in, CDN stream, or Vorbis decoding failed")
				stage = .Failed
			}
		}
	}
	app_offer_next_track(app)
	app_gapless_boundary(app)
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
	// Resolve the track that plays next while this one plays. Repeat-one
	// replays the cached source and needs no preload.
	if next := next_play_index(app); stage == .Playing && next >= 0 && next != play_index {
		next_uri := play_queue[next].uri
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
	for &glide, area in smooth {
		if smooth_step(SCROLL_AREA_ID[area], &glide, smooth_dt) {redraw = true}
	}
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
	if density != previous_density {
		clay.ResetMeasureTextCache()
		load_icons(&state, &textures)
	}
	progress := f32(0)
	if duration_ms > 0 {
		// Kept times hold the bar steady across worker swaps; live audio
		// refines it below.
		progress = f32(displayed_ms) / f32(duration_ms)
		if sample_rate > 0 && stream != nil {
			queued := max(0, sdl.GetAudioStreamQueued(stream))
			measured_ms := (sent_frames - int(queued) / 4 - origin_frames) * 1000 / sample_rate
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
		shown_status = fmt.tprintf("Controlling %s", library_client.remote_device)
	}
	shown_input := input
	if library_client.state != .Missing_Client_ID {
		if len(shown_input) == 0 {
			shown_input = input_active ? "" : "Search Spotify or paste a track link"
		}
	}
	times: [2][16]u8
	retain_player_cover(&displayed_cover, player_cover, &textures)
	// The footer links the playing album and each known artist.
	// The live queue is the truth, even when it links nothing; the
	// persisted record only serves the queue-less resumed footer.
	queue_at = play_index >= 0 && play_index < len(play_queue)
	foot_album, foot_album_uri = "", ""
	foot_artists = nil
	if queue_at {
		item := play_queue[play_index]
		foot_album, foot_album_uri = item.album, item.album_uri
		foot_artists = item.artist_links
	} else {
		foot_album, foot_album_uri = app_state.last_played.album, app_state.last_played.album_uri
		if played := &app_state.last_played;
		   played.artist_uri != "" && artist == played.first_artist {
			foot_artists = make([]library.Artist_Link, 1, context.temp_allocator)
			foot_artists[0] = {
				name = played.first_artist,
				uri  = played.artist_uri,
			}
		}
	}
	link_album = len(foot_album_uri) > 0
	if shown_status != artist || artist == "" {foot_artists = nil}
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
		show_toast(app, fmt.tprintf("%s %s", verb, library_client.write_name))
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
		seek_enabled   = seek_enabled,
		artist_links   = foot_artists,
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
	for &glide, area in smooth {
		if !scroll_wheel(SCROLL_AREA_ID[area], wheel.y, density, &glide) {continue}
		if area == .Detail {detail_scroll_armed = false}
		break
	}
	t0 := sdl.GetTicksNS()
	now := sdl.GetTicksNS()
	dt := f32(now - last) / 1e9
	last = now
	clay.UpdateScrollContainers(false, {}, dt)
	_, card_title_height := ui.text_size(&state, "", 14 * density)
	_, card_subtitle_height := ui.text_size(&state, "", 12 * density)
	card_text_height := card_title_height + card_subtitle_height
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
		smooth[.Detail].target = 0
		smooth[.Detail].active = false
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
		smooth[.Detail].target = pos
		smooth[.Detail].active = false
		// Keep the target while a partial page is still too short to reach it.
		if pos == detail_scroll_target || loaded {detail_scroll_armed = false}
		if pos == previous {break}
	}
	fx_animating = fx.animating
	fx_next_frame = fx.next_frame
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
		smooth_cancel_id(&smooth, autoscroll_container)
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
	// Widgets request their cursor during layout; drags keep theirs.
	ui.set_cursor(&state, resizing ? .Resize : layout_cursor)
	// A hidden window keeps layout, input and transport state current but
	// draws nothing: present blocks for frame callbacks the compositor
	// withholds. SDL sends EXPOSED when the window returns.
	if window_visible(&state) {
		render(&commands, &state, &textures)
		ui.frame_done(&state)
	}
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
