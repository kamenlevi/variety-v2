# Variety v2

A wallpaper manager for macOS, in the spirit of
[Variety](https://github.com/varietywalls/variety) by Peter Levi.

Native Swift, no dependencies, no Python runtime. Lives in the menu bar.

## Status

Early. The wallpaper engine and its self-tests work; sources, effects,
overlays and UI are in progress.

```
swift build -c release
./.build/release/VarietyV2 --selftest
./Scripts/build-app.sh
```

## Relationship to Variety

This is a reimplementation, not a port. Variety is GPL-3 Python + GTK, and is
in maintenance mode upstream; none of its code is used here, so this project is
MIT. What is borrowed is the *design*: rotating wallpapers from a set of online
sources, and a keep/discard workflow for separating good images from junk.

Same approach as [OjoX](https://github.com/kamenlevi/OjoX), which took Ojo's
design and replaced its engine entirely.

## Notes on setting wallpaper in macOS 26

These were measured on 26.5 (build 25F71), not taken from documentation. They
are the reason the code is shaped the way it is.

### WallpaperAgent caches by file URL

Writing new bytes to the path that is already the current wallpaper and calling
`setDesktopImageURL` again **does nothing.** No error is thrown. The index file
updates. The screen does not change.

Demonstrated by setting a red image at a path, then overwriting that same path
with a green image and setting it again — the desktop stayed red.

Consequence: every visual change must land on a path that has never been used
as a wallpaper before. `GenerationStore` hands out fresh paths and prunes old
ones. This matters most for the clock overlay, which emits a file per minute.

This also means the natural Linux approach — Variety keeps one
`wallpaper.jpg` and rewrites it — cannot be transplanted directly.

### `desktopImageURL(for:)` is unreliable

It returns `/System/Library/CoreServices/DefaultDesktop.heic` regardless of
what is actually on screen. It cannot be used to read current state.

The real state is in WallpaperAgent's own index:

```
~/Library/Application Support/com.apple.wallpaper/Store/Index.plist
```

which contains *nested* binary plists — the per-choice `Configuration` value is
itself a plist holding `{ type: "imageFile", url: { relative: "file://…" } }`.
`WallpaperStore` parses this.

### Cached metadata in the index goes stale

The index stores a computed dominant colour alongside the wallpaper choice. It
is not always recomputed when the wallpaper changes, so it is not a reliable
signal for "did the wallpaper actually change". Only the `url` field tracks
reliably.

### Dynamic wallpapers have no backing file

When the desktop is on a system dynamic wallpaper the provider is
`com.apple.wallpaper.choice.sequoia` with an empty file list, so there is no
path to read. `currentImageURL()` returns nil rather than inventing one.

### Scope decision: one image everywhere

Per-Space wallpapers are the least reliable corner of this API and are
deliberately not attempted. All attached screens get the same image.

## Build

Command Line Tools are sufficient; full Xcode is not required. Because
`swift build --arch arm64 --arch x86_64` needs xcbuild, `Scripts/build-app.sh`
builds each architecture separately and `lipo`s them when `UNIVERSAL=1`.

## License

MIT. See [LICENSE](LICENSE).
