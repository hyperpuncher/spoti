package main

import "core:strings"
import "core:testing"

@(test)
copy_feedback_replaces_the_previous_toast_and_requests_a_frame :: proc(t: ^testing.T) {
	app := App {
		toast = strings.clone("Previous action"),
	}
	defer delete(app.toast)
	show_toast(&app, "Link copied")
	testing.expect_value(t, app.toast, "Link copied")
	testing.expect(t, app.pending_redraw)
	testing.expect(t, app.toast_until > 0)

	app.pending_redraw = false
	// This collection has no web URL. No desktop clipboard call is made.
	copy_link(&app, "spotify:collection:tracks")
	testing.expect_value(t, app.toast, "Could not copy link")
	testing.expect(t, app.pending_redraw)
}
