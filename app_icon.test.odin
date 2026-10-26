package main

import "core:os"
import "core:strings"
import "core:testing"
import artwork "spotify/artwork"
import ui "ui"
import sdl "vendor:sdl3"

@(test)
app_icon_has_transparent_edges_and_resolves_outside_the_checkout_cwd :: proc(t: ^testing.T) {
	path, found := ui.asset_path("app/icon.png")
	if !testing.expect(t, found) {return}
	defer delete(path)
	encoded, err := os.read_entire_file_from_path(path, context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(encoded)
	image, decoded := artwork.decode(encoded)
	if !testing.expect(t, decoded) {return}
	defer artwork.free_image(&image)
	testing.expect_value(t, int(image.w), 1024)
	testing.expect_value(t, int(image.h), 1024)
	alpha: u8
	testing.expect(t, sdl.ReadSurfacePixel(image, 0, 0, nil, nil, nil, &alpha))
	testing.expect_value(t, alpha, u8(0))
	testing.expect(t, sdl.ReadSurfacePixel(image, 512, 512, nil, nil, nil, &alpha))
	testing.expect_value(t, alpha, u8(255))

	// The root test runner has one thread. No SDL window is created.
	cwd, cwd_err := os.get_working_directory(context.allocator)
	if !testing.expect(t, cwd_err == nil) {return}
	defer delete(cwd)
	outside, temp_err := os.temp_directory(context.temp_allocator)
	if !testing.expect(t, temp_err == nil) {return}
	if !testing.expect(t, os.set_working_directory(outside) == nil) {return}
	defer _ = os.set_working_directory(cwd)
	installed, resolved := ui.asset_path("app/icon.png")
	defer delete(installed)
	testing.expect(t, resolved && strings.has_suffix(installed, "app/icon.png"))
	font, font_found := ui.resolve_bundled(ui.GEIST_VAR)
	defer delete(font)
	testing.expect(t, font_found && strings.has_suffix(font, ui.GEIST_VAR))
}
