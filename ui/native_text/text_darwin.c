#include "text.h"
#include <CoreText/CoreText.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <string.h>
#include <stdbool.h>

struct St_Engine { CTFontDescriptorRef descriptor; };
typedef struct { CTLineRef value; CFRange range; float baseline, height; } St_Line;
struct St_Layout {
	CFAttributedStringRef text;
	char *utf8;
	int length, count;
	St_Line *lines;
	St_Metrics metrics;
};

St_Engine *st_open(const char *path) {
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
	if (!url) return NULL;
	CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromURL(url);
	CFRelease(url);
	if (!descriptors) return NULL;
	St_Engine *engine = NULL;
	if (CFArrayGetCount(descriptors)) {
		engine = calloc(1, sizeof(*engine));
		if (engine) engine->descriptor = (CTFontDescriptorRef)CFRetain(CFArrayGetValueAtIndex(descriptors, 0));
	}
	CFRelease(descriptors);
	return engine;
}
void st_close(St_Engine *engine) {
	if (!engine) return;
	CFRelease(engine->descriptor);
	free(engine);
}
St_Layout *st_layout(St_Engine *engine, const char *text, int length, float size, int weight) {
	if (!engine || length < 0 || !isfinite(size) || size <= 0) return NULL;
	CFStringRef string = CFStringCreateWithBytes(NULL, (const UInt8 *)(text ? text : ""), length, kCFStringEncodingUTF8, false);
	if (!string) return NULL;
	St_Layout *l = calloc(1, sizeof(*l));
	if (!l) { CFRelease(string); return NULL; }
	l->utf8 = calloc((size_t)length + 1, 1);
	if (!l->utf8) { CFRelease(string); free(l); return NULL; }
	if (length) memcpy(l->utf8, text, length);
	l->length = length;
	int axis = 0x77676874; // OpenType wght axis
	CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &axis);
	CTFontDescriptorRef desc = CTFontDescriptorCreateCopyWithVariation(engine->descriptor, number, weight);
	CFRelease(number);
	CTFontRef font = CTFontCreateWithFontDescriptor(desc, size, NULL);
	CFRelease(desc);
	const void *keys[] = {kCTFontAttributeName, kCTForegroundColorFromContextAttributeName};
	const void *values[] = {font, kCFBooleanTrue};
	CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	l->text = CFAttributedStringCreate(NULL, string, attrs);
	CFRelease(attrs);
	CFIndex total = CFStringGetLength(string);
	bool trailing_break = total > 0 && CFCharacterSetIsCharacterMember(
		CFCharacterSetGetPredefined(kCFCharacterSetNewline), CFStringGetCharacterAtIndex(string, total - 1));
	CFRelease(string);
	CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString(l->text);
	// One slot per UTF-16 unit is an upper bound on hard lines, plus empty text.
	l->lines = calloc(total + 1, sizeof(*l->lines));
	if (!l->lines) { CFRelease(typesetter); CFRelease(font); st_destroy(l); return NULL; }
	CFIndex at = 0;
	CGRect ink = CGRectNull;
	for (;;) {
		CFIndex count = at < total ? CTTypesetterSuggestLineBreak(typesetter, at, 1000000000) : 0;
		if (at < total && count <= 0) break;
		St_Line *line = &l->lines[l->count++];
		line->range = CFRangeMake(at, count);
		line->value = CTTypesetterCreateLine(typesetter, line->range);
		CGFloat ascent, descent, leading;
		double width = CTLineGetTypographicBounds(line->value, &ascent, &descent, &leading);
		if (ascent + descent <= 0) {
			ascent = CTFontGetAscent(font); descent = CTFontGetDescent(font); leading = CTFontGetLeading(font);
		}
		line->height = ceil(ascent + descent + leading);
		line->baseline = l->metrics.height + ascent;
		if (l->count == 1) l->metrics.baseline = line->baseline;
		l->metrics.height += line->height;
		l->metrics.width = fmaxf(l->metrics.width, width);
		CGRect bounds = CTLineGetImageBounds(line->value, NULL);
		if (!CGRectIsNull(bounds) && !CGRectIsEmpty(bounds)) {
			bounds.origin.y = line->baseline - CGRectGetMaxY(bounds);
			ink = CGRectUnion(ink, bounds);
		}
		at += count;
		if (at == total && count > 0 && trailing_break) { trailing_break = false; continue; }
		if (at >= total) break;
	}
	if (!CGRectIsNull(ink)) l->metrics.ink = (St_Rect){ink.origin.x, ink.origin.y, ink.size.width, ink.size.height};
	CFRelease(typesetter); CFRelease(font);
	return l;
}
void st_destroy(St_Layout *l) {
	if (!l) return;
	for (int i = 0; i < l->count; i++) CFRelease(l->lines[i].value);
	if (l->text) CFRelease(l->text);
	free(l->lines); free(l->utf8); free(l);
}
St_Metrics st_metrics(St_Layout *l) { return l->metrics; }
int st_fit(St_Layout *l, float width) {
	if (!isfinite(width) || width < 0 || !l->count) return -1;
	if (l->metrics.width <= width) return l->length;
	CFDictionaryRef base = CFAttributedStringGetAttributes(l->text, 0, NULL);
	CFMutableDictionaryRef attrs = CFDictionaryCreateMutableCopy(NULL, 0, base);
	CFDictionarySetValue(attrs, CFSTR("spoti.ellipsis"), kCFBooleanTrue);
	CFAttributedStringRef text = CFAttributedStringCreate(NULL, CFSTR("…"), attrs);
	CFRelease(attrs);
	CTLineRef token = CTLineCreateWithAttributedString(text);
	CFRelease(text);
	CTLineRef trimmed = CTLineCreateTruncatedLine(l->lines[0].value, width, kCTLineTruncationEnd, token);
	int prefix = -1;
	if (trimmed && CTLineGetTypographicBounds(token, NULL, NULL, NULL) <= width) {
		prefix = 0;
		CFArrayRef runs = CTLineGetGlyphRuns(trimmed);
		for (CFIndex i = 0; i < CFArrayGetCount(runs); i++) {
			CTRunRef run = CFArrayGetValueAtIndex(runs, i);
			if (CFDictionaryContainsKey(CTRunGetAttributes(run), CFSTR("spoti.ellipsis"))) continue;
			CFRange range = CTRunGetStringRange(run);
			int end = st_bytes(l->utf8, l->length, (int)(range.location + range.length));
			if (end > prefix) prefix = end;
		}
	}
	if (trimmed) CFRelease(trimmed);
	CFRelease(token);
	return prefix;
}
float st_cursor(St_Layout *l, int index) {
	return l->count ? CTLineGetOffsetForStringIndex(l->lines[0].value, st_units(l->utf8, l->length, index), NULL) : 0;
}
int st_hit(St_Layout *l, float x, int nearest) {
	if (!l->count) return 0;
	CTLineRef line = l->lines[0].value;
	CFIndex at = CTLineGetStringIndexForPosition(line, CGPointMake(x, 0));
	if (at == kCFNotFound) return x <= 0 ? 0 : l->length;
	if (!nearest && at > 0) {
		// Double-click uses the cluster under the pointer, not its nearest edge.
		CGFloat here = CTLineGetOffsetForStringIndex(line, at, NULL);
		CGFloat before = CTLineGetOffsetForStringIndex(line, at - 1, NULL);
		if ((before <= x && x < here) || (here < x && x <= before)) at--;
	}
	return st_bytes(l->utf8, l->length, (int)at);
}
int st_selection(St_Layout *l, int start, int end, St_Rect *rects, int capacity) {
	if (!l->count) return 0;
	CTLineRef line = l->lines[0].value;
	CFIndex first = st_units(l->utf8, l->length, start), last = st_units(l->utf8, l->length, end);
	CFArrayRef runs = CTLineGetGlyphRuns(line);
	int count = 0;
	for (CFIndex i = 0; i < CFArrayGetCount(runs); i++) {
		CTRunRef run = CFArrayGetValueAtIndex(runs, i);
		CFRange range = CTRunGetStringRange(run);
		CFIndex a = first > range.location ? first : range.location;
		CFIndex b = last < range.location + range.length ? last : range.location + range.length;
		if (a >= b) continue;
		CGFloat left = CGFLOAT_MAX, right = -CGFLOAT_MAX;
		for (CFIndex g = 0; g < CTRunGetGlyphCount(run); g++) {
			CGPoint position; CGSize advance;
			CTRunGetPositions(run, CFRangeMake(g, 1), &position);
			CTRunGetAdvances(run, CFRangeMake(g, 1), &advance);
			left = fmin(left, position.x); right = fmax(right, position.x + advance.width);
		}
		CGFloat secondary_a, secondary_b;
		CGFloat x = CTLineGetOffsetForStringIndex(line, a, &secondary_a);
		CGFloat y = CTLineGetOffsetForStringIndex(line, b, &secondary_b);
		if (x < left - 0.01 || x > right + 0.01) x = secondary_a;
		if (y < left - 0.01 || y > right + 0.01) y = secondary_b;
		if (count < capacity) rects[count] = (St_Rect){fmin(x, y), 0, fabs(x-y), l->lines[0].height};
		count++;
	}
	return count;
}
St_Image st_render(St_Layout *l, uint8_t r, uint8_t g, uint8_t b) {
	St_Image image = st_image(l->metrics.ink);
	if (!image.pixels) return image;
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGContextRef context = CGBitmapContextCreate(image.pixels, image.width, image.height, 8,
		image.stride, space, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
	CGColorSpaceRelease(space);
	if (!context) { free(image.pixels); image.pixels = NULL; return image; }
	CGContextSetShouldSmoothFonts(context, false);
	CGContextSetShouldAntialias(context, true);
	CGContextSetTextMatrix(context, CGAffineTransformIdentity);
	CGContextSetRGBFillColor(context, r/255.0, g/255.0, b/255.0, 1);
	for (int i = 0; i < l->count; i++) {
		CGContextSetTextPosition(context, -image.x, image.height + image.y - l->lines[i].baseline);
		CTLineDraw(l->lines[i].value, context);
	}
	CGContextRelease(context);
	return image;
}
