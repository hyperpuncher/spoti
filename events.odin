#+feature using-stmt
package main

import "core:strings"
import edit "core:text/edit"
import "core:time"
import library "spotify/library"
import track "spotify/track"
import ui "ui"
import sdl "vendor:sdl3"

PLAYBACK_FRAME_NS :: u64(1_000_000_000 / 30)

window_visible :: proc(state: ^ui.State) -> bool {
	return sdl.GetWindowFlags(state.window) & {.HIDDEN, .MINIMIZED, .OCCLUDED} == {}
}
REMOTE_POLL_NS :: u64(5_000_000_000)

// Lower an SDL wait (-1 waits forever) so it ends at a tick deadline.
wait_until :: proc(wait_ms: ^i32, now, deadline: u64) {
	remaining :=
		deadline > now ? i32(min((deadline - now + 999_999) / 1_000_000, u64(max(i32)))) : 0
	wait_ms^ = wait_ms^ < 0 ? remaining : min(wait_ms^, remaining)
}

// SDL ticks for a wall-clock deadline; past deadlines return now.
ticks_at :: proc(at: time.Time, now: u64) -> u64 {
	delay := -time.since(at)
	return delay > 0 ? now + u64(delay) : now
}

// Work whose result only a worker can deliver. With a wake event these
// results push SDL events; without one the loop polls.
app_waiting_on_workers :: proc(app: ^App) -> bool {
	client := &app.library_client
	for pending in client.pending {if pending {return true}}
	return(
		client.state == .Authorizing ||
		client.state == .Loading ||
		client.detail_loading ||
		client.search_loading ||
		client.covers_pending > 0 ||
		client.devices_pending ||
		client.transfer_pending ||
		client.release_feed.pending ||
		app.connect_client.worker != nil ||
		app.preload_worker != nil \
	)
}

