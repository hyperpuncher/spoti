package main

import "base:runtime"
import "core:math"
import "core:testing"
import library "spotify/library"
import clay "vendor/clay"
import sdl "vendor:sdl3"

layout_test_measure :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	user_data: rawptr,
) -> clay.Dimensions {
	d := (^f32)(user_data)^
	return {f32(text.length) * f32(config.fontSize) * 0.5 * d, f32(config.fontSize) * d}
}

layout_test_error :: proc "c" (error: clay.ErrorData) {
	context = runtime.default_context()
	counter := (^int)(error.userData)
	counter^ += 1
}

@(test)
large_library_grid_layout_is_bounded :: proc(t: ^testing.T) {
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	errors := 0
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), &memory[0]),
		{1280, 820},
		{handler = layout_test_error, userData = &errors},
	)
	// Clay holds the context process-global; a deleted arena must never
	// dangle into the next test's MinMemorySize.
	defer clay.SetCurrentContext(nil)
	density: f32 = 1
	clay.SetMeasureTextFunction(layout_test_measure, &density)

	client: library.Client
	client.pages[.Albums].items = make([dynamic]library.Entry, 3000)
	defer delete(client.pages[.Albums].items)
	for &entry in client.pages[.Albums].items {
		entry.name = "Album title"
		entry.subtitle = "Artist name"
	}
	client.pages[.Albums].items[0].uri = "spotify:album:selected"
	client.detail.id = "selected"
	client.detail.ready = true
	client.detail.name = "Album"
	client.detail.label = "Album"
	client.detail.has_more = true
	client.detail.rows = make([dynamic]library.Track_Row, 3000)
	defer delete(client.detail.rows)
	for &row in client.detail.rows {
		row.name = "Track title"
		row.artists = "Artist"
		row.duration_ms = 180_000
	}
	client.detail.albums.items = make([dynamic]library.Entry, 3000)
	defer delete(client.detail.albums.items)
	for &release in client.detail.albums.items {
		release.name = "Release"
		release.subtitle = "2026"
	}
	client.detail.albums.total = 3000
	client.detail.albums.has_more = true
	client.detail.singles.items = make([dynamic]library.Entry, 3000)
	defer delete(client.detail.singles.items)
	for &release in client.detail.singles.items {
		release.name = "Single"
		release.subtitle = "2026"
	}
	client.detail.singles.total = 3000
	client.detail.singles.has_more = true
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	fake_icon: sdl.Texture
	textures.by_key[icon_key("play-filled", .Dark)] = &fake_icon
	textures.by_key[icon_key("pause-filled", .Dark)] = &fake_icon
	defer {
		delete(textures.by_key)
		delete(textures.requested)
	}
	footer_overlap_found := false
	defer testing.expect(
		t,
		footer_overlap_found,
		"regression must exercise a clipped row overlapping next",
	)
	app_state: State
	anims := make(map[string]Button_Fx)
	defer delete(anims)
	fx := Button_Fx_Ctx {
		anims = &anims,
	}
	for d in ([]f32{1, 1.5}) {
		density = d
		clay.ResetMeasureTextCache()
		clay.SetLayoutDimensions({1280 * d, 820 * d})
		for width in ([]f32{SIDEBAR_MIN, SIDEBAR_MAX}) {
			input_box, player_box: clay.BoundingBox
			for source in ([]library.Source{.Album, .Artist}) {
				client.detail.source = source
				client.detail.name = source == .Artist ? "Starfoxlaflare" : "Album"
				// Allow dimensions from the previous layout to settle after resizing.
				for _ in 0 ..< 2 {
					clay.UpdateScrollContainers(false, {}, 0)
					_, _ = layout(
						{button = "pause"},
						&client,
						&app_state,
						.Albums,
						&textures,
						&fx,
						width,
						1280 * d,
						820 * d,
						26 * d,
						0,
						d,
						nil,
					)
				}
				input := clay.GetElementData(clay.ID("track_input")).boundingBox
				player := clay.GetElementData(clay.ID("footer_play")).boundingBox
				if source == .Album {
					input_box, player_box = input, player
				} else {
					testing.expect(t, input == input_box, "page changes must not move search")
					testing.expect(
						t,
						player == player_box,
						"page changes must not move playback controls",
					)
				}
				for fraction in ([]f32{0, 0.5, 1}) {
					clay.UpdateScrollContainers(false, {}, 0)
					for id in ([]string{"library_grid", "detail_rows"}) {
						scroll := clay.GetScrollContainerData(clay.ID(id))
						scroll.scrollPosition.y =
							fraction *
							min(
								0,
								scroll.scrollContainerDimensions.height -
								scroll.contentDimensions.height,
							)
					}
					commands, visible := layout(
						{button = "pause"},
						&client,
						&app_state,
						.Albums,
						&textures,
						&fx,
						width,
						1280 * d,
						820 * d,
						26 * d,
						0,
						d,
						nil,
					)
					testing.expect_value(t, errors, 0)
					if source == .Album && fraction == 0 {
						button := clay.GetElementData(clay.ID("footer_next")).boundingBox
						point := sdl.FPoint {
							button.x + button.width / 2,
							button.y + button.height / 2,
						}
						testing.expect(t, hit("footer_next", point))
						overlapped := false
						for index in visible.tracks.first ..< visible.tracks.last {
							if hit_index("track_row", point, u32(index)) {overlapped = true}
							testing.expect(
								t,
								!hit_clipped("track_row", "detail_rows", point, u32(index)),
								"footer clicks must not select clipped overscan rows",
							)
						}
						footer_overlap_found = footer_overlap_found || overlapped
					}
					if source == .Album && fraction == 0 {
						found_selected, hero_play, footer_pause := false, false, false
						for command in commands.internalArray[:commands.length] {
							if command.commandType == .Image {
								key := u64(uintptr(command.renderData.image.imageData))
								if key == icon_key("play-filled", .Dark) {hero_play = true}
								if key == icon_key("pause-filled", .Dark) {footer_pause = true}
							}
							if command.id == clay.ID("card", 0).id &&
							   command.commandType == .Rectangle {
								found_selected =
									command.renderData.rectangle.backgroundColor == SELECTED
							}
						}
						testing.expect(
							t,
							hero_play && footer_pause,
							"detail play must remain play while the footer shows pause",
						)
						testing.expect(
							t,
							found_selected,
							"selected cards need a persistent subtle background",
						)
					}
					seek := clay.GetElementData(clay.ID("seek_slider"))
					testing.expect(
						t,
						seek.found && seek.boundingBox.width > 500 * d,
						"seek bar should use available footer width",
					)
					testing.expect(t, !clay.GetElementData(clay.ID("toolbar_home")).found)
					testing.expect(t, !clay.GetElementData(clay.ID("toolbar_search")).found)
					testing.expect(t, clay.GetElementData(clay.ID("toolbar_forward")).found)
					input := clay.GetElementData(clay.ID("track_input"))
					input_center := input.boundingBox.x + input.boundingBox.width / 2
					testing.expect(
						t,
						input.found && math.abs(input_center - 640 * d) < 120 * d,
						"toolbar search and buttons must sit centered",
					)
					testing.expect(
						t,
						commands.length < 1000,
						"layout work must be bounded by the viewport",
					)
					testing.expect(t, visible.cards.last - visible.cards.first < 40)
					if fraction > 0 {testing.expect(t, visible.cards.first > 0)}
					if fraction == 1 {testing.expect_value(t, visible.cards.last, 3000)}
					grid := clay.GetScrollContainerData(clay.ID("library_grid"))
					usable := width * d - 36 * d
					columns := clamp(int(usable / (140 * d)), 2, 4)
					expected :=
						f32((3000 + columns - 1) / columns) *
						card_row_height(usable / f32(columns), 26 * d, d)
					testing.expect(
						t,
						math.abs(grid.contentDimensions.height - expected) < 0.5,
						"spacers must preserve the complete grid height",
					)
					if source == .Album {
						rows := clay.GetScrollContainerData(clay.ID("detail_rows"))
						expected_rows := 36 * d + 3000 * (ROW_HEIGHT * d + f32(u16(2 * d)))
						testing.expect(
							t,
							math.abs(rows.contentDimensions.height - expected_rows) < 0.5,
							"track spacers must preserve row gaps with no load-more button",
						)
						if fraction == 1 {testing.expect_value(t, visible.tracks.last, 3000)}
					} else if fraction == 1 {
						testing.expect_value(t, visible.singles.last, 3000)
					}
				}
			}
		}
	}
}

