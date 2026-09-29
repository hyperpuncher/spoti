// Explicit, credential-free-output login + first-range diagnostic.
package main

import session "../../spotify/session"

main :: proc() {
	source, ok := session.open()
	if !ok {return}
	defer session.close_source(&source)
	session.probe(&source)
}
