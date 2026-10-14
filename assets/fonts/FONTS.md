# fonts

Geist is the primary face on Linux, macOS, and Windows.

- `Geist[wght].ttf`: regular by default, Medium for track titles, and
  ExtraBold for hero titles and headings.
- `GeistMono-Regular.ttf`: numeric fields.
- `OFL.txt`: the SIL Open Font License for both files.

Source: https://github.com/vercel/geist-font

`SPOTI_FONTS` overrides the primary font search directory. Install layouts
and the development checkout are also searched. If Geist is absent, Linux
uses fontconfig for the primary face; other platforms require the bundle.

## system glyph fallback

Fontconfig selects an installed outline face for each character Geist
cannot draw. Script letters use the requested weight; missing symbols use
regular weight to preserve their outline. This includes symbols and scripts,
not just CJK. SDL_ttf verifies glyph coverage and attaches the selected
face to the primary font. Font sources and character matches are cached;
faces are opened only for sizes used by the interface.

Measurement and drawing use the same prepared font. Existing Geist glyphs
keep their original appearance and advances. Truncation and its measurement
probes stop only at complete Unicode grapheme clusters.

Fontconfig is required on all three targets. Its configuration must include
the system and user font directories. On Windows, package its configuration
files with its DLL and dependencies, not only the fontconfig DLL.
On Linux, Noto's script and symbol font packages provide broad coverage.
No fallback font binaries are included in this repository. Emoji presentation
uses Unicode 17 data under the [Unicode license](../../docs/licenses/unicode.txt).

## remaining limits

Only installed glyphs can be displayed. A character with no usable installed
font still uses the missing-glyph box. Font selection is character-based;
script-run and locale-specific fallback selection need further work.

## inline emoji

Color emoji are separate from ordinary font fallback. Fontconfig selects the
system color emoji face. SDL_ttf shapes each complete sequence and renders
its image on a worker. The UI uploads at most six images per frame and keeps
a 256-entry texture cache. Worker fonts and surfaces never cross into the
ordinary text font cache.

Every emoji sequence reserves one cell based on Geist's visible capital
height. Image availability cannot change measurement, wrapping, or truncation.
The UI scales the cached image into that cell and centers it vertically
against the primary font's visible capital ink. A pending,
missing, or unjoined sequence shows one outlined placeholder, not several
squeezed pictures. No system font is installed or replaced.

Headless Linux tests cover Noto Color Emoji cars, smoke, flags, skin tones,
hearts, keycaps, and joined families. macOS and Windows use the same path but
still require native runtime verification with Apple Color Emoji and Segoe UI
Emoji. Overlapping glyph layers are accepted when they fit one advancing
emoji cell; unjoined side-by-side parts are rejected. Full bidirectional
layout across mixed text and emoji spans is not provided; ordinary spans
retain SDL_ttf's shaping.
