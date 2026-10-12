package main

import "core:testing"
import library "spotify/library"
import clay "vendor/clay"
import sdl "vendor:sdl3"

@(test)
device_panel_keeps_two_line_rows_inside_panel :: proc(t: ^testing.T) {
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
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	defer delete(textures.by_key)
	devices := [?]library.Device {
		{name = "Redmi Note 12 Turbo", type = "Smartphone", active = true},
		{name = "Living room", type = "Speaker"},
	}
	for d in ([]f32{1, 1.5}) {
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
	}
	testing.expect_value(t, errors, 0)
}
