#+build linux, darwin
package session

import "core:net"
import posix "core:sys/posix"

// Readability check for the keep-alive loop. A failed poll reads as
// not-ready and the loop retries in 100 ms.
socket_readable :: proc(socket: net.TCP_Socket) -> bool {
	fds := [1]posix.pollfd{{fd = posix.FD(socket), events = {.IN}}}
	return posix.poll(raw_data(fds[:]), 1, 0) > 0
}
