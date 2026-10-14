package main

import "core:math"
import "core:testing"
import library "spotify/library"
import clay "vendor/clay"

@(test)
sign_in_uses_current_viewport_on_the_first_frame :: proc(t: ^testing.T) {
	errors := 0
	density: f32 = 1
	memory := layout_test_init(&density, &errors, {944, 542})
	defer {clay.SetCurrentContext(nil); delete(memory)}
	client := library.Client {
		state = .Authorizing,
	}
	app_state: State
	textures: Textures
	fx: Button_Fx_Ctx
	for d in ([]f32{1, 1.5, 2}) {
		density = d
		clay.ResetMeasureTextCache()
		// The compositor's current size differs from the previous frame.
		clay.SetLayoutDimensions({944, 542})
		first_title, first_line: clay.BoundingBox
		for frame in 0 ..< 2 {
			if frame == 1 {clay.SetLayoutDimensions({936, 534})}
			commands, _ := layout(
				{},
				&client,
				&app_state,
				.Playlists,
				&textures,
				&fx,
				360,
				936,
				534,
				26 * d,
				0,
				d,
				nil,
			)
			title, line: clay.BoundingBox
			title_found, line_found := false, false
			for command in commands.internalArray[:commands.length] {
				if command.commandType != .Text {continue}
				text := command.renderData.text.stringContents
				value := string(text.chars[:text.length])
				if value == "Signing in..." {title = command.boundingBox; title_found = true}
				if value == "Checking your saved Spotify approval." {
					line = command.boundingBox
					line_found = true
				}
			}
			if !testing.expect(t, title_found && line_found) {continue}
			testing.expect(t, math.abs(title.x + title.width / 2 - 468) < 0.01)
			testing.expect(t, math.abs(line.x + line.width / 2 - 468) < 0.01)
			testing.expect(t, math.abs((title.y + line.y + line.height) / 2 - 267) < 0.01)
			if frame == 0 {first_title, first_line = title, line} else {
				testing.expect_value(t, title, first_title)
				testing.expect_value(t, line, first_line)
			}
		}
	}
	testing.expect_value(t, errors, 0)
}

@(test)
restored_collection_preview_never_uses_track_artwork :: proc(t: ^testing.T) {
	app_state := State {
		last_collection = "spotify:playlist:radar",
		last_name = "Release Radar",
		last_saved = true,
		last_played = {
			title = "Lifestyle",
			cover = "https://i.scdn.co/image/track",
			collection = "spotify:playlist:radar",
		},
	}
	client: library.Client
	client.pages[.Albums].items = make([dynamic]library.Entry)
	defer delete(client.pages[.Albums].items)
	append(
		&client.pages[.Albums].items,
		library.Entry{uri = "spotify:album:radar", image = "https://i.scdn.co/image/unrelated"},
	)
	preview := state_collection_preview(&app_state, &client)
	testing.expect_value(t, preview.uri, app_state.last_collection)
	testing.expect_value(t, preview.name, "Release Radar")
	testing.expect_value(t, preview.image, "")
	testing.expect(t, preview.saved)
	// Missing collection metadata must not become the footer's track title.
	app_state.last_name = ""
	preview = state_collection_preview(&app_state, &client)
	testing.expect_value(t, preview.name, "")
	client.pages[.Playlists].items = make([dynamic]library.Entry)
	defer delete(client.pages[.Playlists].items)
	append(
		&client.pages[.Playlists].items,
		library.Entry{uri = "spotify:playlist:other", image = "https://i.scdn.co/image/other"},
		library.Entry {
			uri = app_state.last_collection,
			name = "Release Radar",
			image = "https://i.scdn.co/image/collection",
			subtitle = "spotify",
			total = 200,
			saved = true,
		},
	)
	preview = state_collection_preview(&app_state, &client)
	testing.expect_value(t, preview.image, "https://i.scdn.co/image/collection")
	testing.expect_value(t, preview.name, "Release Radar")
	testing.expect_value(t, preview.subtitle, "spotify")
	testing.expect_value(t, preview.total, 200)
	testing.expect_value(t, app_state.last_played.cover, "https://i.scdn.co/image/track")
}
