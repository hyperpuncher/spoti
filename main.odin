package main

import "base:runtime"
import c "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import diagnostic "diagnostic"
import library "spotify/library"
import mpris "spotify/mpris"
import player "spotify/player"
import session "spotify/session"
import track "spotify/track"
import ui "ui"
import clay "vendor/clay"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// The MPRIS worker pushes this event to wake the otherwise idle frame loop.
WAKE_EVENT: u32

@(private = "file")
wake_mpris :: proc "c" (_: rawptr) {
	event := sdl.Event {
		type = sdl.EventType(WAKE_EVENT),
	}
	_ = sdl.PushEvent(&event)
}

hit_index :: proc(id: string, point: sdl.FPoint, index: u32) -> bool {
	data := clay.GetElementData(clay.ID(id, index))
	box := data.boundingBox
	return(
		data.found &&
		point.x >= box.x &&
		point.x < box.x + box.width &&
		point.y >= box.y &&
		point.y < box.y + box.height \
	)
}

hit :: proc(id: string, point: sdl.FPoint) -> bool {
	return hit_index(id, point, 0)
}

// Overscan items can have rectangles outside their scroll viewport. Drawing
// is clipped by Clay, but explicit rectangle hit tests must check the clip too.
hit_clipped :: proc(id, clip: string, point: sdl.FPoint, index: u32 = 0) -> bool {
	return hit(clip, point) && hit_index(id, point, index)
}

pointer_over :: proc(id: string, index: u32 = 0) -> bool {
	return clay.PointerOver(clay.ID(id, index))
}

update_cursor :: proc(
	state: ^ui.State,
	client: ^library.Client,
	resizing: bool,
	visible: Frame_Visible,
	seek_enabled: bool,
) {
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
	for id in ([]string{"toolbar_back", "toolbar_library", "detail_more", "hero_play", "footer_play", "footer_previous", "footer_next", "footer_repeat", "footer_shuffle", "hero_shuffle", "volume_slider", "spotify_link"}) {
		if (id == "hero_play" || id == "hero_shuffle") && !detail_play_enabled(client) {continue}
		if id == "spotify_link" && client.detail_loading {continue}
		if pointer_over(id) {
			ui.set_cursor(state, .Pointer)
			return
		}
	}
	for _, index in LIBRARY_TABS {
		if pointer_over("chip", u32(index)) {
			ui.set_cursor(state, .Pointer)
			return
		}
	}
	for index in visible.cards.first ..< visible.cards.last {
		if pointer_over("card", u32(index)) {
			ui.set_cursor(state, .Pointer)
			return
		}
	}
	if client.detail.ready {
		for index in visible.tracks.first ..< visible.tracks.last {
			if pointer_over("track_row", u32(index)) {
				ui.set_cursor(state, .Pointer)
				return
			}
		}
		for index in visible.releases.first ..< visible.releases.last {
			if pointer_over("release_card", u32(index)) {
				ui.set_cursor(state, .Pointer)
				return
			}
		}
	}
	ui.set_cursor(state, .Default)
}

open_spotify_detail :: proc(detail: ^library.Detail) {
	kind := "playlist"
	switch detail.source {
	case .Album:
		kind = "album"
	case .Artist:
		kind = "artist"
	case .Liked:
		return
	case .Playlist:
	}
	address := fmt.aprintf("https://open.spotify.com/%s/%s", kind, detail.id)
	defer delete(address)
	c_address := strings.clone_to_cstring(address)
	defer delete(c_address)
	_ = sdl.OpenURL(c_address)
}

ascii_track_input :: proc(value: string) -> bool {
	for ch in transmute([]u8)value {
		if ch < ' ' || ch > '~' {return false}
	}
	return true
}

// Route the wheel to the hovered scroll container and clamp its offset.
scroll_wheel :: proc(id: string, amount, d: f32) -> bool {
	if amount == 0 || !pointer_over(id) {return false}
	scroll := clay.GetScrollContainerData(clay.ID(id))
	if !scroll.found || scroll.scrollPosition == nil {return false}
	minimum := min(
		f32(0),
		scroll.scrollContainerDimensions.height - scroll.contentDimensions.height,
	)
	scroll.scrollPosition.y = clamp(scroll.scrollPosition.y + amount * 40 * d, minimum, 0)
	return true
}

