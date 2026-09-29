// Credential-free Spotify access-point handshake diagnostic.
// Sends no username, token, or password. This is not an audio player.
package main

import ap "../../spotify/ap"
import "core:crypto"
import "core:fmt"
import "core:net"
import "core:time"

main :: proc() {
	socket, err := net.dial_tcp("ap.spotify.com:443")
	if err != nil {
		fmt.eprintln("could not reach Spotify access point:", err)
		return
	}
	defer net.close(socket)
	_ = net.set_option(socket, .Receive_Timeout, time.Duration(5 * time.Second))
	_ = net.set_option(socket, .Send_Timeout, time.Duration(5 * time.Second))
	keys, status := ap.handshake(socket)
	defer crypto.zero_explicit(&keys, size_of(keys))
	if status != .None {fmt.eprintln("AP handshake failed:", status); return}
	fmt.println("AP handshake sent; no Spotify login or playback yet")
}
