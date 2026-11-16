#+feature using-stmt
package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import diagnostic "diagnostic"
import connect "spotify/connect"
import library "spotify/library"
import mpris "spotify/mpris"
import player "spotify/player"
import session "spotify/session"
import clay "vendor/clay"
import sdl "vendor:sdl3"

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
			smooth_cancel_id(&smooth, scrollbar_drag.container)
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
				app_stop_audio(app)
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
	if clicked && hit("footer_metadata", mouse_click) {
		if link := artist_link_at(foot_artists, "footer_artist", 0, mouse_click); link != nil {
			_ = open_entry_page(&nav_ctx, library.Entry{name = link.name, uri = link.uri})
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
			app_stop_audio(app)
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
						next      = &next_track,
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
						sent_frames, origin_frames, sample_rate = 0, 0, 0
						clear_upcoming(app)
						clear_next_track(&next_track)
						tracks_started = 0
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
				album = play_index >= 0 && play_index < len(play_queue) ? play_queue[play_index].album : "",
				art_url = player_cover,
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
