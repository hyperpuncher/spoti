// Clay has no built-in scrollbar. Each scrolling container gets a floating
// thumb sized and positioned from its live scroll data, then dragged in main.
package main

import clay "vendor/clay"

SCROLLBAR :: clay.Color{120, 120, 126, 170}
SCROLLBAR_HOVER :: clay.Color{170, 170, 176, 210}
SCROLLBAR_WIDTH :: 6
SCROLLBAR_MARGIN :: 2

Scrollbar_Drag :: struct {
	container: string, // empty when no drag is active
	grab:      f32,
	origin:    f32,
}

scrollbar_metrics :: proc(
	scroll_y, content_height, viewport_height, min_thumb, margin: f32,
) -> (
	thumb, offset: f32,
	visible: bool,
) {
	if viewport_height <= 0 || content_height <= viewport_height {return 0, 0, false}
	thumb = clamp(viewport_height * viewport_height / content_height, min_thumb, viewport_height)
	travel := viewport_height - thumb - 2 * margin
	progress := clamp(-scroll_y / (content_height - viewport_height), 0, 1)
	return thumb, margin + progress * travel, true
}

scrollbar :: proc(container, name: string, d: f32) {
	data := clay.GetScrollContainerData(clay.ID(container))
	if !data.found || data.scrollPosition == nil {return}
	thumb, offset, visible := scrollbar_metrics(
		data.scrollPosition.y,
		data.contentDimensions.height,
		data.scrollContainerDimensions.height,
		24 * d,
		2 * d,
	)
	if !visible {return}
	if clay.UI_WithId(clay.ID(name))(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(SCROLLBAR_WIDTH * d),
				height = clay.SizingFixed(thumb),
			},
		},
		floating = {
			offset = {(SCROLLBAR_WIDTH + SCROLLBAR_MARGIN) * d, offset},
			zIndex = 1,
			parentId = clay.ID(container).id,
			attachment = {element = .RightTop, parent = .RightTop},
			attachTo = .ElementWithId,
		},
		backgroundColor = clay.PointerOver(clay.ID(name)) ? SCROLLBAR_HOVER : SCROLLBAR,
		cornerRadius = clay.CornerRadiusAll(f32(SCROLLBAR_WIDTH) / 2 * d),
	},
	) {}
}

// Grabbing records the scroll offset so motion stays relative after clamping.
begin_scrollbar_drag :: proc(drag: ^Scrollbar_Drag, container: string, mouse_y: f32) {
	data := clay.GetScrollContainerData(clay.ID(container))
	if !data.found || data.scrollPosition == nil {return}
	drag^ = {
		container = container,
		grab      = mouse_y,
		origin    = data.scrollPosition.y,
	}
}

drag_scrollbar :: proc(drag: ^Scrollbar_Drag, mouse_y, d: f32) -> bool {
	data := clay.GetScrollContainerData(clay.ID(drag.container))
	if !data.found || data.scrollPosition == nil {return false}
	viewport := data.scrollContainerDimensions.height
	content := data.contentDimensions.height
	if viewport <= 0 || content <= viewport {return false}
	ratio := content / viewport
	minimum := -(content - viewport)
	data.scrollPosition.y = clamp(drag.origin + (drag.grab - mouse_y) / d * ratio, minimum, 0)
	return true
}
