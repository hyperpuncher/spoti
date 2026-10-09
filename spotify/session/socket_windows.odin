package session

import "core:net"
import win "core:sys/windows"

// Readability check for the keep-alive loop. Winsock select with a zero
// timeout; a failed check reads as not-ready and the loop retries in 100 ms.
socket_readable :: proc(socket: net.TCP_Socket) -> bool {
	set := win.fd_set{}
	set.fd_count = 1
	set.fd_array[0] = win.SOCKET(socket)
	wait := win.timeval{}
	return win.select(0, &set, nil, nil, &wait) > 0
}
