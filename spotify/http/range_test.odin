package http

import "core:testing"

@(test)
content_range_requires_complete_consistent_byte_bounds :: proc(t: ^testing.T) {
	info := parse_content_range("bytes 65536-131071/200000")
	testing.expect(t, info.valid)
	testing.expect_value(t, info.start, 65536)
	testing.expect_value(t, info.end, 131071)
	testing.expect_value(t, info.total, 200000)
	for invalid in ([]string{"bytes */200000", "bytes 0-10/*", "bytes -1-10/20", "bytes 10-0/20", "bytes 0-20/20", "bytes 0-0/0", "items 0-1/2", "bytes 0-1/99999999999999999999999"}) {
		testing.expect(t, !parse_content_range(invalid).valid)
	}
}