@(test)
artist_sections_skip_off_screen_cards :: proc(t: ^testing.T) {
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	errors := 0
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), &memory[0]),
		{1920, 1080},
		{handler = layout_test_error, userData = &errors},
	)
	defer clay.SetCurrentContext(nil)
	density: f32 = 1
	clay.SetMeasureTextFunction(layout_test_measure, &density)

	client: library.Client
	client.detail.ready = true
	client.detail.source = .Artist
	client.detail.id = "artist"
	client.detail.name = "Artist"
	client.detail.label = "Artist"
	client.detail.rows = make([dynamic]library.Track_Row, 10)
	defer delete(client.detail.rows)
	for &row in client.detail.rows {
		row.name = "Top track"
		row.artists = "Artist"
		row.duration_ms = 180_000
	}
	client.detail.albums.items = make([dynamic]library.Entry, 2000)
	defer delete(client.detail.albums.items)
	for &entry in client.detail.albums.items {
		entry.name = "Album title"
		entry.subtitle = "2026"
	}
	client.detail.albums.total = 2000
	client.detail.albums.has_more = true
	client.detail.singles.items = make([dynamic]library.Entry, 2000)
	defer delete(client.detail.singles.items)
	for &entry in client.detail.singles.items {
		entry.name = "Single title"
		entry.subtitle = "2026"
	}
	client.detail.singles.total = 2000
	client.detail.singles.has_more = true
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	defer {
		delete(textures.by_key)
		delete(textures.requested)
	}
	app_state: State
	anims := make(map[string]Button_Fx)
	defer delete(anims)
	fx := Button_Fx_Ctx {
		anims = &anims,
	}
	for _ in 0 ..< 2 {
		clay.UpdateScrollContainers(false, {}, 0)
		_, _ = layout(
			{button = "pause"},
			&client,
			&app_state,
			.Albums,
			&textures,
			&fx,
			SIDEBAR_MAX,
			1920,
			1080,
			26,
			0,
			1,
			nil,
		)
	}
	for fraction in ([]f32{0, 0.5, 1}) {
		clay.UpdateScrollContainers(false, {}, 0)
		scroll := clay.GetScrollContainerData(clay.ID("detail_rows"))
		scroll.scrollPosition.y =
			fraction *
			min(0, scroll.scrollContainerDimensions.height - scroll.contentDimensions.height)
		_, _ = layout(
			{button = "pause"},
			&client,
			&app_state,
			.Albums,
			&textures,
			&fx,
			SIDEBAR_MAX,
			1920,
			1080,
			26,
			0,
			1,
			nil,
		)
		// Clay prunes its 100-entry scroll container array each frame, so a
		// single frame may hold at most that many clips. Off-screen sections
		// must render no cards instead of a full viewport each.
		testing.expect_value(t, errors, 0)
	}
}

