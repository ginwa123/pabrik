# Pabrik brand icons

Single artwork, many containers. The mark is a `P` in Kanagawa violet
(`#8992a7`) on the Kanagawa Dragon background (`#181616`) — the same
artwork as the anakmagangweb site favicon
(`src/static/favicon.ico` there).

## Files

| File | Purpose |
|---|---|
| `pabrik-16.png` … `pabrik-1024.png` | Crisp per-size renders (source of truth for every container below) |
| `pabrik.ico` | Multi-size Windows ICO (16/32/48/256) — embedded into `pabrik-desktop.exe` via `packaging/windows/pabrik.rc` |
| `../macos/Pabrik.icns` | Multi-resolution macOS icon (ic11/ic12/ic07/ic14/ic08/ic13/ic09/ic10) — copied into `Pabrik.app/Contents/Resources` by `install-pabrik-app.sh` |
| `../../src/apps/desktop/public/favicon.ico` | 32×32 web favicon, byte-identical to the anakmagangweb source (fast tab load) |
| `../../src/apps/desktop/public/apple-touch-icon.png` | 180×180 copy of `pabrik-180.png` for Safari/iOS |

Linux needs no committed copy: `zig build install:linux:app` renders the
hicolor entries from these PNGs (see `build.zig`).

## Regenerating

Requires ImageMagick (`magick`). The recipe matches the original
ImageMagick command documented in anakmagangweb's `favicon_handler.zig`:

```bash
cd packaging/icons
for s in 16 32 48 64 128 180 256 512 1024; do
  magick -size ${s}x${s} xc:'#181616' -fill '#8992a7' \
    -pointsize $((s*22/32)) -gravity center -annotate +0+0 'P' \
    pabrik-${s}.png
done
magick pabrik-16.png pabrik-32.png pabrik-48.png pabrik-256.png pabrik.ico
cp pabrik-180.png ../../src/apps/desktop/public/apple-touch-icon.png
```

The `.icns` is a plain container (magic `icns`, then `OSType + be32 len +
PNG` elements) — repack with `packaging/macos/build-icns.py` after
re-rendering the PNGs.
