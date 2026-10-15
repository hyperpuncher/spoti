// Native now-playing integration. Linux speaks MPRIS over sd-bus; other
// platforms install no-op stubs until their own media APIs are wired in.
package mpris

Status :: struct {
	playing:      bool,
	shuffle:      bool,
	repeat:       bool,
	can_seek:     bool,
	can_next:     bool,
	can_previous: bool,
	volume:       f32,
}

Now_Playing :: struct {
	title:        string,
	artist:       string,
	duration_ms:  int,
	position_ms:  int,
	using status: Status,
}

// Remote control from the desktop shell or playerctl. Seek carries a relative
// offset; Set_Position carries an absolute position. Both are milliseconds.
Command :: enum {
	Play,
	Pause,
	Play_Pause,
	Stop,
	Next,
	Previous,
	Seek,
	Set_Position,
	Quit,
}

// Called from the service thread when a remote command needs the UI thread.
Wake :: proc "c" (userdata: rawptr)