// Event wait plus the drain switch. Fills the frame flags the later stages
// read and reports whether anything arrived plus whether fades animate.
app_events :: proc(app: ^App, frame: ^Frame) -> (bool, bool) {
	using app
	using frame
	input_limit := library_client.state == .Missing_Client_ID ? 64 : 512
	event: sdl.Event
	wait_ms: i32 = -1 // no redraw while idle; SDL events wake the window
	fades_animating := false
	for alpha in ([4]f32{textures.fade_top_alpha, textures.fade_bottom_alpha, textures.fade_detail_top_alpha, textures.fade_detail_bottom_alpha}) {
		if alpha != 0 && alpha != 1 {fades_animating = true}
	}
	// Anything animating renders at the display rate, so the idle poll
	// below can never throttle a scroll glide or a button spring.
	if editor.selecting ||
	   autoscroll_moving ||
	   smooth_active(&smooth) ||
	   resizing ||
	   dragging ||
	   seek_dragging ||
	   volume_dragging ||
	   scrollbar_drag.container != "" ||
	   fx_animating ||
	   fades_animating ||
	   first_frame ||
	   pending_redraw ||
	   len(library_client.cover_queue) > 0 {
		// Cover uploads are spread over frames; keep draining the backlog.
		wait_ms = 0
	} else if WAKE_EVENT == 0 && app_waiting_on_workers(app) {
		// Without a wake event, worker results need a short poll.
		wait_ms = 40
	}
	now := sdl.GetTicksNS()
	// Only steady playback uses 30 fps. Count from the last layout start,
	// so rendering and presentation time are part of the frame budget.
	// The loop also feeds the audio stream, so it ticks while hidden too.
	if stage == .Playing {
		if now - playback_tick >= PLAYBACK_FRAME_NS {playback_tick = now}
		wait_until(&wait_ms, now, max(last, playback_tick) + PLAYBACK_FRAME_NS)
	}
	// Playback state changes arrive through the decoder queue, not events.
	if worker != nil &&
	   stage != .Playing &&
	   stage != .Paused {wait_until(&wait_ms, now, now + 40_000_000)}
	if remote_control {wait_until(&wait_ms, now, remote_polled_at + REMOTE_POLL_NS)}
	if len(toast) > 0 {wait_until(&wait_ms, now, toast_until)}
	// These deadlines change what the frame shows, so reaching one redraws.
	show_at := max(u64)
	if fx_next_frame != 0 {show_at = fx_next_frame}
	// A settling Connect state is sent from the frame loop.
	if connect_settle_at != 0 {show_at = min(show_at, connect_settle_at)}
	if search_pending {show_at = min(show_at, search_deadline)}
	// Wall-clock deadlines count only while they are still ahead.
	if library_client.detail_loading && time.since(library_client.detail_loading_at) < 0 {
		show_at = min(show_at, ticks_at(library_client.detail_loading_at, now))
	}
	if library_client.state == .Ready && time.since(library_client.page_at) < 0 {
		show_at = min(show_at, ticks_at(library_client.page_at, now))
	}
	if show_at != max(u64) {wait_until(&wait_ms, now, show_at)}
	if library_client.release_feed.open &&
	   !library_client.release_feed.done &&
	   time.since(library_client.release_feed.wait_until) < 0 {
		wait_until(&wait_ms, now, ticks_at(library_client.release_feed.wait_until, now))
	}
	// If the wake event could not be registered, poll the bus instead.
	if mpris_active && WAKE_EVENT == 0 {wait_until(&wait_ms, now, now + 100_000_000)}
	if blink_wait := ui.editor_blink_delay(&editor, sdl.GetTicks()); blink_wait >= 0 {
		wait_until(&wait_ms, now, now + u64(blink_wait) * 1_000_000)
	}
	has_event := sdl.WaitEventTimeout(&event, wait_ms)
	if has_event {
		for {
			#partial switch event.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				running = false
			case .WINDOW_EXPOSED, .WINDOW_SHOWN, .WINDOW_RESTORED:
				first_frame = true
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
				if event.key.key == sdl.K_ESCAPE && menu.open {
					free_context_menu(&menu)
					pending_redraw = true
					break
				}
				if input_active {
					key_mod := event.key.mod
					gui := key_mod & sdl.KMOD_GUI != {}
					alt := .LALT in key_mod || .RALT in key_mod
					shift := key_mod & sdl.KMOD_SHIFT != {}
					cmd := key_mod & (sdl.KMOD_CTRL | sdl.KMOD_GUI) != {}
					switch event.key.key {
					case sdl.K_ESCAPE:
						ui.editor_move(&editor, editor.editing.selection[0])
						editor.selecting = false
						input_active = false
						_ = sdl.StopTextInput(state.window)
						if len(strings.trim_space(input)) == 0 && search_mode {
							library.clear_search(&library_client)
							search_mode, search_pending = false, false
							ui.editor_set_text(&editor, "")
							nav_replace(
								&nav,
								nav_capture(&library_client, filter, false, search_kind, ""),
							)
						}
					case sdl.K_BACKSPACE, sdl.K_DELETE, sdl.K_W:
						if event.key.key == sdl.K_W && !cmd {break}
						backward := event.key.key != sdl.K_DELETE
						direction: edit.Translation = backward ? .Left : .Right
						if gui && !alt {direction = backward ? .Start : .End} else if cmd || alt {
							direction = backward ? .Word_Left : .Word_Right
						}
						input_changed = ui.editor_delete(&editor, direction) || input_changed
					case sdl.K_LEFT, sdl.K_RIGHT, sdl.K_HOME, sdl.K_END:
						backward := event.key.key == sdl.K_LEFT || event.key.key == sdl.K_HOME
						direction: edit.Translation = backward ? .Left : .Right
						if event.key.key == sdl.K_HOME || event.key.key == sdl.K_END || gui {
							direction = backward ? .Start : .End
						} else if cmd || alt {direction = backward ? .Word_Left : .Word_Right}
						ui.editor_translate(&editor, direction, shift)
					case sdl.K_Z, sdl.K_Y:
						if cmd {
							redo := event.key.key == sdl.K_Y || shift
							input_changed =
								ui.editor_undo(&editor, redo, input_limit) || input_changed
						}
					case sdl.K_A:
						if cmd {ui.editor_select_all(&editor)}
					case sdl.K_U:
						if cmd {
							ui.editor_select_all(&editor)
							input_changed = ui.editor_delete(&editor, .Left) || input_changed
						}
					case sdl.K_C, sdl.K_X, sdl.K_V, sdl.K_INSERT:
						inserting := event.key.key == sdl.K_INSERT
						if !cmd && !(inserting && shift) {break}
						cutting := event.key.key == sdl.K_X
						copying := event.key.key == sdl.K_C || inserting && !shift
						if copying || cutting {
							low, high := edit.sorted_selection(&editor.editing)
							if low != high {
								c_input := strings.clone_to_cstring(input[low:high])
								defer delete(c_input)
								if sdl.SetClipboardText(c_input) && cutting {
									input_changed =
										ui.editor_delete(&editor, .Left) || input_changed
								}
							}
						} else {
							clipboard := sdl.GetClipboardText()
							if clipboard != nil {
								value := paste_text(string(cstring(clipboard)))
								input_changed =
									ui.editor_insert(&editor, value, input_limit) || input_changed
								sdl.free(rawptr(clipboard))
							}
						}
					case sdl.K_RETURN, sdl.K_KP_ENTER:
						ui.editor_move(&editor, editor.editing.selection[0])
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
							ui.editor_set_text(&editor, "")
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
						if event.key.mod & (sdl.KMOD_CTRL | sdl.KMOD_GUI) != {} {
							if !input_active {
								input_active = sdl.StartTextInput(state.window)
								ui.editor_move(&editor, len(input))
							}
						}
					}
				}
			case .TEXT_INPUT:
				if input_active && sdl.GetModState() & (sdl.KMOD_CTRL | sdl.KMOD_GUI) == {} {
					added := string(event.text.text)
					if input_text_ok(added) {
						input_changed =
							ui.editor_insert(&editor, added, input_limit) || input_changed
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
	// A timed wake redraws: deadlines above change what the frame shows.
	show_due := show_at != max(u64) && sdl.GetTicksNS() >= show_at
	return has_event || show_due || ui.editor_blink_delay(&editor, sdl.GetTicks()) == 0,
		fades_animating
}
