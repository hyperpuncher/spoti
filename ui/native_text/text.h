#ifndef SPOTI_TEXT_H
#define SPOTI_TEXT_H

#include <stdint.h>
#include <limits.h>
#include <stdlib.h>
#include <math.h>

#ifdef __cplusplus
extern "C" {
#endif

// One engine per owner thread. Layouts borrow the engine and own their text.
// All positions are drawable pixels. Editing offsets are UTF-8 byte offsets.
typedef struct St_Engine St_Engine;
typedef struct St_Layout St_Layout;
typedef struct { float x, y, width, height; } St_Rect;
typedef struct {
	float width, height, baseline;
	St_Rect ink;
} St_Metrics;
typedef struct {
	uint8_t *pixels; // owned, native-endian premultiplied ARGB32
	int width, height, stride, x, y;
} St_Image;

St_Engine *st_open(const char *font_path);
void st_close(St_Engine *engine);
St_Layout *st_layout(St_Engine *engine, const char *text, int length, float size, int weight);
void st_destroy(St_Layout *layout);
St_Metrics st_metrics(St_Layout *layout);
// Returns the retained UTF-8 prefix, or -1 if even the ellipsis does not fit.
int st_fit(St_Layout *layout, float width);
float st_cursor(St_Layout *layout, int index);
int st_hit(St_Layout *layout, float x, int nearest);
// Returns the required count; copies up to capacity disjoint visual rectangles.
int st_selection(St_Layout *layout, int start, int end, St_Rect *rects, int capacity);
St_Image st_render(St_Layout *layout, uint8_t r, uint8_t g, uint8_t b);
void st_free_image(St_Image image);

#ifdef __cplusplus
}
#endif

// Limit any one raster allocation to 64 MiB, including overflow checks.
static inline St_Image st_image(St_Rect ink) {
	St_Image image = {NULL, 0, 0, 0, 0, 0};
	if (!isfinite(ink.x) || !isfinite(ink.y) || !isfinite(ink.width) || !isfinite(ink.height) ||
		ink.width <= 0 || ink.height <= 0 || ink.width > 16382 || ink.height > 16382 ||
		fabsf(ink.x) > (float)(INT_MAX / 2) || fabsf(ink.y) > (float)(INT_MAX / 2)) return image;
	image.x = (int)floorf(ink.x) - 1;
	image.y = (int)floorf(ink.y) - 1;
	image.width = (int)ceilf(ink.x + ink.width) - image.x + 1;
	image.height = (int)ceilf(ink.y + ink.height) - image.y + 1;
	if ((size_t)image.width * image.height > 16 * 1024 * 1024) return image;
	image.stride = image.width * 4;
	image.pixels = (uint8_t *)calloc(image.height, image.stride);
	return image;
}

#if defined(_WIN32) || defined(__APPLE__)
// Inputs were already validated by the platform UTF-8 decoder. Keep one common
// mapping between its UTF-16 indices and the editor's UTF-8 byte offsets.
static inline int st_units(const char *text, int length, int bytes) {
	int units = 0;
	for (int i = 0; i < length && i < bytes;) {
		unsigned char c = (unsigned char)text[i];
		int n = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
		if (i + n > bytes) break;
		i += n;
		units += n == 4 ? 2 : 1;
	}
	return units;
}
static inline int st_bytes(const char *text, int length, int units) {
	int i = 0, used = 0;
	while (i < length && used < units) {
		unsigned char c = (unsigned char)text[i];
		int n = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
		int count = n == 4 ? 2 : 1;
		if (used + count > units) break;
		used += count;
		i += n;
	}
	return i;
}
#endif
#endif
