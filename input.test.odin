package main

import "core:testing"

@(test)
pasted_text_joins_lines_and_keeps_spaces :: proc(t: ^testing.T) {
	for example in ([]struct {
			input, want: string,
		}{{"hello", "hello"}, {"hello\n", "hello"}, {"\r\n  https://open.spotify.com/track/abc \r\n", "  https://open.spotify.com/track/abc "}, {"one\ntwo\tthree", "one two three"}, {"two  spaces", "two  spaces"}, {"\x01hidden\x7f", "hidden"}, {"Кино\nгруппа", "Кино группа"}, {"\n\t\r", ""}}) {
		testing.expect_value(t, paste_text(example.input), example.want)
	}
}
