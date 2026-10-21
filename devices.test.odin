package main

import "core:testing"
import library "spotify/library"
import clay "vendor/clay"
import sdl "vendor:sdl3"

@(test)
floating_picker_panels_keep_rows_bounded :: proc(t: ^testing.T) {
	errors := 0
	density: f32 = 1
	memory := layout_test_init(&density, &errors, {1280, 820})
	defer {clay.SetCurrentContext(nil); delete(memory)}
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	defer delete(textures.by_key)
	devices := [?]library.Device {
		{name = "Redmi Note 12 Turbo", type = "Smartphone", active = true},
		{name = "Living room", type = "Speaker"},
	}
	playlists := make([dynamic]library.Entry, 300)
	defer delete(playlists)
	for &entry in playlists {entry.name = "Playlist"; entry.subtitle = "Account"}
	for d in ([]f32{1, 1.2, 1.5}) {
		density = d
		clay.ResetMeasureTextCache()
		clay.SetLayoutDimensions({1280 * d, 820 * d})
		for _ in 0 ..< 3 {
			clay.BeginLayout()
			if clay.UI()(
			{layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}}},
			) {
				if clay.UI_WithId(clay.ID("footer_devices"))(
				{
					layout = {
						sizing = {
							width = clay.SizingFixed(32 * d),
							height = clay.SizingFixed(32 * d),
						},
					},
					floating = {attachTo = .Root, offset = {1200 * d, 760 * d}},
				},
				) {}
				device_panel({device_open = true, device_rows = devices[:]}, &textures, d)
			}
			commands := clay.EndLayout(0)
			panel := clay.GetElementData(clay.ID("device_panel")).boundingBox
			for command in commands.internalArray[:commands.length] {
				if command.commandType != .Text {continue}
				box := command.boundingBox
				testing.expect(
					t,
					box.y >= panel.y && box.y + box.height <= panel.y + panel.height,
					"device text must stay inside the panel",
				)
			}
		}
		first := clay.GetElementData(clay.ID("device_item", 0)).boundingBox
		second := clay.GetElementData(clay.ID("device_item", 1)).boundingBox
		testing.expect(t, second.y >= first.y + first.height, "device rows must not overlap")
		picker := Context_Menu {
			open         = true,
			count        = 1,
			selected     = -1,
			picker_open  = true,
			picker_items = playlists,
		}
		picker.entries[0] = {.Add_To_Playlist, "Add to playlist"}
		for fraction in ([]f32{0, 0.5, 1}) {
			for _ in 0 ..< 3 {
				scroll := clay.GetScrollContainerData(clay.ID("playlist_picker"))
				if scroll.found {
					scroll.scrollPosition.y =
						fraction *
						min(
							0,
							scroll.scrollContainerDimensions.height -
							scroll.contentDimensions.height,
						)
				}
				clay.BeginLayout()
				context_menu(&picker, &textures, d)
				commands := clay.EndLayout(0)
				testing.expect(t, commands.length < 150)
			}
			scroll := clay.GetScrollContainerData(clay.ID("playlist_picker"))
			gap := f32(u16(2 * d))
			expected := f32(len(playlists)) * ((PICKER_ROW - 2) * d + gap) - gap
			testing.expect(t, abs(scroll.contentDimensions.height - expected) < 0.5)
			if fraction == 1 {
				last := clay.GetElementData(clay.ID("picker_item", u32(len(playlists) - 1)))
				panel := clay.GetElementData(clay.ID("playlist_picker_panel")).boundingBox
				testing.expect(
					t,
					last.found &&
					last.boundingBox.y >= panel.y &&
					last.boundingBox.y < panel.y + panel.height,
				)
			}
		}
	}
	testing.expect_value(t, errors, 0)
}
