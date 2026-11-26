#+feature using-stmt
package main

import "core:fmt"
import "core:strings"
import library "spotify/library"
import oauth "spotify/oauth"
import ui "ui"
import clay "vendor/clay"
import sdl "vendor:sdl3"

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
		mod & sdl.KMOD_SHIFT != {},
	)
	pending_redraw = true
}

app_open_radio :: proc(app: ^App, seed, name, image: string) -> bool {
	uri := library.radio_uri(seed)
	if uri == "" {return false}
	title := name != "" ? fmt.tprintf("%s Radio", name) : "Song Radio"
	return open_entry_page(&app.nav_ctx, library.Entry{uri = uri, name = title, image = image})
}

app_click :: proc(app: ^App, frame: ^Frame, visible: Frame_Visible) {
	using app
	using frame
	if right_clicked && queue_open && hit("queue_panel", mouse_right) {
		if index := queue_item_at(play_index, visible.queue, mouse_right);
		   index >= 0 && index < len(play_queue) {
			open_link_menu(&menu, mouse_right, play_queue[index].uri)
		} else {menu.open = false}
	} else if link := artist_link_at(foot_artists, "footer_artist", 0, mouse_right);
	   right_clicked && link != nil {
		open_card_menu(&menu, mouse_right, link.uri, state_is_pinned(&app_state, link.uri))
	} else if right_clicked && hit("footer_metadata", mouse_right) {
		uri := selected
		if play_index >= 0 && play_index < len(play_queue) {
			uri = play_queue[play_index].uri
		} else if uri == "" {
			uri = app_state.last_played.track
		}
		if uri != "" {open_link_menu(&menu, mouse_right, uri)} else {menu.open = false}
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
				switch menu.entries[index].action {
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
					if release := release_feed_find(&library_client, menu.uri); release != nil {
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
						if release_feed_open_album(&library_client, release.entry) {
							replace_string(&release_play_uri, menu.uri)
						}
					} else if menu.track >= 0 && menu.track < len(library_client.detail.rows) {
						track_selected = app_queue_detail(app, menu.track)
					}
				case .Song_Radio:
					row: library.Track_Row
					if idx := menu.track; idx >= 0 && idx < len(library_client.detail.rows) {
						candidate := library_client.detail.rows[idx]
						if candidate.uri == menu.uri {row = candidate}
					}
					if !app_open_radio(app, menu.uri, row.name, row.image) {
						show_toast(app, "Couldn't open song radio")
					}
				case .Add_To_Queue:
					if !app_enqueue_uri(app, menu.uri) {
						show_toast(app, "Couldn't add to queue")
					}
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
			smooth[.Queue] = {}
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
				if hit_index("feed_save", mouse_click, u32(index)) {
					_ = library.toggle_like(
						&library_client,
						.Album,
						release.entry.uri[len("spotify:album:"):],
						!release_feed_saved(&library_client, release),
					)
				} else if hit_index("feed_play", mouse_click, u32(index)) {
					if release_feed_open_album(&library_client, release.entry) {
						replace_string(&release_play_uri, release.entry.uri)
					}
				} else {
					entry := release.entry
					if link := artist_link_at(
						release.artist_links,
						"feed_artist_link",
						artist_link_id(u32(index), 0),
						mouse_click,
					); link != nil {
						entry = {
							name = link.name,
							uri  = link.uri,
						}
					}
					_ = open_entry_page(&nav_ctx, entry)
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
			} else if hit("search_clear", mouse_click) {
				ui.editor_select_all(&editor)
				input_changed = ui.editor_delete(&editor, .Left) || input_changed
				editor.selecting = false
				pending_redraw = true
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
				if link := artist_link_at(
					library_client.detail.artist_links,
					"hero_artist_link",
					0,
					mouse_click,
				); link != nil {
					handled = open_entry_page(
						&nav_ctx,
						library.Entry{name = link.name, uri = link.uri},
					)
				}
			}
			if !handled && library_client.detail.ready {
				if detail := &library_client.detail;
				   detail.source == .Artist &&
				   !library.detail_loading_visible(&library_client) &&
				   hit("hero_radio", mouse_click) {
					handled = app_open_radio(
						app,
						detail_card_uri(detail^),
						detail.name,
						detail.image,
					)
					if !handled {show_toast(app, "Couldn't open artist radio")}
				} else if hit("hero_like", mouse_click) {
					detail := library_client.detail
					if detail.source != .Liked &&
					   !library_client.detail_loading &&
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
							if link := artist_link_at(
								row.artist_links,
								"artist_link",
								artist_link_id(slot, 0),
								mouse_click,
							); link != nil {
								handled = open_entry_page(
									&nav_ctx,
									library.Entry{name = link.name, uri = link.uri},
								)
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
						ui.editor_set_text(&editor, "")
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
				ui.editor_move(&editor, editor.editing.selection[0])
				_ = sdl.StopTextInput(state.window)
			}
		}
	}
}
