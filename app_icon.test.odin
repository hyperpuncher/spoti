package main

import "core:os"
import "core:strings"
import "core:testing"
import artwork "spotify/artwork"

@(test)
app_icon_has_transparent_edges_and_resolves_outside_the_checkout_cwd :: proc(t: ^testing.T) {
	path, found := asset_path("app/icon.png")
	if !testing.expect(t, found) {return}
	defer delete(path)
	encoded, err := os.read_entire_file_from_path(path, context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(encoded)
	image, decoded := artwork.decode(encoded)
	if !testing.expect(t, decoded) {return}
	defer artwork.free_image(&image)
	testing.expect_value(t, image.width, 1024)
	testing.expect_value(t, image.height, 1024)
	testing.expect_value(t, image.pixels[3], u8(0))
	center := (512 * image.width + 512) * 4
	testing.expect_value(t, image.pixels[center + 3], u8(255))

	// The root test runner has one thread. No SDL window is created.
	cwd, cwd_err := os.get_working_directory(context.allocator)
	if !testing.expect(t, cwd_err == nil) {return}
	defer delete(cwd)
	outside, temp_err := os.temp_directory(context.temp_allocator)
	if !testing.expect(t, temp_err == nil) {return}
	if !testing.expect(t, os.set_working_directory(outside) == nil) {return}
	defer _ = os.set_working_directory(cwd)
	installed, resolved := asset_path("app/icon.png")
	defer delete(installed)
	testing.expect(t, resolved && strings.has_suffix(installed, "app/icon.png"))
}
