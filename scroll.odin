package main

import clay "vendor/clay"

// One glide target per scroll container. Wheel ticks are sparse (a mouse
// detent is roughly one event) while frames are cheap, so the wheel only
// moves the target and each frame eases the real offset toward it.
Smooth :: struct {
	target: f32,
	active: bool,
}

// Wheel glides. The order is the wheel priority: popovers before the queue
// panel before the page.
Scroll_Area :: enum {
	Device_Picker,
	Playlist_Picker,
	Queue,
	Grid,
	Detail,
}

SCROLL_AREA_ID := [Scroll_Area]string {
	.Device_Picker   = "device_picker",
	.Playlist_Picker = "playlist_picker",
	.Queue           = "queue_rows",
	.Grid            = "library_grid",
	.Detail          = "detail_rows",
}

// Stop the glide on a container a drag or autoscroll now drives.
smooth_cancel_id :: proc(smooth: ^[Scroll_Area]Smooth, container: string) {
	for id, area in SCROLL_AREA_ID {
		if id == container {smooth_cancel(id, &smooth[area])}
	}
}

// Live detail_rows offset for history saves; zero when the page is closed.
detail_scroll_y :: proc() -> f32 {
	data := clay.GetScrollContainerData(clay.ID("detail_rows"))
	if !data.found || data.scrollPosition == nil {return 0}
	return data.scrollPosition.y
}

SCROLL_WHEEL_STEP :: 120.0

scroll_wheel :: proc(id: string, amount, d: f32, smooth: ^Smooth) -> bool {
	if amount == 0 || !pointer_over(id) {return false}
	scroll := clay.GetScrollContainerData(clay.ID(id))
	if !scroll.found || scroll.scrollPosition == nil {return false}
	if !smooth.active {
		smooth.target = scroll.scrollPosition.y
		smooth.active = true
	}
	minimum := min(
		f32(0),
		scroll.scrollContainerDimensions.height - scroll.contentDimensions.height,
	)
	smooth.target = clamp(smooth.target + amount * SCROLL_WHEEL_STEP * d, minimum, 0)
	return true
}

// One easing step toward the wheel target. Clamps every frame so content
// loads and view switches self-heal instead of whooshing to stale offsets.
SMOOTH_SNAP :: 0.5
SMOOTH_RATE :: 14.0

smooth_step :: proc(container: string, smooth: ^Smooth, dt: f32) -> bool {
	if !smooth.active {return false}
	data := clay.GetScrollContainerData(clay.ID(container))
	if !data.found || data.scrollPosition == nil {
		smooth.active = false
		return false
	}
	viewport := data.scrollContainerDimensions.height
	content := data.contentDimensions.height
	if viewport <= 0 || content <= viewport {
		smooth.active = false
		return false
	}
	minimum := viewport - content
	smooth.target = clamp(smooth.target, minimum, 0)
	next :=
		data.scrollPosition.y + (smooth.target - data.scrollPosition.y) * min(1, dt * SMOOTH_RATE)
	if abs(smooth.target - next) <= SMOOTH_SNAP {
		next = smooth.target
		smooth.active = false
	}
	data.scrollPosition.y = next
	return true
}

// Direct offset writes (drag, autoscroll) cancel the glide so they never
// fight it; the target re-arms from the new position on the next tick.
smooth_active :: proc(smooth: ^[Scroll_Area]Smooth) -> bool {
	for glide in smooth {if glide.active {return true}}
	return false
}

smooth_cancel :: proc(container: string, smooth: ^Smooth) {
	data := clay.GetScrollContainerData(clay.ID(container))
	if data.found && data.scrollPosition != nil {smooth.target = data.scrollPosition.y}
	smooth.active = false
}

// Middle-click autoscroll: the button parks an anchor, steering away scrolls
// with a velocity proportional to the distance, another click exits.
AUTOSCROLL_DEADZONE :: 10.0
AUTOSCROLL_SPEED :: 30.0

// Signed scroll px for this frame; zero inside the dead zone. Pure for tests.
autoscroll_delta :: proc(dy, dt, d: f32) -> f32 {
	remaining := abs(dy) - AUTOSCROLL_DEADZONE * d
	if remaining <= 0 || dt <= 0 {return 0}
	step := remaining * AUTOSCROLL_SPEED * min(dt, 0.1)
	return dy > 0 ? -step : step
}

autoscroll_step :: proc(container: string, dy, dt, d: f32) -> bool {
	data := clay.GetScrollContainerData(clay.ID(container))
	if !data.found || data.scrollPosition == nil {return false}
	viewport := data.scrollContainerDimensions.height
	content := data.contentDimensions.height
	if viewport <= 0 || content <= viewport {return false}
	delta := autoscroll_delta(dy, dt, d)
	if delta == 0 {return false}
	data.scrollPosition.y = clamp(data.scrollPosition.y + delta, viewport - content, 0)
	return true
}