@(test)
selected_card_matches_both_source_and_id :: proc(t: ^testing.T) {
	detail := library.Detail {
		ready  = true,
		source = .Playlist,
		id     = "same-id",
	}
	entry := library.Entry {
		uri = "spotify:playlist:same-id",
	}
	testing.expect(t, card_selected(&entry, &detail))
	entry.uri = "spotify:album:same-id"
	testing.expect(t, !card_selected(&entry, &detail))
	detail.source = .Album
	testing.expect(t, card_selected(&entry, &detail))
	detail.ready = false
	testing.expect(t, !card_selected(&entry, &detail))
	testing.expect(t, SELECTED.r > SIDEBAR.r && SELECTED.r < HOVER.r)
}

@(test)
visible_items_preserve_partial_rows_and_overscan :: proc(t: ^testing.T) {
	start := visible_items(2995, 4, 200, 0, 450)
	testing.expect_value(t, start.first, 0)
	testing.expect_value(t, start.last, 16)
	testing.expect_value(t, start.before + 4 * 200 + start.after, f32(749 * 200))
	middle := visible_items(2995, 4, 200, 10_050, 450)
	testing.expect_value(t, middle.first, 196)
	testing.expect_value(t, middle.last, 216)
	testing.expect_value(t, middle.before + 5 * 200 + middle.after, f32(749 * 200))
	end := visible_items(2995, 4, 200, 1e6, 450)
	testing.expect_value(t, end.last, 2995)
	testing.expect_value(t, end.after, f32(0))
	short := visible_items(3, 4, 200, -100, 450)
	testing.expect_value(t, short.first, 0)
	testing.expect_value(t, short.last, 3)
	testing.expect_value(t, visible_items(0, 4, 200, 0, 450), Visible_Items{})
}

@(test)
scrollbar_thumb_hides_when_content_fits_and_clamps_at_both_ends :: proc(t: ^testing.T) {
	_, _, fits := scrollbar_metrics(0, 400, 800, 24, 2)
	testing.expect(t, !fits)
	thumb, top, visible := scrollbar_metrics(0, 4000, 800, 24, 2)
	testing.expect(t, visible && thumb >= 24)
	testing.expect_value(t, top, f32(2))
	_, bottom, _ := scrollbar_metrics(-3200, 4000, 800, 24, 2)
	testing.expect(t, math.abs(bottom - (800 - thumb - 2)) < 0.01)
	_, clamped, _ := scrollbar_metrics(-99999, 4000, 800, 24, 2)
	testing.expect_value(t, clamped, bottom)
}

