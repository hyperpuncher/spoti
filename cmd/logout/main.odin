package main

import credential "../../spotify/credential"
import "core:fmt"

main :: proc() {
	playback := credential.clear()
	library := credential.clear(.Library)
	if playback || library {
		fmt.println("saved Spotify sign-in removed from the system keyring")
	} else {
		fmt.eprintln(
			"no saved sign-in removed; unlock your system keyring and try again if needed",
		)
	}
}
