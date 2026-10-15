#+build darwin
package credential

import cf "core:sys/darwin/CoreFoundation"
import "core:testing"

foreign import foundation "system:CoreFoundation.framework"
foreign foundation {
	CFDictionaryGetValue :: proc "c" (dictionary, key: cf.TypeRef) -> cf.TypeRef ---
}

@(test)
keychain_queries_keep_the_existing_service_and_accounts :: proc(t: ^testing.T) {
	// Core Foundation objects only. Never read or change the user's Keychain.
	accounts := [Slot]string {
		.Playback       = "playback",
		.Library        = "library",
		.Library_Client = "library_client",
	}
	for account, slot in accounts {
		query := keychain_query(slot)
		if !testing.expect(t, query != nil) {continue}
		defer cf.Release(query)
		for attribute in ([]struct {
				key:      cf.TypeRef,
				expected: string,
			}{{kSecAttrService, "org.spoti.playback"}, {kSecAttrAccount, account}}) {
			value := CFDictionaryGetValue(query, attribute.key)
			if !testing.expect(t, value != nil) {continue}
			buffer: [128]u8
			if !testing.expect(
				t,
				bool(
					cf.StringGetCString(
						cf.String(value),
						raw_data(buffer[:]),
						cf.Index(len(buffer)),
						cf.StringEncoding(cf.StringBuiltInEncodings.UTF8),
					),
				),
			) {continue}
			testing.expect_value(t, string(cstring(raw_data(buffer[:]))), attribute.expected)
		}
	}
}
