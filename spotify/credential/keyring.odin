// Credential addresses stay the same across backend changes.
package credential

SERVICE :: "org.spoti.playback"

Slot :: enum {
	Playback,
	Library,
	Library_Client,
}

SLOTS := [Slot]struct {
	account, label, target: cstring,
} {
	.Playback       = {"playback", "spoti Spotify playback", "spoti/playback"},
	.Library        = {"library", "spoti Spotify library", "spoti/library"},
	.Library_Client = {"library_client", "spoti Spotify app ID", "spoti/library_client"},
}
