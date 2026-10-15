#+build windows
package ui

import "base:runtime"
import "core:fmt"
import win "core:sys/windows"
import sdl "vendor:sdl3"

foreign import dwm "system:dwmapi.lib"
foreign import comctl "system:comctl32.lib"

foreign dwm {
	DwmDefWindowProc :: proc "system" (hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, result: ^win.LRESULT) -> win.BOOL ---
}
foreign comctl {
	GetWindowSubclass :: proc "system" (hwnd: win.HWND, callback: win.SUBCLASSPROC, id: win.UINT_PTR, data: ^win.DWORD_PTR) -> win.BOOL ---
	RemoveWindowSubclass :: proc "system" (hwnd: win.HWND, callback: win.SUBCLASSPROC, id: win.UINT_PTR) -> win.BOOL ---
}

windows_hwnd :: proc(window: ^sdl.Window) -> win.HWND {
	return win.HWND(
		sdl.GetPointerProperty(
			sdl.GetWindowProperties(window),
			sdl.PROP_WINDOW_WIN32_HWND_POINTER,
			nil,
		),
	)
}

extend_windows_frame :: proc(hwnd: win.HWND) {
	margins := win.MARGINS {
		cyTopHeight = win.INT(32 * win.GetDpiForWindow(hwnd) / 96),
	}
	_ = win.DwmExtendFrameIntoClientArea(hwnd, &margins)
}

windows_frame_proc :: proc "system" (
	hwnd: win.HWND,
	message: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
	id: win.UINT_PTR,
	data: win.DWORD_PTR,
) -> win.LRESULT {
	context = runtime.default_context()
	style := win.GetWindowLongPtrW(hwnd, win.GWL_STYLE)
	if message == win.WM_NCCALCSIZE && wparam != 0 && style & win.LONG_PTR(win.WS_CAPTION) != 0 {
		params := (^win.NCCALCSIZE_PARAMS)(uintptr(lparam))
		top := params.rgrc[0].top
		// Let SDL/Windows retain the side and bottom resize borders.
		_ = win.DefSubclassProc(hwnd, message, wparam, lparam)
		if win.IsZoomed(hwnd) {
			dpi := win.GetDpiForWindow(hwnd)
			top +=
				win.GetSystemMetricsForDpi(win.SM_CYSIZEFRAME, dpi) +
				win.GetSystemMetricsForDpi(win.SM_CXPADDEDBORDER, dpi)
		}
		params.rgrc[0].top = top
		return 0
	}
	if message == win.WM_ACTIVATE || message == win.WM_DPICHANGED {
		extend_windows_frame(hwnd)
	}
	if message == win.WM_NCDESTROY {
		_ = RemoveWindowSubclass(hwnd, windows_frame_proc, id)
	}
	result: win.LRESULT
	// DWM owns caption-button input, including the native maximise button.
	if DwmDefWindowProc(hwnd, message, wparam, lparam, &result) {return result}
	return win.DefSubclassProc(hwnd, message, wparam, lparam)
}

configure_windows_window :: proc(window: ^sdl.Window) {
	hwnd := windows_hwnd(window)
	if hwnd == nil {return}
	win.SetWindowSubclass(hwnd, windows_frame_proc, 1, 0)
	// The core setter omits its BOOL result; verify registration separately.
	data: win.DWORD_PTR
	if !GetWindowSubclass(hwnd, windows_frame_proc, 1, &data) {
		fmt.eprintln("could not integrate native window controls")
		return
	}
	extend_windows_frame(hwnd)
	_ = win.SetWindowPos(
		hwnd,
		nil,
		0,
		0,
		0,
		0,
		win.SWP_NOMOVE |
		win.SWP_NOSIZE |
		win.SWP_NOZORDER |
		win.SWP_NOACTIVATE |
		win.SWP_FRAMECHANGED,
	)
}

windows_caption_width :: proc(window: ^sdl.Window) -> f32 {
	hwnd := windows_hwnd(window)
	if win.GetWindowLongPtrW(hwnd, win.GWL_STYLE) & win.LONG_PTR(win.WS_CAPTION) == 0 {return 0}
	bounds: win.RECT
	// DWMWA_CAPTION_BUTTON_BOUNDS = 5, in window pixels.
	if win.DwmGetWindowAttribute(hwnd, 5, &bounds, size_of(bounds)) != 0 {return 0}
	return f32(max(0, bounds.right - bounds.left))
}

windows_frame_theme :: proc(window: ^sdl.Window, dark: bool) {
	value := win.BOOL(dark)
	// DWMWA_USE_IMMERSIVE_DARK_MODE = 20. Older Windows versions can ignore it.
	_ = win.DwmSetWindowAttribute(windows_hwnd(window), 20, &value, size_of(value))
}
