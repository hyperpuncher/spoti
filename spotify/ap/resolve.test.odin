package ap

import http "../http"
import "core:sync"
import "core:testing"

@(test)
access_point_response_preserves_priority_and_rejects_invalid_destinations :: proc(t: ^testing.T) {
	body := `{"accesspoint":["ap-one.spotify.com:4070","ap-two.spotify.com:443","ap-three.spotify.com:80"]}`
	addresses, ok := parse_access_points(transmute([]u8)body)
	testing.expect(t, ok && len(addresses) == 3)
	if !ok {return}
	testing.expect_value(t, addresses[0], "ap-one.spotify.com:4070")
	testing.expect_value(t, addresses[1], "ap-two.spotify.com:443")
	for invalid in ([]string{`{"accesspoint":[]}`, `{"accesspoint":["attacker.invalid:443"]}`, `{"accesspoint":["ap.spotify.com:22"]}`, `{"accesspoint":["127.0.0.1:443"]}`, `{"accesspoint":["ap.spotify.com"]}`, `{"accesspoint":["ap.spotify.com:443","bad"]}`, `{"accesspoint":"not an array"}`, `not json`}) {
		_, accepted := parse_access_points(transmute([]u8)invalid)
		testing.expect(t, !accepted)
	}
	cancelled := true
	_, result := connect(&cancelled)
	testing.expect_value(t, result, Resolve_Result.Cancelled)
	cancelled = false
	_, result = connect(
	&cancelled,
	proc(_: string, options: http.Options, _: rawptr) -> ([dynamic]u8, int, bool) {
		if options.cancel != nil {sync.atomic_store(options.cancel, true)}
		// The resolver must free even an interrupted response and never dial it.
		return make([dynamic]u8, 4), 200, true
	},
	)
	testing.expect(t, cancelled)
	testing.expect_value(t, result, Resolve_Result.Cancelled)
}
