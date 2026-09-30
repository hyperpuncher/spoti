package session

import oauth "../oauth"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
streaming_grant_is_reused_with_independent_owned_copies :: proc(t: ^testing.T) {
	clear_authorization()
	defer clear_authorization()
	authorization_tokens = oauth.Tokens {
		access     = strings.clone("test-access"),
		refresh    = strings.clone("test-refresh"),
		expires_at = time.time_add(time.now(), time.Minute),
	}
	first, ok := authorize(.None)
	defer oauth.wipe_tokens(&first)
	testing.expect(t, ok)
	raw_data(first.access)[0] = 'X'
	second, reused := authorize(.None)
	defer oauth.wipe_tokens(&second)
	testing.expect(t, reused)
	testing.expect_value(t, second.access, "test-access")
	testing.expect_value(t, second.refresh, "test-refresh")
	testing.expect_value(t, second.expires_at, authorization_tokens.expires_at)
	cancel := true
	cancelled, accepted := authorize(.None, &cancel, force = true)
	defer oauth.wipe_tokens(&cancelled)
	testing.expect(t, !accepted && cancelled.access == "")
}
