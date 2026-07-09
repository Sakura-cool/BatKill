#!/bin/bash
# ────────────────────────────────────────────────────
# Generate BatKill.app icon via Swift + iconutil
# ────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SCRIPT_DIR/Resources/AppIcon.icns"
TMPDIR=$(mktemp -d)
trap "rm -rf \"$TMPDIR\"" EXIT

# Write a Swift script that renders the icon
cat > "$TMPDIR/gen.swift" << 'SWIFT'
import AppKit

let iconSize: CGFloat = 1024
let img = NSImage(size: NSSize(width: iconSize, height: iconSize))
img.lockFocusFlipped(false)
let ctx = NSGraphicsContext.current!.cgContext

// --- Clipping: rounded rect (macOS app icon radius ≈ 22 %) ---
let r = iconSize * 0.22
let rect = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
let clipPath = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
clipPath.addClip()

// --- Background: green → blue gradient ---
let colorSpace = CGColorSpaceCreateDeviceRGB()
let colors: [CGColor] = [
    CGColor(red: 0.12, green: 0.58, blue: 0.32, alpha: 1),
    CGColor(red: 0.08, green: 0.42, blue: 0.68, alpha: 1),
]
let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: iconSize), end: CGPoint(x: iconSize, y: 0), options: [])

// --- Battery body ---
let batteryColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.92)
ctx.setStrokeColor(batteryColor)
ctx.setLineWidth(28)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let bw: CGFloat = 480   // battery width
let bh: CGFloat = 320   // battery height
let bx = (iconSize - bw) / 2
let by = (iconSize - bh) / 2
let br: CGFloat = 50    // battery corner

let bodyRect = CGRect(x: bx, y: by, width: bw, height: bh)
ctx.addPath(CGPath(roundedRect: bodyRect, cornerWidth: br, cornerHeight: br, transform: nil))
ctx.strokePath()

// --- Battery terminal (tip) ---
let tw: CGFloat = 40
let th: CGFloat = 80
let tx = bx + bw
let ty = (iconSize - th) / 2
let termRect = CGRect(x: tx, y: ty, width: tw, height: th)
let termPath = CGPath(roundedRect: termRect, cornerWidth: 16, cornerHeight: 16, transform: nil)
ctx.addPath(termPath)
ctx.fillPath()

// --- Lightning bolt ⚡ ---
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
let bolt = CGMutablePath()
bolt.move(to: CGPoint(x: 570, y: 700))
bolt.addLine(to: CGPoint(x: 420, y: 480))
bolt.addLine(to: CGPoint(x: 510, y: 480))
bolt.addLine(to: CGPoint(x: 440, y: 320))
bolt.addLine(to: CGPoint(x: 610, y: 540))
bolt.addLine(to: CGPoint(x: 520, y: 540))
bolt.closeSubpath()
ctx.addPath(bolt)
ctx.fillPath()

img.unlockFocus()

// --- Save as PNG ---
guard let tiff = img.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    print("❌ Failed to render icon")
    exit(1)
}
let url = URL(fileURLWithPath: "\(NSTemporaryDirectory())/icon_1024.png")
try png.write(to: url)
print(url.path)
SWIFT

# Run the Swift script
GENERATED=$(swift "$TMPDIR/gen.swift" 2>/dev/null | tail -1)
echo "✅ Icon PNG: $GENERATED"

# Create iconset and convert to .icns
ICONSET="$TMPDIR/AppIcon.iconset"
mkdir -p "$ICONSET"

sips -z 16  16  "$GENERATED" --out "$ICONSET/icon_16x16.png"        > /dev/null 2>&1
sips -z 32  32  "$GENERATED" --out "$ICONSET/icon_16x16@2x.png"     > /dev/null 2>&1
sips -z 32  32  "$GENERATED" --out "$ICONSET/icon_32x32.png"        > /dev/null 2>&1
sips -z 64  64  "$GENERATED" --out "$ICONSET/icon_32x32@2x.png"     > /dev/null 2>&1
sips -z 128 128 "$GENERATED" --out "$ICONSET/icon_128x128.png"      > /dev/null 2>&1
sips -z 256 256 "$GENERATED" --out "$ICONSET/icon_128x128@2x.png"   > /dev/null 2>&1
sips -z 256 256 "$GENERATED" --out "$ICONSET/icon_256x256.png"      > /dev/null 2>&1
sips -z 512 512 "$GENERATED" --out "$ICONSET/icon_256x256@2x.png"   > /dev/null 2>&1
sips -z 512 512 "$GENERATED" --out "$ICONSET/icon_512x512.png"      > /dev/null 2>&1
cp "$GENERATED" "$ICONSET/icon_512x512@2x.png"

# Create .icns
iconutil -c icns "$ICONSET" -o "$OUT"
echo "✅ Icon created: $OUT"
