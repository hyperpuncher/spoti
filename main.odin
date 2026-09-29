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
import player "spotify/player"
import session "spotify/session"
import track "spotify/track"
import ui "ui"
import clay "vendor/clay"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

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

pointer_over :: proc(id: string, index: u32 = 0) -> bool {
	return clay.PointerOver(clay.ID(id, index))
}

update_cursor :: proc(
	state: ^ui.State,
	client: ^library.Client,
	resizing: bool,
	visible: Frame_Visible,
) {
	if resizing || pointer_over("sidebar_handle") {
		ui.set_cursor(state, .Resize)
		return
	}
	if pointer_over("track_input") {
		ui.set_cursor(state, .Text)
		return
	}
	for id in ([]string{"toolbar_back", "toolbar_home", "toolbar_library", "toolbar_search", "detail_more", "hero_play", "footer_play", "footer_previous", "footer_next", "footer_repeat", "spotify_link"}) {
		if id == "hero_play" && !detail_play_enabled(client) {continue}
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

ensure_covers :: proc(
	client: ^library.Client,
	textures: ^Textures,
	filter: library.Kind,
	player_cover: string,
	visible: Frame_Visible,
) {
	urls: [dynamic]string
	defer delete(urls)
	append(&urls, player_cover)
	for entry in client.pages[filter].items[visible.cards.first:visible.cards.last] {append(&urls, entry.image)}
	if client.detail.ready {
		append(&urls, client.detail.image)
		append(&urls, client.detail.image_preview)
		append(&urls, client.detail.image_small)
		for row in client.detail.rows[visible.tracks.first:visible.tracks.last] {
			append(&urls, row.image)
			append(&urls, row.image_small)
		}
		for release in client.detail.releases[visible.releases.first:visible.releases.last] {append(&urls, release.image)}
	}
	requested := 0
	for url in urls {
		if requested >= 4 {break}
		if len(url) == 0 {continue}
		key := cover_key(url)
		if key in textures.by_key || key in textures.requested {continue}
		if library.request_cover(client, url, key) {
			textures.requested[key] = true
			requested += 1
		}
	}
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
	cancel, closed := false, false
	stream: ^sdl.AudioStream
	title: string
	selected := strings.clone(session.TRACK_URL)
	player_cover: string
	play_queue: [dynamic]Play_Item
	play_index := -1
	input: string
	input_active := false
	textures := Textures {
		by_key    = make(map[u64]^sdl.Texture),
		requested = make(map[u64]bool),
	}
	load_icons(&state, &textures)
	library_client: library.Client
	filter := library.Kind.Playlists
	sidebar_width: f32 = 360
	resizing := false
	defer {
		if worker != nil {release_worker(worker, queue, &cancel, closed)}
		if stream != nil {sdl.DestroyAudioStream(stream)}
		library.stop(&library_client)
		for _, texture in textures.by_key {sdl.DestroyTexture(texture)}
		delete(textures.by_key)
		delete(textures.requested)
		delete(title)
		delete(selected)
		delete(player_cover)
		free_play_queue(&play_queue)
		delete(input)
	}
	stage := Stage.Idle
	finished := false
	repeat, replay_pending, play_after_stop := false, false, false
	sent_frames, sample_rate, duration_ms := 0, 0, 0
	displayed_ms := 0
	last := sdl.GetTicksNS()
	first_frame := true
	for running := true; running; {
		defer free_all(context.temp_allocator)
		wheel := sdl.FPoint{}
		mouse_click := sdl.FPoint{}
		clicked, space_pressed, stop_pressed := false, false, false
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
		if first_frame {wait_ms = 0}
		has_event := sdl.WaitEventTimeout(&event, wait_ms)
		redraw := has_event || first_frame
		first_frame = false
		if has_event {
			for {
				#partial switch event.type {
				case .QUIT, .WINDOW_CLOSE_REQUESTED:
					running = false
				case .MOUSE_BUTTON_UP:
					if event.button.button == sdl.BUTTON_LEFT {resizing = false}
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
					}
				}
				if !sdl.PollEvent(&event) {break}
			}
		}
		if !running {break}
		if library_client.worker == nil {
			remember := os.get_env("SPOTI_REMEMBER_LOGIN", context.temp_allocator) == "1"
			_ = library.start(&library_client, remember)
		}
		if library.poll(&library_client) {redraw = true}
		for cover in library.take_cover(&library_client) {
			redraw = true
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
		if stop_pressed && worker != nil && stage != .Stopping {
			sync.atomic_store(&cancel, true)
			chan.close(queue)
			closed = true
			if stream != nil {
				sdl.DestroyAudioStream(stream)
				stream = nil
			}
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
			sync.atomic_store(&cancel, true)
			if !closed {
				chan.close(queue)
				closed = true
			}
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
							_ = sdl.SetAudioStreamGain(stream, 0.5)
							_ = sdl.ResumeAudioStreamDevice(stream)
						}
						sample_rate = packet.sample_rate
					}
					if stream == nil ||
					   !sdl.PutAudioStreamData(
							   stream,
							   raw_data(packet.pcm),
							   c.int(player.PCM_BYTES),
						   ) {
						fmt.eprintln("SDL3 audio device or stream failed:", sdl.GetError())
						stage = .Failed
					} else {
						sent_frames += player.BUFFER_FRAMES
						stage = .Playing
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
			if repeat {
				replay_pending = true
			} else if play_index + 1 < len(play_queue) {
				play_index += 1
				_ = select_play_item(play_queue[:], play_index, &selected, &player_cover)
				replay_pending = true
			}
			redraw = true
		}
		if replay_pending && stage == .Ended && worker != nil && thread.is_done(worker) {
			replay_pending = false
			space_pressed = true
			redraw = true
		}
		if !redraw && stage != .Playing {continue}

		progress := f32(0)
		if sample_rate > 0 && duration_ms > 0 && stream != nil {
			queued := max(0, sdl.GetAudioStreamQueued(stream))
			measured_ms := (sent_frames - int(queued) / 4) * 1000 / sample_rate
			displayed_ms = max(displayed_ms, clamp(measured_ms, 0, duration_ms))
			progress = f32(displayed_ms) / f32(duration_ms)
		}
		button := "play"
		if stage == .Playing {button = "pause"}
		if stage == .Paused {button = "resume"}
		if stage == .Signing_In || stage == .Buffering || stage == .Stopping {button = "wait"}
		status := "Ready to play"
		switch stage {
		case .Signing_In:
			status = "Signing in. See the terminal for the browser link."
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
		view := View {
			title        = shown_title,
			status       = status,
			button       = button,
			progress     = progress,
			elapsed      = duration_text(displayed_ms, times[0][:]),
			total        = duration_text(duration_ms, times[1][:]),
			input        = shown_input,
			cover        = player_cover,
			repeat       = repeat,
			input_active = input_active,
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
		density := ui.scale(&state)
		wheel_used := scroll_wheel("library_grid", wheel.y, density)
		if !wheel_used {wheel_used = scroll_wheel("detail_rows", wheel.y, density)}
		clay.UpdateScrollContainers(false, {}, dt)
		card_text_height :=
			f32(ttf.GetFontHeight(ui.font_for_size(&state, 14 * density))) +
			f32(ttf.GetFontHeight(ui.font_for_size(&state, 12 * density)))
		commands, visible := layout(
			view,
			&library_client,
			filter,
			&textures,
			sidebar_width,
			f32(width),
			f32(height),
			card_text_height,
			dt,
			density,
		)
		update_cursor(&state, &library_client, resizing, visible)
		_ = sdl.SetRenderDrawColor(state.renderer, 18, 18, 18, 255)
		_ = sdl.RenderClear(state.renderer)
		render(&commands, &state, &textures)
		ui.frame_done(&state)
		load_more_near_bottom(&library_client, filter, ui.scale(&state))
		ensure_covers(&library_client, &textures, filter, player_cover, visible)
		if clicked {
			if hit("sidebar_handle", mouse_click) {
				resizing = true
			} else {
				handled := false
				if hit("toolbar_back", mouse_click) || hit("toolbar_library", mouse_click) {
					library.clear_detail(&library_client)
					handled = true
				} else if hit("toolbar_home", mouse_click) {
					filter = .Playlists
					library.clear_detail(&library_client)
					handled = true
				} else if hit("toolbar_search", mouse_click) || hit("track_input", mouse_click) {
					if !input_active {input_active = sdl.StartTextInput(state.window)}
					handled = true
				}
				if !handled {
					tabs := LIBRARY_TABS
					for index in 0 ..< len(tabs) {
						if hit_index("chip", mouse_click, u32(index)) {
							selected_filter := tabs[index]
							if selected_filter != filter {library.clear_detail(&library_client)}
							filter = selected_filter
							handled = true
							break
						}
					}
				}
				if !handled {
					for index in visible.cards.first ..< visible.cards.last {
						entry := library_client.pages[filter].items[index]
						if !hit_index("card", mouse_click, u32(index)) {continue}
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
						break
					}
				}
				if !handled && library_client.detail.ready {
					if hit("spotify_link", mouse_click) && !library_client.detail_loading {
						open_spotify_detail(&library_client.detail)
						handled = true
					} else if hit("detail_more", mouse_click) {
						handled = library.more_rows(&library_client)
					} else if library_client.detail.source == .Artist {
						for index in visible.releases.first ..< visible.releases.last {
							release := library_client.detail.releases[index]
							if !hit_index("release_card", mouse_click, u32(index)) {continue}
							id := release.uri
							if strings.has_prefix(id, "spotify:album:") {
								id = id[len("spotify:album:"):]
								handled = library.open_detail(&library_client, .Album, id, release)
							}
							break
						}
					} else {
						for index in visible.tracks.first ..< visible.tracks.last {
							if !hit_index("track_row", mouse_click, u32(index)) {continue}
							build_play_queue(&play_queue, library_client.detail.rows[:])
							play_index = index
							_ = select_play_item(
								play_queue[:],
								play_index,
								&selected,
								&player_cover,
							)
							if len(player_cover) == 0 {
								player_cover = strings.clone(library_client.detail.image_small)
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
			} else {
				sidebar_width = clamp(mouse.x / density, SIDEBAR_MIN, SIDEBAR_MAX)
			}
			redraw = true
		}
		if clicked && hit("footer_repeat", mouse_click) {
			repeat = !repeat
			replay_pending = repeat && stage == .Ended
		}
		hero_pressed := clicked && hit("hero_play", mouse_click)
		restart_playback := hero_pressed && detail_play_enabled(&library_client)
		if restart_playback {
			build_play_queue(&play_queue, library_client.detail.rows[:])
			play_index = 0
			_ = select_play_item(play_queue[:], play_index, &selected, &player_cover)
			if len(player_cover) == 0 {
				player_cover = strings.clone(library_client.detail.image_small)
			}
		}
		track_delta := 0
		if clicked && hit("footer_previous", mouse_click) {track_delta = -1}
		if clicked && hit("footer_next", mouse_click) {track_delta = 1}
		if track_delta != 0 &&
		   select_play_item(play_queue[:], play_index + track_delta, &selected, &player_cover) {
			play_index += track_delta
			restart_playback = true
		}
		if restart_playback {
			if worker != nil && stage != .Idle && stage != .Ended && stage != .Failed {
				sync.atomic_store(&cancel, true)
				if !closed {chan.close(queue); closed = true}
				if stream != nil {sdl.DestroyAudioStream(stream); stream = nil}
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
							remember  = os.get_env(
								"SPOTI_REMEMBER_LOGIN",
								context.temp_allocator,
							) == "1",
						}
						diagnostic.write("playback worker starting")
						worker = thread.create_and_start_with_data(&work, login_and_decode)
						if worker == nil {
							delete(work.track_url)
							chan.destroy(queue)
							stage = .Failed
						} else {
							if stream != nil {
								sdl.DestroyAudioStream(stream)
								stream = nil
							}
							finished = false
							sent_frames, sample_rate, duration_ms = 0, 0, 0
							displayed_ms = 0
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
		if clicked {first_frame = true}
	}
}
