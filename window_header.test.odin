package main

import "core:testing"
import clay "vendor/clay"
import sdl "vendor:sdl3"

@(test)
header_dragging_keeps_window_controls_and_toolbar_clickable :: proc(t: ^testing.T) {
	errors := 0
	density: f32 = 1
	memory := layout_test_init(&density, &errors, {1280, 820})
	defer {clay.SetCurrentContext(nil); delete(memory)}
	anims := make(map[u32]Button_Fx)
	defer delete(anims)
	fx := Button_Fx_Ctx {
		anims = &anims,
	}
	for d in ([]f32{1, 1.5}) {
		density = d
		fx_test_layout(&fx, d)
		controls := sdl.FRect{0, 0, 96 * d, 58 * d}
		testing.expect(
			t,
			!header_can_drag({40 * d, 15 * d}, d, controls),
			"native controls must not drag",
		)
		testing.expect(t, !header_can_drag({1200, 60 * d}, d, controls), "content must not drag")
		testing.expect(
			t,
			header_can_drag({1200, 20 * d}, d, controls),
			"empty header space must drag",
		)
		right_controls := sdl.FRect{1100, 0, 180, 58 * d}
		testing.expect(
			t,
			!header_can_drag({1200, 20 * d}, d, right_controls),
			"Windows controls must not drag",
		)
		testing.expect(
			t,
			header_can_drag({40 * d, 20 * d}, d, right_controls),
			"empty left header must drag on Windows",
		)
		for id in ([]string{"toolbar_back", "toolbar_forward", "track_input", "toolbar_releases"}) {
			data := clay.GetElementData(clay.ID(id))
			if !testing.expect(t, data.found) {continue}
			box := data.boundingBox
			testing.expect(
				t,
				!header_can_drag({box.x + box.width / 2, box.y + box.height / 2}, d, controls),
			)
			when ODIN_OS == .Darwin {
				testing.expect(t, box.x >= 96 * d, "toolbar must not overlap traffic lights")
			}
		}
	}
	testing.expect_value(t, errors, 0)
}
