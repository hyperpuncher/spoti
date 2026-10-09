package library

import "core:testing"

DEVICES_FIXTURE :: `{"devices":[
{"id":"74ASZWbe4lXaubB36ztrGX","is_active":false,"is_private_session":false,"is_restricted":false,"name":"Kitchen speaker","type":"speaker","volume_percent":59,"supports_volume":true},
{"id":"0d1841b0976bae2a3a310dd74c0f3df354899bc8","is_active":true,"is_private_session":false,"is_restricted":true,"name":"Phone","type":"smartphone","volume_percent":null,"supports_volume":false},
{"id":"bad\"id","is_active":false,"name":"Junk","type":"computer"}
]}`

@(test)
devices_parse_keeps_valid_entries_with_volume_fallback :: proc(t: ^testing.T) {
	body := DEVICES_FIXTURE
	devices, ok := parse_devices(transmute([]u8)body)
	defer free_devices(devices)
	testing.expect(t, ok)
	testing.expect_value(t, len(devices), 2)
	testing.expect_value(t, devices[0].name, "Kitchen speaker")
	testing.expect_value(t, devices[0].volume, 59)
	testing.expect(t, !devices[0].active)
	testing.expect(t, devices[1].active)
	testing.expect(t, devices[1].restricted)
	testing.expect_value(t, devices[1].volume, -1)
	bogus := `{"devices":"nope"}`
	_, ok = parse_devices(transmute([]u8)bogus)
	testing.expect(t, !ok)
	testing.expect(t, !valid_device_id(""))
	testing.expect(t, !valid_device_id("bad\"id"))
}

PLAYER_FIXTURE :: `{"device":{"id":"74ASZWbe4lXaubB36ztrGX","is_active":true,"name":"Kitchen speaker","type":"speaker","volume_percent":59},"is_playing":true,"progress_ms":61234}`

@(test)
player_parse_reads_playing_progress_and_device :: proc(t: ^testing.T) {
	body := PLAYER_FIXTURE
	state, ok := parse_player_state(transmute([]u8)body)
	defer free_player_state(state)
	testing.expect(t, ok)
	testing.expect(t, state.playing)
	testing.expect_value(t, state.progress, 61234)
	testing.expect_value(t, state.device, "Kitchen speaker")
	idle := `{"is_playing":false}`
	_, ok = parse_player_state(transmute([]u8)idle)
	testing.expect(t, !ok, "a payload without an active device fails")
}
