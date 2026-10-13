package diagnostic

import "core:testing"

@(test)
rootlist_logging_never_keeps_an_account_name :: proc(t: ^testing.T) {
	endpoint, paging := sanitize_endpoint(
		"https://spclient.wg.spotify.com/playlist/v2/user/alice/rootlist?from=36&length=36",
	)
	defer {delete(endpoint); delete(paging)}
	testing.expect_value(t, endpoint, "spclient playlist-v2-user-rootlist")
	testing.expect_value(t, paging, " offset=36")
}
