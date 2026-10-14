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
	ctx := Context {
		pages = {
			{
				tracks = {
					{uri = "spotify:track:0000000000000000000000"},
					{uri = "spotify:track:0000000000000000000001"},
					{uri = "spotify:track:0000000000000000000003"},
				},
			},
		},
	}
	append_context(&event, ctx)
	if testing.expect_value(t, len(event.tracks), 3) {
		testing.expect_value(t, event.tracks[0], "spotify:track:0000000000000000000001")
		testing.expect_value(t, event.tracks[1], "spotify:track:0000000000000000000002")
		testing.expect_value(t, event.tracks[2], "spotify:track:0000000000000000000003")
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
dealer_payload_detects_gzip_without_a_header :: proc(t: ^testing.T) {
	// Odin's gzip fixture includes optional header fields and a valid checksum.
	encoded := "H4sIHMs7OloCAwcAYWIDAGNkZWZpbGVuYW1lAFRoaXMgaXMgYSBjb21tZW50ACtIrMzJT0wBABVqLEIHAAAA"
	data, zipped, ok := dealer_payload(encoded)
	testing.expect(t, ok && zipped)
	testing.expect_value(t, string(data), "payload")
	plain, plain_gzip, plain_ok := dealer_payload("e30=")
	testing.expect(t, plain_ok && !plain_gzip && string(plain) == "{}")
	_, _, invalid_ok := dealer_payload("!")
	testing.expect(t, !invalid_ok)
	_, _, truncated_ok := dealer_payload(encoded[:len(encoded) - 4])
	testing.expect(t, !truncated_ok)
}

@(test)
transport_commands_accept_optional_dealer_metadata :: proc(t: ^testing.T) {
	fixtures := []struct {
		body:   string,
		action: Action,
	} {
		{
			`{"message_id":null,"sent_by_device_id":null,"command":{"endpoint":"pause","value":null}}`,
			.Pause,
		},
		{
			`{"message_id":"42","command":{"endpoint":"resume","context":"opaque","options":{"seek_to":null,"initially_paused":null,"skip_to":null}}}`,
			.Resume,
		},
		{`{"command":{"endpoint":"skip_next","track":null}}`, .Next},
		{`{"command":{"endpoint":"skip_prev","logging_params":null}}`, .Previous},
	}
	for fixture in fixtures {
		event, request, ok := parse_command(transmute([]u8)fixture.body)
		defer free_event(event)
		testing.expect(t, ok)
		testing.expect_value(t, event.action, fixture.action)
		if fixture.action ==
		   .Resume {testing.expect_value(t, request_message_id(request), u32(42))}
	}
}

@(test)
connect_state_reports_shuffle_with_the_rebuilt_queue :: proc(t: ^testing.T) {
	tracks := make([dynamic]string, 0, 3)
	append(&tracks, "spotify:track:0000000000000000000001")
	append(&tracks, "spotify:track:0000000000000000000002")
	append(&tracks, "spotify:track:0000000000000000000003")
	defer delete(tracks)
	snapshot := Snapshot {
		uri            = tracks[1],
		context_uri    = "spotify:album:AAAAAAAAAAAAAAAAAAAAAA",
		tracks         = tracks,
		index          = 1,
		queue_revision = 42,
		active         = true,
		playing        = true,
		shuffle        = true,
	}
	state := encode_state("device", "session", snapshot, 4, "sender", 7)
	defer delete(state)
	device, _, device_valid := ap.get_bytes(state[:], 2)
	player, _, player_valid := ap.get_bytes(device, 2)
	options, _, options_valid := ap.get_bytes(player, 16)
	shuffle, _, shuffle_valid := ap.get_number(options, 1)
	index, _, index_valid := ap.get_bytes(player, 6)
	track, _, track_valid := ap.get_number(index, 2)
	previous, _, previous_valid := ap.get_bytes(player, 19)
	previous_uri, _, previous_uri_valid := ap.get_bytes(previous, 1)
	next, _, next_valid := ap.get_bytes(player, 20)
	next_uri, _, next_uri_valid := ap.get_bytes(next, 1)
	revision, _, revision_valid := ap.get_bytes(player, 24)
	testing.expect(t, device_valid && player_valid && options_valid)
	testing.expect(t, shuffle_valid && shuffle == 1)
	testing.expect(t, index_valid && track_valid && track == 1)
	testing.expect(t, previous_valid && previous_uri_valid && string(previous_uri) == tracks[0])
	testing.expect(t, next_valid && next_uri_valid && string(next_uri) == tracks[2])
	testing.expect(t, revision_valid && string(revision) == "42")
}

@(test)
partial_options_do_not_clear_unrelated_modes :: proc(t: ^testing.T) {
	body := `{"command":{"endpoint":"set_options","repeating_track":false}}`
	event, _, ok := parse_command(transmute([]u8)body)
	defer free_event(event)
	testing.expect(t, ok && event.set_repeat_track && !event.repeat_track)
	testing.expect(t, !event.set_shuffle && !event.set_repeat_context)
}
