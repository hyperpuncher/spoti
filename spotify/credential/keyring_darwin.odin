// Native Keychain access. Refresh tokens never enter process arguments.
package credential

import "core:crypto"
import "core:strings"
import "core:sync"
import cf "core:sys/darwin/CoreFoundation"
import security "core:sys/darwin/Security"

foreign import keychain "system:Security.framework"
foreign import foundation "system:CoreFoundation.framework"

CF_Key_Callbacks :: struct {
	version:                                int,
	retain, release, describe, equal, hash: rawptr,
}
CF_Value_Callbacks :: struct {
	version:                          int,
	retain, release, describe, equal: rawptr,
}

@(default_calling_convention = "c")
foreign foundation {
	kCFTypeDictionaryKeyCallBacks: CF_Key_Callbacks
	kCFTypeDictionaryValueCallBacks: CF_Value_Callbacks
	kCFBooleanTrue, kCFAllocatorNull: cf.TypeRef
	CFDictionaryCreateMutable :: proc(allocator: cf.TypeRef, capacity: int, keys: ^CF_Key_Callbacks, values: ^CF_Value_Callbacks) -> cf.TypeRef ---
	CFDictionarySetValue :: proc(dictionary, key, value: cf.TypeRef) ---
	CFStringCreateWithCString :: proc(allocator: cf.TypeRef, value: cstring, encoding: u32) -> cf.TypeRef ---
	CFDataCreateWithBytesNoCopy :: proc(allocator: cf.TypeRef, bytes: [^]u8, length: int, deallocator: cf.TypeRef) -> cf.TypeRef ---
	CFDataGetLength :: proc(data: cf.TypeRef) -> int ---
	CFDataGetBytePtr :: proc(data: cf.TypeRef) -> [^]u8 ---
}

@(default_calling_convention = "c")
foreign keychain {
	kSecClass, kSecClassGenericPassword, kSecAttrService, kSecAttrAccount: cf.TypeRef
	kSecAttrLabel, kSecReturnData, kSecValueData: cf.TypeRef
	SecItemCopyMatching :: proc(query: cf.TypeRef, result: ^cf.TypeRef) -> security.OSStatus ---
	SecItemUpdate :: proc(query, attributes: cf.TypeRef) -> security.OSStatus ---
	SecItemAdd :: proc(attributes: cf.TypeRef, result: ^cf.TypeRef) -> security.OSStatus ---
	SecItemDelete :: proc(query: cf.TypeRef) -> security.OSStatus ---
}

// Startup authorizes playback and library work on separate workers. Without
// this cache every worker read opens another Keychain permission dialog.
KEYCHAIN_OK :: security.OSStatus(security.errSec.Success)
KEYCHAIN_MISSING :: security.OSStatus(security.errSec.ItemNotFound)

keychain_cache: [Slot]string // owned; empty means no cached credential
keychain_mutex: sync.Mutex

keychain_clear_entry :: proc(entry: ^string) {
	crypto.zero_explicit(raw_data(entry^), len(entry^))
	delete(entry^)
	entry^ = ""
}

keychain_set_entry :: proc(entry: ^string, token: string) {
	keychain_clear_entry(entry)
	entry^ = strings.clone(token)
}

keychain_query :: proc(slot: Slot) -> cf.TypeRef {
	service := CFStringCreateWithCString(nil, SERVICE, u32(cf.StringBuiltInEncodings.UTF8))
	if service == nil {return nil}
	defer cf.Release(service)
	account := CFStringCreateWithCString(
		nil,
		SLOTS[slot].account,
		u32(cf.StringBuiltInEncodings.UTF8),
	)
	if account == nil {return nil}
	defer cf.Release(account)
	query := CFDictionaryCreateMutable(
		nil,
		0,
		&kCFTypeDictionaryKeyCallBacks,
		&kCFTypeDictionaryValueCallBacks,
	)
	if query == nil {return nil}
	CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword)
	CFDictionarySetValue(query, kSecAttrService, service)
	CFDictionarySetValue(query, kSecAttrAccount, account)
	return query
}

load :: proc(slot: Slot = .Playback) -> (token: string, found: bool) {
	sync.mutex_lock(&keychain_mutex)
	defer sync.mutex_unlock(&keychain_mutex)
	entry := &keychain_cache[slot]
	if len(entry^) > 0 {return strings.clone(entry^), true}
	query := keychain_query(slot)
	if query == nil {return}
	defer cf.Release(query)
	CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue)
	data: cf.TypeRef
	if SecItemCopyMatching(query, &data) != KEYCHAIN_OK || data == nil {return}
	defer cf.Release(data)
	length := CFDataGetLength(data)
	bytes := length > 0 ? CFDataGetBytePtr(data) : nil
	if bytes == nil {return}
	keychain_set_entry(entry, string(bytes[:length]))
	return strings.clone(entry^), true
}

save :: proc(token: string, slot: Slot = .Playback) -> bool {
	if len(token) == 0 || strings.contains(token, "\x00") {return false}
	sync.mutex_lock(&keychain_mutex)
	defer sync.mutex_unlock(&keychain_mutex)
	entry := &keychain_cache[slot]
	query := keychain_query(slot)
	if query == nil {return false}
	defer cf.Release(query)
	// The synchronous call borrows the caller's bytes instead of making an
	// extra secret copy. Core Foundation must not free that borrowed memory.
	data := CFDataCreateWithBytesNoCopy(nil, raw_data(token), len(token), kCFAllocatorNull)
	if data == nil {return false}
	defer cf.Release(data)
	label := CFStringCreateWithCString(nil, SLOTS[slot].label, u32(cf.StringBuiltInEncodings.UTF8))
	if label == nil {return false}
	defer cf.Release(label)
	attributes := CFDictionaryCreateMutable(
		nil,
		0,
		&kCFTypeDictionaryKeyCallBacks,
		&kCFTypeDictionaryValueCallBacks,
	)
	if attributes == nil {return false}
	defer cf.Release(attributes)
	CFDictionarySetValue(attributes, kSecValueData, data)
	CFDictionarySetValue(attributes, kSecAttrLabel, label)
	status := SecItemUpdate(query, attributes)
	if status == KEYCHAIN_MISSING {
		CFDictionarySetValue(query, kSecValueData, data)
		CFDictionarySetValue(query, kSecAttrLabel, label)
		status = SecItemAdd(query, nil)
	}
	if status != KEYCHAIN_OK {return false}
	keychain_set_entry(entry, token)
	return true
}

clear :: proc(slot: Slot = .Playback) -> bool {
	sync.mutex_lock(&keychain_mutex)
	defer sync.mutex_unlock(&keychain_mutex)
	entry := &keychain_cache[slot]
	query := keychain_query(slot)
	if query == nil {return false}
	defer cf.Release(query)
	status := SecItemDelete(query)
	if status != KEYCHAIN_OK && status != KEYCHAIN_MISSING {return false}
	keychain_clear_entry(entry)
	return true
}
