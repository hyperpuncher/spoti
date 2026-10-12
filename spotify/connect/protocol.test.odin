package connect

import ap "../ap"
import "core:testing"

@(test)
transfer_retains_position_pause_and_queued_tracks :: proc(t: ^testing.T) {
	current := make([dynamic]u8)
	defer delete(current)
	put_string(&current, 1, "spotify:track:0000000000000000000001")
	playback := make([dynamic]u8)
	defer delete(playback)
	ap.put_number(&playback, 2, 42000)
	ap.put_number(&playback, 4, 1)
	ap.put_bytes(&playback, 5, current[:])
	queued := make([dynamic]u8)
	defer delete(queued)
	put_string(&queued, 1, "spotify:track:0000000000000000000002")
	queue := make([dynamic]u8)
	defer delete(queue)
	ap.put_bytes(&queue, 1, queued[:])
	body := make([dynamic]u8)
	defer delete(body)
	ap.put_bytes(&body, 2, playback[:])
	ap.put_bytes(&body, 4, queue[:])
	event, ok := parse_transfer(body[:])
	defer free_event(event)
	testing.expect(t, ok && event.action == .Load && event.paused)
	testing.expect_value(t, event.position, 42000)
	if testing.expect_value(t, len(event.tracks), 2) {
		testing.expect_value(t, event.tracks[0], "spotify:track:0000000000000000000001")
		testing.expect_value(t, event.tracks[1], "spotify:track:0000000000000000000002")
	}
	_, broken := parse_transfer(body[:len(body) - 1])
	testing.expect(t, !broken, "truncated transfers must fail without a partial event")
	_, empty := parse_transfer(nil)
	testing.expect(t, !empty)
}

@(test)
play_command_selects_the_requested_uid_without_replaying_previous_tracks :: proc(t: ^testing.T) {
	body := `{"message_id":4,"sent_by_device_id":"fixture","command":{"endpoint":"play","context":{"pages":[{"tracks":[{"uri":"spotify:track:0000000000000000000001","uid":"first"},{"uri":"spotify:track:0000000000000000000002","uid":"second"}]}]},"options":{"skip_to":{"track_uid":"second"},"seek_to":3200}}}`
	event, _, ok := parse_command(transmute([]u8)body)
	defer free_event(event)
	testing.expect(t, ok)
	testing.expect_value(t, event.position, 3200)
	if testing.expect_value(
		t,
		len(event.tracks),
		1,
	) {testing.expect_value(t, event.tracks[0], "spotify:track:0000000000000000000002")}
	unknown := `{"command":{"endpoint":"not_implemented"}}`
	_, _, accepted := parse_command(transmute([]u8)unknown)
	testing.expect(t, !accepted)
}

@(test)
partial_options_do_not_clear_unrelated_modes :: proc(t: ^testing.T) {
	body := `{"command":{"endpoint":"set_options","repeating_track":false}}`
	event, _, ok := parse_command(transmute([]u8)body)
	defer free_event(event)
	testing.expect(t, ok && event.set_repeat_track && !event.repeat_track)
	testing.expect(t, !event.set_shuffle && !event.set_repeat_context)
}
