# Variety v2

A wallpaper manager for macOS, in the spirit of
[Variety](https://github.com/varietywalls/variety) by Peter Levi.

Native Swift, no dependencies, no Python runtime. Lives in the menu bar.

## What it does

- Rotates wallpapers on a timer, on wake, and on login
- Five image sources working with no setup: Bing Photo of the Day, Google
  Earth View, NASA APOD, Wallhaven, ArtStation Trending
- Unsplash and Reddit available once you add your own credentials
- Keep/discard workflow — favourites are kept aside, trashed images are
  remembered and never offered again
- Display modes rendered in Core Image: zoom, black letterbox, blurred fill,
  oil painting
- Optional quote and clock drawn onto the wallpaper
- Menu bar only, no Dock icon; thumbnail strip of recent wallpapers
- Starts at login

```
swift build -c release
./.build/release/VarietyV2 --selftest      # internal checks
./.build/release/VarietyV2 --probe-sources # hit the live image APIs
./.build/release/VarietyV2 --cycle         # one full fetch → render → set
./Scripts/build-app.sh                     # build VarietyV2.app
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

## Notes on the sources

Variety was written against a more open web than exists now, and several of
its sources have since closed off. Checked against the live services:

| Source | State |
| --- | --- |
| Bing, Earth View, APOD, Wallhaven | work anonymously |
| ArtStation | project JSON is behind a Cloudflare challenge; the RSS feeds are open, which is the route Variety uses too |
| Reddit | refuses anonymous JSON since the 2023 API changes — 403/503 regardless of User-Agent. Needs a free script app |
| Unsplash | needs your own access key |
| `api.quotable.io` | no longer resolves. Quotes come from ZenQuotes, with a community Quotable mirror and a bundled set behind it |

`--probe-sources` exists to catch the next one of these to break.

## A note on start-at-login

`SMAppService` registration is invalidated when the `.app` bundle is replaced
wholesale, so the build script updates the installed bundle in place rather
than deleting and re-copying it.

Separately: Swift's synthesized `Codable` throws `keyNotFound` for a missing
key even when the property has a default, so a settings file written by an
older build would fail to decode and silently reset *every* preference —
including turning start-at-login back off and unregistering the login item.
`Settings` therefore decodes leniently, field by field, and the self-test
covers it.

## Build

Command Line Tools are sufficient; full Xcode is not required. Because
`swift build --arch arm64 --arch x86_64` needs xcbuild, `Scripts/build-app.sh`
builds each architecture separately and `lipo`s them when `UNIVERSAL=1`.

## License

MIT. See [LICENSE](LICENSE).