load_more_near_bottom :: proc(client: ^library.Client, filter: library.Kind, d: f32) {
	page := &client.pages[filter]
	if !page.has_more || client.pending[filter] {return}
	scroll := clay.GetScrollContainerData(clay.ID("library_grid"))
	if !scroll.found || scroll.scrollPosition == nil {return}
	remaining :=
		scroll.contentDimensions.height -
		scroll.scrollContainerDimensions.height +
		scroll.scrollPosition.y
	if remaining <= 480 * d {library.more(client, filter)}
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
	filter: library.Kind,
	player_cover: string,
	visible: Frame_Visible,
) {
	budget := 4
	ensure_cover(client, textures, player_cover, &budget)
	for entry in client.pages[filter].items[visible.cards.first:visible.cards.last] {
		ensure_cover(client, textures, entry.image, &budget)
	}
	if client.detail.ready {
		ensure_cover(client, textures, client.detail.image, &budget)
		ensure_cover(client, textures, client.detail.image_preview, &budget)
		ensure_cover(client, textures, client.detail.image_small, &budget)
		for row in client.detail.rows[visible.tracks.first:visible.tracks.last] {
			ensure_cover(client, textures, row.image, &budget)
			ensure_cover(client, textures, row.image_small, &budget)
		}
		for release in client.detail.releases[visible.releases.first:visible.releases.last] {
			ensure_cover(client, textures, release.image, &budget)
		}
	}
}

clear_audio_stream :: proc(stream: ^^sdl.AudioStream) {
	if stream^ != nil {sdl.DestroyAudioStream(stream^); stream^ = nil}
}

