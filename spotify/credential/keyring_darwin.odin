// Native Keychain access. Refresh tokens never enter process arguments.
package credential

import "core:strings"
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
	query := keychain_query(slot)
	if query == nil {return}
	defer cf.Release(query)
	CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue)
	data: cf.TypeRef
	if SecItemCopyMatching(query, &data) != security.OSStatus(security.errSec.Success) ||
	   data == nil {return}
	defer cf.Release(data)
	length := CFDataGetLength(data)
	if length <= 0 {return}
	bytes := CFDataGetBytePtr(data)
	if bytes == nil {return}
	return strings.clone(string(bytes[:length])), true
}

save :: proc(token: string, slot: Slot = .Playback) -> bool {
	if len(token) == 0 || strings.contains(token, "\x00") {return false}
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
	if status !=
	   security.OSStatus(
		   security.errSec.ItemNotFound,
	   ) {return status == security.OSStatus(security.errSec.Success)}
	CFDictionarySetValue(query, kSecValueData, data)
	CFDictionarySetValue(query, kSecAttrLabel, label)
	return SecItemAdd(query, nil) == security.OSStatus(security.errSec.Success)
}

clear :: proc(slot: Slot = .Playback) -> bool {
	query := keychain_query(slot)
	if query == nil {return false}
	defer cf.Release(query)
	return SecItemDelete(query) == security.OSStatus(security.errSec.Success)
}
