#+build darwin
package ui

import cocoa "core:sys/darwin/Foundation"
import sdl "vendor:sdl3"

foreign import objc "system:objc"
foreign objc {
	sel_registerName :: proc "c" (name: cstring) -> cocoa.SEL ---
	objc_msgSend :: proc "c" (object: cocoa.id, selector: cocoa.SEL, #c_vararg args: ..any) ---
}

Objc_Get_Integer :: #type proc "c" (object: cocoa.id, selector: cocoa.SEL) -> uintptr
Objc_Set_Integer :: #type proc "c" (object: cocoa.id, selector: cocoa.SEL, value: uintptr)
Objc_Set_Boolean :: #type proc "c" (object: cocoa.id, selector: cocoa.SEL, value: bool)

// Keep Cocoa's controls without replacing SDL's NSWindow or delegate.
// The current compiler asserts when generating intrinsics.objc_send, so
// use the Objective-C C ABI with signatures matching these NSWindow methods.
configure_macos_window :: proc(window: ^sdl.Window) {
	properties := sdl.GetWindowProperties(window)
	native := (cocoa.id)(
		sdl.GetPointerProperty(properties, sdl.PROP_WINDOW_COCOA_WINDOW_POINTER, nil),
	)
	if native == nil {return}
	get_integer := transmute(Objc_Get_Integer)objc_msgSend
	style := get_integer(native, sel_registerName("styleMask"))
	set_integer := transmute(Objc_Set_Integer)objc_msgSend
	set_boolean := transmute(Objc_Set_Boolean)objc_msgSend
	// NSWindowStyleMaskFullSizeContentView = 1 << 15; NSWindowTitleHidden = 1.
	set_integer(native, sel_registerName("setStyleMask:"), style | (1 << 15))
	set_integer(native, sel_registerName("setTitleVisibility:"), 1)
	set_boolean(native, sel_registerName("setTitlebarAppearsTransparent:"), true)
}
