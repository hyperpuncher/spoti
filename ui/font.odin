package ui

import "core:container/lru"
import "core:fmt"
import "core:os"
import filepath "core:path/filepath"
import "core:strings"
import native "native_text"

Font_Role :: enum {
	Regular,
	Numeric,
	Bold,
	Medium,
}
GEIST_VAR :: "Geist[wght].ttf"

// Assets resolve around the executable before the development checkout.
// The returned path is owned; candidate strings use the frame allocator.
asset_path :: proc(relative: string) -> (path: string, ok: bool) {
	if exe, err := os.get_executable_path(context.temp_allocator); err == nil {
		dir := filepath.dir(string(exe))
		for root in ([]string{"../Resources", "../share/spoti", ".", "assets", "../assets"}) {
			candidate := fmt.aprintf(
				"%s/%s/%s",
				dir,
				root,
				relative,
				allocator = context.temp_allocator,
			)
			if os.exists(candidate) {return strings.clone(candidate), true}
		}
	}
	candidate := fmt.aprintf("assets/%s", relative, allocator = context.temp_allocator)
	if os.exists(candidate) {return strings.clone(candidate), true}
	return "", false
}

resolve_bundled :: proc(file: string) -> (path: string, ok: bool) {
	if override, found := os.lookup_env("SPOTI_FONTS", context.temp_allocator); found {
		candidate := fmt.aprintf("%s/%s", override, file, allocator = context.temp_allocator)
		if os.exists(candidate) {return strings.clone(candidate), true}
	}
	return asset_path(fmt.aprintf("fonts/%s", file, allocator = context.temp_allocator))
}

// Valid for headless font tests too. No SDL video, window, or worker is needed.
init_text :: proc(state: ^State) -> bool {
	if state.text_backend != nil {return true}
	path, ok := resolve_bundled(GEIST_VAR)
	if !ok {fmt.eprintln("missing bundled font:", GEIST_VAR); return false}
	defer delete(path)
	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)
	state.text_backend = native.open(c_path)
	if state.text_backend == nil {fmt.eprintln("could not initialize native text"); return false}
	// Clay callbacks replace the Odin context. Persistent text must still use
	// its owner's allocator, including when tests enable memory tracking.
	cache := new(Text_Cache)
	cache.allocator = context.allocator
	cache.retired = make([dynamic]^Text_Entry, cache.allocator)
	lru.init(&cache.layouts, TEXT_CACHE_SLOTS, cache.allocator, cache.allocator)
	cache.layouts.on_remove = retire_text_entry
	cache.layouts.on_remove_user_data = cache
	state.text_cache = cache
	return state.text_backend != nil
}

font_weight :: proc(font_id: u16) -> i32 {
	switch Font_Role(font_id) {
	case .Regular, .Numeric:
		return 400
	case .Bold:
		return 800
	case .Medium:
		return 500
	}
	return 400
}
