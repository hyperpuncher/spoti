package main

import "core:os"
import "core:strings"
import "core:testing"
import ui "ui"

@(test)
bundled_assets_resolve_outside_the_checkout_cwd :: proc(t: ^testing.T) {
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
