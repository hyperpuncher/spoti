package library

import oauth "../oauth"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
private_reads_reuse_only_their_worker_owned_streaming_grant :: proc(t: ^testing.T) {
	client: Client
	tokens := oauth.Tokens {
		access     = strings.clone("fake-streaming-grant"),
		refresh    = strings.clone("fake-streaming-refresh"),
		expires_at = time.time_add(time.now(), time.Minute),
	}
	defer oauth.wipe_tokens(&tokens)
	testing.expect(t, authorize_session(&client, &tokens))
	testing.expect_value(t, tokens.access, "fake-streaming-grant")
	client.cancel = true
	rows, _, _, _, status, ok := read_session_playlist(
		&client,
		&tokens,
		"unused",
		0,
		context.allocator,
	)
	testing.expect(t, !ok && rows == nil && status == PLAYLIST_AUTH_REQUIRED)
	testing.expect_value(t, tokens.refresh, "fake-streaming-refresh")
}