@(test)
autoscroll_delta_deadzone_and_direction :: proc(t: ^testing.T) {
	d: f32 = 2
	testing.expect_value(t, autoscroll_delta(5 * d, 0.016, d), 0)
	testing.expect_value(t, autoscroll_delta(-5 * d, 0.016, d), 0)
	down := autoscroll_delta(60 * d, 0.016, d)
	testing.expect(t, down < 0, "steering down must scroll down")
	up := autoscroll_delta(-60 * d, 0.016, d)
	testing.expect(t, up > 0, "steering up must scroll up")
	testing.expect_value(t, down, -up)
	testing.expect_value(t, autoscroll_delta(60 * d, 0, d), 0)
}

@(test)
wheel_target_glides_to_rest :: proc(t: ^testing.T) {
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	errors := 0
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), &memory[0]),
		{1280, 820},
		{handler = layout_test_error, userData = &errors},
	)
	defer clay.SetCurrentContext(nil)
	density: f32 = 1
	clay.SetMeasureTextFunction(layout_test_measure, &density)
	client: library.Client
	client.detail.ready = true
	client.detail.source = .Playlist
	client.detail.name = "Playlist"
	client.detail.label = "Playlist"
	client.detail.rows = make([dynamic]library.Track_Row, 100)
	defer delete(client.detail.rows)
	for &row in client.detail.rows {
		row.name = "Track title"
		row.artists = "Artist"
		row.duration_ms = 180_000
	}
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	defer {
		delete(textures.by_key)
		delete(textures.requested)
	}
	app_state: State
	d: f32 = 1
	clay.SetLayoutDimensions({1280, 820})
	clay.UpdateScrollContainers(false, {}, 0)
	glide_anims := make(map[string]Button_Fx)
	defer delete(glide_anims)
	glide_fx := Button_Fx_Ctx {
		anims = &glide_anims,
	}
	_, _ = layout(
		{button = "pause"},
		&client,
		&app_state,
		.Playlists,
		&textures,
		&glide_fx,
		360,
		1280,
		820,
		26,
		0,
		d,
		nil,
	)
	rows := clay.GetElementData(clay.ID("detail_rows"))
	testing.expect(t, rows.found, "detail rows must exist for the glide test")
	clay.SetPointerState({rows.boundingBox.x + 10, rows.boundingBox.y + 10}, false)
	smooth: Smooth
	testing.expect(
		t,
		scroll_wheel("detail_rows", -1, d, &smooth),
		"wheel over the rows must arm a glide",
	)
	testing.expect(t, smooth.active)
	testing.expect_value(t, smooth.target, -120 * d)
	steps := 0
	for smooth.active && steps < 600 {
		testing.expect(t, smooth_step("detail_rows", &smooth, 1.0 / 60))
		steps += 1
	}
	testing.expect(t, !smooth.active, "glide must settle on its target")
	data := clay.GetScrollContainerData(clay.ID("detail_rows"))
	testing.expect_value(t, data.scrollPosition.y, smooth.target)
	smooth_cancel("detail_rows", &smooth)
	testing.expect(t, !smooth.active)
	testing.expect_value(t, errors, 0)
}

@(test)
button_press_scales_icon_and_release_springs_back :: proc(t: ^testing.T) {
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	errors := 0
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), &memory[0]),
		{1280, 820},
		{handler = layout_test_error, userData = &errors},
	)
	defer clay.SetCurrentContext(nil)
	density: f32 = 1
	clay.SetMeasureTextFunction(layout_test_measure, &density)
	anims := make(map[string]Button_Fx)
	defer delete(anims)
	fx := Button_Fx_Ctx {
		anims = &anims,
	}
	fx_test_layout(&fx, 1)
	next := clay.GetElementData(clay.ID("footer_next")).boundingBox
	testing.expect(t, next.width > 0, "footer next must exist")
	center := clay.Vector2{next.x + next.width / 2, next.y + next.height / 2}
	// Hover without press reports hover at full size.
	fx.mouse_down = false
	clay.SetPointerState(center, false)
	fx_test_layout(&fx, 1)
	scale, over := button_fx(&fx, "footer_next")
	testing.expect(t, over, "pointer over footer next must report hover")
	testing.expect_value(t, scale, 1)
	// Press shrinks instantly.
	fx.mouse_down = true
	clay.SetPointerState(center, true)
	fx_test_layout(&fx, 1)
	scale, over = button_fx(&fx, "footer_next")
	testing.expect(t, over)
	testing.expect_value(t, scale, BUTTON_PRESS)
	// Release springs back instead of snapping.
	fx.mouse_down = false
	clay.SetPointerState(center, false)
	scale, _ = button_fx(&fx, "footer_next")
	testing.expect(t, scale > BUTTON_PRESS && scale <= 1, "release must ease back")
	testing.expect_value(t, errors, 0)
}

