package ui

import ttf "vendor:sdl3/ttf"

// Text slots follow draw order, so storage is bounded by one visible frame.
// SDL_ttf owns each slot's copied string; no borrowed Clay text survives a frame.
cached_text :: proc(state: ^State, font: ^ttf.Font, value: string) -> ^ttf.Text {
	content: ^ttf.Text
	if state.text_count == len(state.texts) {
		content = ttf.CreateText(state.text_engine, font, raw_data(value), len(value))
		if content == nil {return nil}
		append(&state.texts, content)
	} else {
		content = state.texts[state.text_count]
		if ttf.GetTextFont(content) != font && !ttf.SetTextFont(content, font) {return nil}
		if string(cstring(content.text)) != value &&
		   !ttf.SetTextString(content, raw_data(value), len(value)) {return nil}
	}
	state.text_count += 1
	return content
}

finish_text_frame :: proc(state: ^State) {
	for len(state.texts) > state.text_count {ttf.DestroyText(pop(&state.texts))}
	state.text_count = 0
}
