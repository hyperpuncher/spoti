# Bundled fonts

The app renders the same faces on every platform from these two files,
so no system font lookup is needed at startup.

- `Geist[wght].ttf`: Geist variable font, regular weight by default.
  The Medium and Bold roles open named instances 5 and 7 of this file.
- `GeistMono-Regular.ttf`: Geist Mono, for numeric fields.
- `OFL.txt`: the SIL Open Font License covering both files.

Sources: https://github.com/vercel/geist-font

If the bundle is missing, Linux falls back to fontconfig; other
platforms exit with the missing file named. `SPOTI_FONTS` overrides
the search directory.