main :: proc() {
	diagnostic.init()
	diagnostic.write("application starting")
	defer {
		diagnostic.write("clean shutdown")
		diagnostic.close()
	}
	state, ok := ui.open("spoti", 1280, 820)
	if !ok {return}
	defer ui.close(&state)
	if !sdl.InitSubSystem(
		sdl.INIT_AUDIO,
	) {fmt.eprintln("could not initialize SDL3 audio:", sdl.GetError()); return}

	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	width, height := ui.size(&state)
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), &memory[0]),
		{f32(width), f32(height)},
		{handler = clay_error},
	)
	clay.SetMeasureTextFunction(measure_text, &state)

	queue: chan.Chan(player.Packet)
	worker: ^thread.Thread
	work: Login_Work
	play_source: Play_Source
	preload_worker: ^thread.Thread
	preload_work: Preload_Work
	preload_attempted: string
	cancel, closed := false, false
	stream: ^sdl.AudioStream
	title: string
	selected := strings.clone(session.TRACK_URL)
	player_cover, displayed_cover: string
	play_queue: [dynamic]Play_Item
	play_index := -1
	input: string
	input_active := false
	textures := Textures {
		by_key    = make(map[u64]^sdl.Texture),
		requested = make(map[u64]Cover_Request_State),
	}
	load_icons(&state, &textures)
	WAKE_EVENT = sdl.RegisterEvents(1)
	mpris_active := mpris.start(WAKE_EVENT != 0 ? wake_mpris : nil)
	library_client: library.Client
	settings := load_settings()
	filter := settings.tab
	sidebar_width := settings.sidebar_width
	settings_dirty := false
	order_dirty := false
	detail_pinned := false
	page_counts: [library.Kind]int
	menu: Context_Menu
	resizing := false
	scrollbar_drag: Scrollbar_Drag
	defer {
		if worker != nil {release_worker(worker, queue, &cancel, closed)}
		if preload_worker != nil {
			sync.atomic_store(&preload_work.cancel, true)
			thread.join(preload_worker)
			thread.destroy(preload_worker)
		}
		clear_preload(&preload_work)
		delete(preload_attempted)
		clear_play_source(&play_source)
		clear_audio_stream(&stream)
		library.stop(&library_client)
		session.clear_authorization()
		for _, texture in textures.by_key {sdl.DestroyTexture(texture)}
		delete(textures.by_key)
		delete(textures.requested)
		delete(title)
		delete(selected)
		delete(player_cover)
		delete(displayed_cover)
		free_play_queue(&play_queue)
		delete(input)
		free_settings(&settings)
		free_context_menu(&menu)
		if mpris_active {mpris.close()}
	}
	stage := Stage.Idle
	finished := false
	repeat, replay_pending, play_after_stop := false, false, false
	shuffle, volume_dragging := false, false
	volume: f32 = 0.5
	seek_dragging, start_paused := false, false
	seek_ms := 0
	sent_frames, sample_rate, duration_ms := 0, 0, 0
	displayed_ms := 0
	last := sdl.GetTicksNS()
	first_frame := true
	for running := true; running; {
		defer free_all(context.temp_allocator)
		wheel := sdl.FPoint{}
		mouse_click := sdl.FPoint{}
		mouse_right := sdl.FPoint{}
		clicked, right_clicked, space_pressed, stop_pressed := false, false, false, false
		event: sdl.Event
		wait_ms: i32 = -1 // no redraw while idle; SDL events wake the window
		// Playback renders at the display rate so the progress bar stays smooth,
		// while the idle window sleeps until an event arrives.
		if stage == .Playing {wait_ms = 0}
		if stage == .Signing_In ||
		   stage == .Buffering ||
		   stage == .Stopping ||
		   (stage == .Ended && replay_pending) ||
		   (stage == .Failed && worker != nil) {wait_ms = 40}
		if library_client.state == .Authorizing ||
		   library_client.state == .Loading ||
		   library_client.detail_loading ||
		   library_client.covers_pending > 0 {wait_ms = 40}
		for pending in library_client.pending {
			if pending {wait_ms = 40; break}
		}
		if preload_worker != nil && stage != .Playing {wait_ms = 40}
		if first_frame {wait_ms = 0}
		// If the wake event could not be registered, poll the bus instead.
		if mpris_active && WAKE_EVENT == 0 && wait_ms < 0 {wait_ms = 100}
		has_event := sdl.WaitEventTimeout(&event, wait_ms)
		redraw := has_event || first_frame
		first_frame = false
		if has_event {
			for {
				#partial switch event.type {
				case .QUIT, .WINDOW_CLOSE_REQUESTED:
					running = false
				case .MOUSE_BUTTON_UP:
					if event.button.button == sdl.BUTTON_LEFT {
						if resizing {settings_dirty = true}
						resizing = false
					}
				case .KEY_DOWN:
					if input_active {
						#partial switch event.key.scancode {
						case .ESCAPE:
							input_active = false
							_ = sdl.StopTextInput(state.window)
						case .BACKSPACE:
							if len(input) > 0 {
								shorter := strings.clone(input[:len(input) - 1])
								delete(input)
								input = shorter
							}
						case .V:
							if .LCTRL in event.key.mod || .RCTRL in event.key.mod {
								clipboard := sdl.GetClipboardText()
								if clipboard != nil {
									value := strings.trim_space(string(cstring(clipboard)))
									if len(value) <= 256 && ascii_track_input(value) {
										delete(input)
										input = strings.clone(value)
									}
									sdl.free(rawptr(clipboard))
								}
							}
						case .RETURN, .KP_ENTER:
							_, valid := track.parse_id(input)
							if valid {
								delete(selected)
								selected = strings.clone(strings.trim_space(input))
								delete(player_cover)
								player_cover = {}
								delete(displayed_cover)
								displayed_cover = {}
								free_play_queue(&play_queue)
								play_index = -1
								delete(input)
								input = {}
								input_active = false
								_ = sdl.StopTextInput(state.window)
							}
						}
					} else if !event.key.repeat {
						#partial switch event.key.scancode {
						case .ESCAPE:
							running = false
						case .S:
							stop_pressed = true
						case .SPACE:
							space_pressed = true
						}
					}
				case .TEXT_INPUT:
					if input_active &&
					   .LCTRL not_in sdl.GetModState() &&
					   .RCTRL not_in sdl.GetModState() {
						added := string(event.text.text)
						if len(input) + len(added) <= 256 && ascii_track_input(added) {
							updated := fmt.aprintf("%s%s", input, added)
							delete(input)
							input = updated
						}
					}
				case .MOUSE_WHEEL:
					wheel.x += event.wheel.x; wheel.y += event.wheel.y
				case .MOUSE_BUTTON_DOWN:
					if event.button.button == sdl.BUTTON_LEFT {
						mouse_click = ui.mouse_position(&state, event.button.x, event.button.y)
						clicked = true
					} else if event.button.button == sdl.BUTTON_RIGHT {
						mouse_right = ui.mouse_position(&state, event.button.x, event.button.y)
						right_clicked = true
					}
				}
				if !sdl.PollEvent(&event) {break}
			}
		}
		if !running {break}
		if preload_worker != nil && thread.is_done(preload_worker) {
			thread.join(preload_worker)
			thread.destroy(preload_worker)
			preload_worker = nil
		}
		if library_client.worker == nil {
			remember := os.get_env("SPOTI_REMEMBER_LOGIN", context.temp_allocator) == "1"
			_ = library.start(&library_client, remember)
		}
		if library.poll(&library_client) {redraw = true}
		for cover in library.take_cover(&library_client) {
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
				if texture != nil {textures.by_key[cover.key] = texture}
				delete(cover.image.pixels)
			}
		}
		if stop_pressed {
			if preload_worker != nil {sync.atomic_store(&preload_work.cancel, true)}
			seek_dragging, start_paused = false, false
			seek_ms = 0
			play_after_stop, replay_pending = false, false
		}
		if stop_pressed && worker != nil && stage != .Stopping {
			cancel_worker(queue, &cancel, &closed)
			clear_audio_stream(&stream)
			stage = .Stopping
		}
		if stage == .Stopping && thread.is_done(worker) {
			redraw = true
			release_worker(worker, queue, &cancel, closed)
			worker = nil
			finished = false
			sent_frames, sample_rate, duration_ms = 0, 0, 0
			displayed_ms = 0
			stage = .Idle
			if play_after_stop {
				play_after_stop = false
				space_pressed = true
			}
		}
		if stage == .Failed && worker != nil {
			start_paused = false
			cancel_worker(queue, &cancel, &closed)
			if thread.is_done(worker) {
				release_worker(worker, queue, &cancel, closed)
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
				case .Failed:
					diagnostic.write("playback worker failed")
					fmt.eprintln("sign-in, CDN stream, or Vorbis decoding failed")
					stage = .Failed
				}
			}
		}
		if finished &&
		   stage == .Playing &&
		   stream != nil &&
		   sdl.GetAudioStreamQueued(stream) == 0 {
			stage = .Ended
			if !seek_dragging && repeat {
				replay_pending = true
			} else if !seek_dragging &&
			   advance_play_item(play_queue[:], &play_index, 1, &selected, &player_cover) {
				replay_pending = true
			}
			redraw = true
		}
		if replay_pending && stage == .Ended && worker != nil && thread.is_done(worker) {
			replay_pending = false
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
					track    = strings.clone(next_uri),
					remember = work.remember,
				}
				preload_worker = thread.create_and_start_with_data(&preload_work, preload_track)
			}
		}
		if !redraw && stage != .Playing {continue}

		progress := f32(0)
		if sample_rate > 0 && duration_ms > 0 && stream != nil {
			queued := max(0, sdl.GetAudioStreamQueued(stream))
			measured_ms := (sent_frames - int(queued) / 4) * 1000 / sample_rate
			displayed_ms = max(displayed_ms, clamp(measured_ms, 0, duration_ms))
			progress = f32(displayed_ms) / f32(duration_ms)
		}
		shown_ms := displayed_ms
		seek_enabled :=
			duration_ms > 0 && (stage == .Playing || stage == .Paused || stage == .Ended)
		if seek_dragging && seek_enabled {
			box := clay.GetElementData(clay.ID("seek_slider")).boundingBox
			mouse_x: f32
			_ = sdl.GetMouseState(&mouse_x, nil)
			point := ui.mouse_position(&state, mouse_x, 0)
			preview := seek_position_ms(point.x, box.x, box.width, duration_ms)
			progress = f32(preview) / f32(duration_ms)
			shown_ms = preview
		}
		button := "play"
		if stage == .Playing {button = "pause"}
		if stage == .Paused {button = "resume"}
		if stage == .Signing_In || stage == .Buffering || stage == .Stopping {button = "wait"}
		status := "Ready to play"
		switch stage {
		case .Signing_In:
			status = "Loading track..."
		case .Buffering:
			status = "Buffering audio..."
		case .Playing:
			status = "Playing from Spotify"
		case .Paused:
			status = "Paused"
		case .Ended:
			status = "Track ended. Press play to replay."
		case .Failed:
			status = "Could not play. Check the terminal; press play to retry."
		case .Stopping:
			status = "Stopping..."
		case .Idle:
			status = "Ready to play"
		}
		shown_title := title
		if len(shown_title) == 0 {shown_title = "Nothing playing"}
		shown_input := input
		if len(shown_input) ==
		   0 {shown_input = "Paste a Spotify track link, or pick from your library"}
		if input_active {shown_input = fmt.aprintf("%s|", shown_input, allocator = context.temp_allocator)}
		times: [2][16]u8
		retain_player_cover(&displayed_cover, player_cover, &textures)
		view := View {
			title        = shown_title,
			status       = status,
			button       = button,
			progress     = progress,
			elapsed      = duration_text(shown_ms, times[0][:]),
			total        = duration_text(duration_ms, times[1][:]),
			input        = shown_input,
			cover        = displayed_cover,
			repeat       = repeat,
			shuffle      = shuffle,
			volume       = volume,
			input_active = input_active,
			pinned       = detail_pinned,
			menu_open    = menu.open,
			menu_x       = menu.point.x,
			menu_y       = menu.point.y,
			menu_count   = menu.count,
			menu_labels  = menu.labels,
		}
		width, height = ui.size(&state)
		mouse_x, mouse_y: f32
		buttons := sdl.GetMouseState(&mouse_x, &mouse_y)
		mouse := ui.mouse_position(&state, mouse_x, mouse_y)
		now := sdl.GetTicksNS()
		dt := f32(now - last) / 1e9
		last = now
		clay.SetLayoutDimensions({f32(width), f32(height)})
		clay.SetPointerState({mouse.x, mouse.y}, .LEFT in buttons)
		previous_density := ui.scale(&state)
		density := ui.update_scale(&state)
		if density != previous_density {clay.ResetMeasureTextCache()}
		wheel_used := scroll_wheel("library_grid", wheel.y, density)
		if !wheel_used {wheel_used = scroll_wheel("detail_rows", wheel.y, density)}
		clay.UpdateScrollContainers(false, {}, dt)
		card_text_height :=
			f32(ttf.GetFontHeight(ui.font_for_size(&state, 14 * density))) +
			f32(ttf.GetFontHeight(ui.font_for_size(&state, 12 * density)))
		commands, visible := layout(
			view,
			&library_client,
			&settings,
			filter,
			&textures,
			sidebar_width,
			f32(width),
			f32(height),
			card_text_height,
			dt,
			density,
		)
		update_cursor(&state, &library_client, resizing, visible, seek_enabled)
		_ = sdl.SetRenderDrawColor(state.renderer, 18, 18, 18, 255)
		_ = sdl.RenderClear(state.renderer)
		render(&commands, &state, &textures)
		ui.frame_done(&state)
		load_more_near_bottom(&library_client, filter, density)
		ensure_covers(&library_client, &textures, filter, player_cover, visible)
		if right_clicked {
			open_menu_at(&menu, &library_client, filter, visible, mouse_right, &settings)
		}
		track_selected := false
		if clicked && menu.open {
			for index in 0 ..< menu.count {
				if !hit_index("menu_item", mouse_click, u32(index)) {continue}
				switch menu.items[index] {
				case .Pin:
					_ = settings_toggle_pin(&settings, menu.uri)
					if menu.uri == detail_card_uri(library_client.detail) {
						detail_pinned = settings_is_pinned(&settings, menu.uri)
					}
					order_dirty = true
					settings_dirty = true
				case .Open_In_Spotify:
					open_spotify_uri(menu.uri)
				case .Play:
					if menu.track >= 0 && menu.track < len(library_client.detail.rows) {
						build_play_queue(
							&play_queue,
							library_client.detail.rows[:],
							library_client.detail.image_small,
						)
						play_index =
							shuffle ? reorder_play_queue(play_queue[:], menu.track, true) : menu.track
						track_selected = select_play_item(
							play_queue[:],
							play_index,
							&selected,
							&player_cover,
						)
					}
				}
				break
			}
			menu.open = false
		} else if clicked {
			if hit("library_scrollbar", mouse_click) {
				begin_scrollbar_drag(&scrollbar_drag, "library_grid", mouse_click.y)
			} else if hit("detail_scrollbar", mouse_click) {
				begin_scrollbar_drag(&scrollbar_drag, "detail_rows", mouse_click.y)
			} else if hit("sidebar_handle", mouse_click) {
				resizing = true
			} else {
				handled := false
				if hit("toolbar_back", mouse_click) || hit("toolbar_library", mouse_click) {
					library.clear_detail(&library_client)
					detail_pinned = false
					handled = true
				} else if hit("track_input", mouse_click) {
					if !input_active {input_active = sdl.StartTextInput(state.window)}
					handled = true
				}
				if !handled {
					tabs := LIBRARY_TABS
					for index in 0 ..< len(tabs) {
						if hit_index("chip", mouse_click, u32(index)) {
							selected_filter := tabs[index]
							if selected_filter != filter {
								library.clear_detail(&library_client)
								detail_pinned = false
							}
							filter = selected_filter
							settings_dirty = true
							retry_failed_covers(&textures)
							handled = true
							break
						}
					}
				}
				if !handled {
					for index in visible.cards.first ..< visible.cards.last {
						entry := library_client.pages[filter].items[index]
						if !hit_clipped("card", "library_grid", mouse_click, u32(index)) {continue}
						source: library.Source
						id := entry.uri
						if strings.has_prefix(id, "spotify:playlist:") {
							source = .Playlist
							id = id[len("spotify:playlist:"):]
						} else if strings.has_prefix(id, "spotify:album:") {
							source = .Album
							id = id[len("spotify:album:"):]
						} else if strings.has_prefix(id, "spotify:artist:") {
							source = .Artist
							id = id[len("spotify:artist:"):]
						} else {break}
						handled = library.open_detail(&library_client, source, id, entry)
						if handled {
							retry_failed_covers(&textures)
							detail_pinned = settings_is_pinned(&settings, entry.uri)
						}
						break
					}
				}
				if !handled && library_client.detail.ready {
					if hit("hero_pin", mouse_click) {
						detail_pinned = settings_toggle_pin(
							&settings,
							detail_card_uri(library_client.detail),
						)
						order_dirty = true
						settings_dirty = true
						handled = true
					} else if hit("spotify_link", mouse_click) && !library_client.detail_loading {
						open_spotify_detail(&library_client.detail)
						handled = true
					} else if hit_clipped("detail_more", "detail_rows", mouse_click) {
						handled = library.more_rows(&library_client)
					} else if library_client.detail.source == .Artist {
						for index in visible.releases.first ..< visible.releases.last {
							release := library_client.detail.releases[index]
							if !hit_clipped(
								"release_card",
								"detail_rows",
								mouse_click,
								u32(index),
							) {continue}
							id := release.uri
							if strings.has_prefix(id, "spotify:album:") {
								id = id[len("spotify:album:"):]
								handled = library.open_detail(&library_client, .Album, id, release)
							}
							break
						}
					} else {
						for index in visible.tracks.first ..< visible.tracks.last {
							if !hit_clipped(
								"track_row",
								"detail_rows",
								mouse_click,
								u32(index),
							) {continue}
							build_play_queue(
								&play_queue,
								library_client.detail.rows[:],
								library_client.detail.image_small,
							)
							play_index =
								shuffle ? reorder_play_queue(play_queue[:], index, true) : index
							track_selected = select_play_item(
								play_queue[:],
								play_index,
								&selected,
								&player_cover,
							)
							if track_selected {
								settings_note_recent(
									&settings,
									detail_card_uri(library_client.detail),
								)
								order_dirty = true
								settings_dirty = true
							}
							delete(input)
							input = {}
							handled = true
							break
						}
					}
				}
				if !handled && input_active {
					input_active = false
					_ = sdl.StopTextInput(state.window)
				}
			}
		}
		if resizing {
			if .LEFT not_in buttons {
				resizing = false
				settings_dirty = true
			} else {
				sidebar_width = clamp(mouse.x / density, SIDEBAR_MIN, SIDEBAR_MAX)
			}
			redraw = true
		}
		if scrollbar_drag.container != "" {
			if .LEFT not_in buttons {
				scrollbar_drag = {}
			} else if drag_scrollbar(&scrollbar_drag, mouse.y, density) {
				redraw = true
			}
		}
		if clicked && hit("volume_slider", mouse_click) {volume_dragging = true}
		if volume_dragging {
			box := clay.GetElementData(clay.ID("volume_slider")).boundingBox
			if box.width > 0 {
				volume = clamp((mouse.x - box.x) / box.width, 0, 1)
				if stream != nil {_ = sdl.SetAudioStreamGain(stream, volume)}
			}
			if .LEFT not_in buttons {volume_dragging = false}
			first_frame = true
		}
		if clicked &&
		   (hit("footer_shuffle", mouse_click) ||
				   detail_play_enabled(&library_client) && hit("hero_shuffle", mouse_click)) {
			shuffle = !shuffle
			play_index = reorder_play_queue(play_queue[:], play_index, shuffle)
		}
		if clicked && hit("footer_repeat", mouse_click) {
			repeat = !repeat
			replay_pending = repeat && stage == .Ended
		}
		mpris_delta := 0
		mpris_seek_ms := 0
		mpris_seek_requested := false
		for {
			command, value, received := mpris.poll()
			if !received {break}
			switch command {
			case .Play:
				if stage != .Playing {space_pressed = true}
			case .Pause:
				if stage == .Playing {space_pressed = true}
			case .Play_Pause:
				space_pressed = true
			case .Stop:
				stop_pressed = true
			case .Next:
				mpris_delta += 1
			case .Previous:
				mpris_delta -= 1
			case .Seek:
				mpris_seek_ms = displayed_ms + value
				mpris_seek_requested = true
			case .Set_Position:
				mpris_seek_ms = value
				mpris_seek_requested = true
			case .Quit:
				running = false
			}
		}
		seek_requested := mpris_seek_requested
		if mpris_seek_requested {
			seek_ms = clamp(mpris_seek_ms, 0, max(0, duration_ms))
			start_paused = stage == .Paused
			mpris.seeked(seek_ms)
		}
		if clicked && seek_enabled && hit("seek_slider", mouse_click) {seek_dragging = true}
		if seek_dragging {
			if !seek_enabled {seek_dragging = false} else {
				if .LEFT not_in buttons {
					box := clay.GetElementData(clay.ID("seek_slider")).boundingBox
					seek_ms = seek_position_ms(mouse.x, box.x, box.width, duration_ms)
					start_paused = stage == .Paused
					seek_requested = true
					seek_dragging = false
				}
				first_frame = true
			}
		}
		hero_pressed := clicked && hit("hero_play", mouse_click)
		hero_start := hero_pressed && detail_play_enabled(&library_client)
		restart_playback := track_selected || hero_start
		if hero_start {
			build_play_queue(
				&play_queue,
				library_client.detail.rows[:],
				library_client.detail.image_small,
			)
			play_index = shuffle ? reorder_play_queue(play_queue[:], 0, true) : 0
			_ = select_play_item(play_queue[:], play_index, &selected, &player_cover)
			settings_note_recent(&settings, detail_card_uri(library_client.detail))
			order_dirty = true
			settings_dirty = true
		}
		track_delta := mpris_delta
		if clicked && hit("footer_previous", mouse_click) {track_delta = -1}
		if clicked && hit("footer_next", mouse_click) {track_delta = 1}
		if track_delta != 0 &&
		   advance_play_item(play_queue[:], &play_index, track_delta, &selected, &player_cover) {
			restart_playback = true
		}
		if restart_playback {seek_ms = 0; start_paused = false; seek_dragging = false}
		if restart_playback || seek_requested {
			replay_pending = false
			if worker != nil {
				cancel_worker(queue, &cancel, &closed)
				clear_audio_stream(&stream)
				stage = .Stopping
				play_after_stop = true
			} else {
				space_pressed = true
			}
		}
		if space_pressed || clicked && hit("footer_play", mouse_click) {
			#partial switch stage {
			case .Idle, .Ended, .Failed:
				if worker == nil || thread.is_done(worker) {
					if worker != nil {release_worker(worker, queue, &cancel, closed); worker = nil}
					alloc_error: runtime.Allocator_Error
					queue, alloc_error = chan.create_buffered(
						chan.Chan(player.Packet),
						4,
						context.allocator,
					)
					if alloc_error != nil {stage = .Failed} else {
						sync.atomic_store(&cancel, false)
						closed = false
						work = Login_Work {
							queue     = queue,
							cancel    = &cancel,
							track_url = strings.clone(selected),
							start_ms  = seek_ms,
							source    = &play_source,
							remember  = os.get_env(
								"SPOTI_REMEMBER_LOGIN",
								context.temp_allocator,
							) == "1",
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
							stage = .Failed
						} else {
							clear_audio_stream(&stream)
							finished = false
							sent_frames, sample_rate, duration_ms = 0, 0, 0
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
			artist := ""
			if play_index >= 0 && play_index < len(play_queue) {
				artist = play_queue[play_index].artist
			}
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
					can_next = play_index >= 0 && play_index + 1 < len(play_queue),
					can_previous = play_index > 0,
				},
			)
		}
		sort_library_pages(&library_client, &settings, &page_counts, order_dirty)
		order_dirty = false
		if settings_dirty {
			settings_dirty = false
			save_settings(&settings)
		}
		if clicked {first_frame = true}
	}
}
