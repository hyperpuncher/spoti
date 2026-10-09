package library

import "core:testing"

@(test)
commands_build_valid_addresses_and_reject_bad_values :: proc(t: ^testing.T) {
	address, ok := command_address(.Pause)
	defer delete(address)
	testing.expect(t, ok && address == PAUSE_ADDRESS)
	testing.expect_value(t, command_method(.Next), "POST")
	testing.expect_value(t, command_method(.Pause), "PUT")
	seek, seek_ok := command_address(.Seek, 25000)
	defer delete(seek)
	testing.expect(
		t,
		seek_ok && seek == "https://api.spotify.com/v1/me/player/seek?position_ms=25000",
	)
	volume, volume_ok := command_address(.Volume, 59)
	defer delete(volume)
	testing.expect(
		t,
		volume_ok && volume == "https://api.spotify.com/v1/me/player/volume?volume_percent=59",
	)
	shuffle, shuffle_ok := command_address(.Shuffle, 1)
	defer delete(shuffle)
	testing.expect(
		t,
		shuffle_ok && shuffle == "https://api.spotify.com/v1/me/player/shuffle?state=true",
	)
	repeat, repeat_ok := command_address(.Repeat, 0, "context")
	defer delete(repeat)
	testing.expect(
		t,
		repeat_ok && repeat == "https://api.spotify.com/v1/me/player/repeat?state=context",
	)
	_, ok = command_address(.Seek, -1)
	testing.expect(t, !ok)
	_, ok = command_address(.Volume, 101)
	testing.expect(t, !ok)
	_, ok = command_address(.Shuffle, 2)
	testing.expect(t, !ok)
	_, ok = command_address(.Repeat, 0, "everything")
	testing.expect(t, !ok)
}
