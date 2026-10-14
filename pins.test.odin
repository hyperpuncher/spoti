package main

import "core:math"
import "core:testing"
import library "spotify/library"
import clay "vendor/clay"
import sdl "vendor:sdl3"

@(test)
pin_badge_has_cover_insets_and_contrast_in_both_themes :: proc(t: ^testing.T) {
	errors := 0
	density: f32 = 1
	memory := layout_test_init(&density, &errors, {400, 400})
	defer {clay.SetCurrentContext(nil); delete(memory)}
	defer apply_theme(true)
	entry := library.Entry {
		name  = "Playlist",
		image = "https://i.scdn.co/image/fixture",
	}
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	defer delete(textures.by_key)
	fake_texture: sdl.Texture
	cover := cover_key(entry.image)
	pin := icon_key("pin-filled", .White)
	textures.by_key[cover], textures.by_key[pin] = &fake_texture, &fake_texture
	for dark in ([]bool{true, false}) {
		apply_theme(dark)
		for d in ([]f32{1, 1.5, 2}) {
			density = d
			clay.SetLayoutDimensions({400 * d, 400 * d})
			clay.BeginLayout()
			library_card(&textures, nil, &entry, 0, 200 * d, d, pinned = true)
			commands := clay.EndLayout(0)
			cover_box: clay.BoundingBox
			pin_drawn, badge_drawn := false, false
			background: clay.Color
			for command in commands.internalArray[:commands.length] {
				if command.commandType == .Image {
					key := u64(uintptr(command.renderData.image.imageData))
					if key == cover {cover_box = command.boundingBox}
					if key == pin {pin_drawn = true}
				} else if command.commandType == .Rectangle &&
				   command.id == clay.ID("card_pin", 0).id {
					badge_drawn = true
					background = command.renderData.rectangle.backgroundColor
				}
			}
			if !testing.expect(t, pin_drawn && badge_drawn && cover_box.width > 0) {continue}
			badge := clay.GetElementData(clay.ID("card_pin", 0)).boundingBox
			testing.expect(t, math.abs(badge.x - cover_box.x - 4 * d) < 0.01)
			testing.expect(t, math.abs(badge.y - cover_box.y - 4 * d) < 0.01)
			testing.expect(t, badge.x + badge.width < cover_box.x + cover_box.width)
			testing.expect(t, badge.y + badge.height < cover_box.y + cover_box.height)
			r, _, _ := icon_tint_color(.White, dark)
			testing.expect(t, dark ? r > 200 && background.r < 50 : r < 50 && background.r > 200)
		}
	}
	testing.expect_value(t, errors, 0)
}
