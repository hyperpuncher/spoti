# app icon

`icon.svg` is the shared source. the PNG, ICO, and ICNS outputs are
committed, so builds need no SVG renderer or icon converter.

regenerate them from the repository root after an SVG change:

```sh
svgo assets/app/icon.svg
rsvg-convert -w 1024 -h 1024 assets/app/icon.svg -o assets/app/icon.png
magick assets/app/icon.png -define icon:auto-resize=256,128,64,48,32,16 assets/app/icon.ico
python3 -c 'from PIL import Image; Image.open("assets/app/icon.png").save("assets/app/icon.icns", format="ICNS")'
```

- SDL uses the PNG for the running app.
- Windows embeds the ICO through `packaging/windows/app.rc`.
- macOS copies the multi-size ICNS into the bundle, then signs it.
- Linux uses `app.spoti.desktop` and the `app.spoti` application ID.
