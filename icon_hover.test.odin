package main

import "core:testing"
import library "spotify/library"
import clay "vendor/clay"
import sdl "vendor:sdl3"

@(test)
icon_controls_hover_by_tint_without_backgrounds :: proc(t: ^testing.T) {
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	errors := 0
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), &memory[0]),
		{1280, 820},
		{handler = layout_test_error, userData = &errors},
	)
	defer clay.SetCurrentContext(nil)
	defer apply_theme(true)
	density: f32 = 1
	clay.SetMeasureTextFunction(layout_test_measure, &density)
	client := library.Client {
		state = .Ready,
	}
	app_state: State
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	defer delete(textures.by_key)
	fake_texture: sdl.Texture
	for name in ([]string{"chevron-left", "skip-back-filled", "skip-forward-filled", "speaker"}) {
		textures.by_key[icon_key(name, .Muted)] = &fake_texture
		textures.by_key[icon_key(name, .White)] = &fake_texture
		textures.by_key[icon_key(name, .Hover)] = &fake_texture
	}
	anims := make(map[string]Button_Fx)
	defer delete(anims)
	fx := Button_Fx_Ctx {
		anims = &anims,
	}
	targets := [?]struct {
		id, icon: string,
		primary:  bool,
	} {
		{"toolbar_back", "chevron-left", false},
		{"footer_previous", "skip-back-filled", true},
		{"footer_next", "skip-forward-filled", true},
		{"footer_devices", "speaker", false},
	}
	for dark in ([]bool{true, false}) {
		apply_theme(dark)
		r, g, b := icon_tint_color(.Hover, dark)
		testing.expect_value(t, r, u8(FOOTER_HOVER.r))
		testing.expect_value(t, g, u8(FOOTER_HOVER.g))
		testing.expect_value(t, b, u8(FOOTER_HOVER.b))
		clay.SetPointerState({-100, -100}, false)
		_, _ = layout(
			{can_back = true},
			&client,
			&app_state,
			.Playlists,
			&textures,
			&fx,
			360,
			1280,
			820,
			26,
			0,
			1,
			nil,
		)
		for target in targets {
			box := clay.GetElementData(clay.ID(target.id)).boundingBox
			if !testing.expect(t, box.width > 0 && box.height > 0) {continue}
			for hovered in ([]bool{false, true}) {
				clay.SetPointerState(
					hovered ? clay.Vector2{box.x + box.width / 2, box.y + box.height / 2} : clay.Vector2{-100, -100},
					false,
				)
				commands, _ := layout(
					{can_back = true},
					&client,
					&app_state,
					.Playlists,
					&textures,
					&fx,
					360,
					1280,
					820,
					26,
					0,
					1,
					nil,
				)
				expected := hovered ? Icon_Tint.White : Icon_Tint.Muted
				if target.primary {expected = hovered ? .Hover : .White}
				icon_found := false
				for command in commands.internalArray[:commands.length] {
					if command.commandType == .Rectangle && command.id == clay.ID(target.id).id {
						testing.expect(
							t,
							command.renderData.rectangle.backgroundColor[3] == 0,
							"hover must not paint a circular background",
						)
					}
					if command.commandType == .Image {
						key := u64(uintptr(command.renderData.image.imageData))
						if key == icon_key(target.icon, expected) {icon_found = true}
					}
				}
				testing.expect(
					t,
					icon_found,
					"primary and secondary controls must both have a visible color hover state",
				)
			}
		}
	}
	testing.expect_value(t, errors, 0)
}
