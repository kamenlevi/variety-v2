#!/bin/bash
# Rebuilds Resources/Variety.icns from Resources/variety.svg.
#
# The source SVG is Variety's own app icon, taken from
# variety/data/media/variety.svg upstream. macOS renders SVG through NSImage,
# so no external converter (rsvg, Inkscape) is needed.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/rasterize.swift" <<'SWIFT'
import AppKit
let svg = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: svg) else { fatalError("cannot load \(svg.path)") }
for size in [16, 32, 64, 128, 256, 512, 1024] {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: outDir.appendingPathComponent("\(size).png"))
}
SWIFT

swiftc -O "$WORK/rasterize.swift" -o "$WORK/rasterize"
mkdir -p "$WORK/png" "$WORK/Variety.iconset"
"$WORK/rasterize" "$ROOT/Resources/variety.svg" "$WORK/png"

cd "$WORK"
cp png/16.png   Variety.iconset/icon_16x16.png
cp png/32.png   Variety.iconset/icon_16x16@2x.png
cp png/32.png   Variety.iconset/icon_32x32.png
cp png/64.png   Variety.iconset/icon_32x32@2x.png
cp png/128.png  Variety.iconset/icon_128x128.png
cp png/256.png  Variety.iconset/icon_128x128@2x.png
cp png/256.png  Variety.iconset/icon_256x256.png
cp png/512.png  Variety.iconset/icon_256x256@2x.png
cp png/512.png  Variety.iconset/icon_512x512.png
cp png/1024.png Variety.iconset/icon_512x512@2x.png

iconutil -c icns Variety.iconset -o "$ROOT/Resources/Variety.icns"
echo "wrote Resources/Variety.icns"