fx_test_layout :: proc(fx: ^Button_Fx_Ctx, d: f32) {
	clay.SetLayoutDimensions({1280, 820})
	clay.UpdateScrollContainers(false, {}, 0)
	client: library.Client
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	defer {delete(textures.by_key); delete(textures.requested)}
	app_state: State
	_, _ = layout(
		{button = "pause"},
		&client,
		&app_state,
		.Playlists,
		&textures,
		fx,
		360,
		1280,
		820,
		26,
		0,
		d,
		nil,
	)
}

@(test)
apply_theme_switches_palette_and_restores_dark :: proc(t: ^testing.T) {
	testing.expect(t, LIGHT_THEME.bg != DARK_THEME.bg, "themes must differ")
	apply_theme(false)
	testing.expect(t, BG == LIGHT_THEME.bg, "light theme must apply")
	testing.expect(t, WHITE == LIGHT_THEME.text, "text follows the theme")
	apply_theme(true)
	testing.expect(t, BG == DARK_THEME.bg, "dark theme must restore")
	testing.expect(t, WHITE == DARK_THEME.text, "other tests render dark")
}

@(test)
artist_discography_cards_stay_inside_their_padding :: proc(t: ^testing.T) {
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	errors := 0
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), &memory[0]),
		{1280, 820},
		{handler = layout_test_error, userData = &errors},
	)
	defer clay.SetCurrentContext(nil)
	density: f32 = 1
	clay.SetMeasureTextFunction(layout_test_measure, &density)

	client: library.Client
	client.detail = library.Detail {
		ready  = true,
		source = .Artist,
		id     = "artist",
		name   = "Artist",
	}
	client.detail.albums.items = make([dynamic]library.Entry, 58)
	defer delete(client.detail.albums.items)
	for &release in client.detail.albums.items {
		release.name = "Release with a fairly long name"
		release.subtitle = "2026"
	}
	client.detail.albums.total = 58
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	defer {
		delete(textures.by_key)
		delete(textures.requested)
	}
	app_state: State
	anims := make(map[string]Button_Fx)
	defer delete(anims)
	fx := Button_Fx_Ctx {
		anims = &anims,
	}
	density = 1.2
	clay.SetLayoutDimensions({1881, 1069})
	// Three settles: the first frame still spans the scrollbar outset.
	for _ in 0 ..< 3 {
		clay.UpdateScrollContainers(false, {}, 0)
		_, _ = layout(
			{button = "pause"},
			&client,
			&app_state,
			.Albums,
			&textures,
			&fx,
			SIDEBAR_MAX,
			1881,
			1069,
			26 * 1.2,
			0,
			1.2,
			nil,
		)
	}
	_, visible := layout(
		{button = "pause"},
		&client,
		&app_state,
		.Albums,
		&textures,
		&fx,
		SIDEBAR_MAX,
		1881,
		1069,
		26 * 1.2,
		0,
		1.2,
		nil,
	)
	testing.expect_value(t, errors, 0)
	rows := clay.GetElementData(clay.ID("detail_rows"))
	if !testing.expect(t, rows.found) {return}
	edge := rows.boundingBox.x + rows.boundingBox.width
	// The detail root reserves the scrollbar outset, so the grid must end
	// before it instead of stretching underneath the thumb.
	testing.expect(
		t,
		math.abs(edge - (1881 - SCROLLBAR_OUTSET * 1.2)) < 1,
		"the discography must respect the scrollbar outset",
	)
	right := f32(0)
	for index in visible.releases.first ..< visible.releases.last {
		card := clay.GetElementData(clay.ID("release_card", u32(index)))
		if !testing.expect(t, card.found) {continue}
		right = max(right, card.boundingBox.x + card.boundingBox.width)
	}
	inset := edge - right
	testing.expect(
		t,
		inset >= 20 * 1.2 - 1 && inset <= (20 + SCROLLBAR_OUTSET) * 1.2 + 1,
		"the last release card must keep the page side padding",
	)
}
