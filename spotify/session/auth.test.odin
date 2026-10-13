package session

import oauth "../oauth"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
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
	// A second startup worker must wait for the grant owner, not report
	// that streaming approval is missing and select an incomplete list.
	Waiting :: struct {
		started, accepted: bool,
	}
	waiting: Waiting
	sync.lock(&authorization_mutex)
	worker := thread.create_and_start_with_data(&waiting, proc(pointer: rawptr) {
		result := (^Waiting)(pointer)
		sync.atomic_store(&result.started, true)
		tokens, ok := authorize(.None, interactive = false)
		result.accepted = ok && tokens.access == "test-access"
		oauth.wipe_tokens(&tokens)
	})
	if !testing.expect(t, worker != nil) {sync.unlock(&authorization_mutex); return}
	for !sync.atomic_load(&waiting.started) {time.sleep(time.Millisecond)}
	time.sleep(30 * time.Millisecond)
	sync.unlock(&authorization_mutex)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect(t, waiting.accepted)

	cancel := true
	cancelled, accepted := authorize(.None, &cancel, force = true)
	defer oauth.wipe_tokens(&cancelled)
	testing.expect(t, !accepted && cancelled.access == "")
}
