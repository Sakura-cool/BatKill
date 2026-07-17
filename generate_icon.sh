#!/bin/bash
# ────────────────────────────────────────────────────
# Generate BatKill.app icon via Swift + iconutil
# Renders at 2048×2048 with sharpening for crisp output
# ────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SCRIPT_DIR/Resources/AppIcon.icns"
TMPDIR=$(mktemp -d)
trap "rm -rf \"$TMPDIR\"" EXIT

# Write a Swift script that renders the icon
cat > "$TMPDIR/gen.swift" << 'SWIFT'
import AppKit
import CoreImage

let iconSize: CGFloat = 2048
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
ctx.setLineWidth(56)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let bw: CGFloat = 960   // battery width  (2x)
let bh: CGFloat = 640   // battery height (2x)
let bx = (iconSize - bw) / 2
let by = (iconSize - bh) / 2
let br: CGFloat = 100   // battery corner (2x)

let bodyRect = CGRect(x: bx, y: by, width: bw, height: bh)
ctx.addPath(CGPath(roundedRect: bodyRect, cornerWidth: br, cornerHeight: br, transform: nil))
ctx.strokePath()

// --- Battery terminal (tip) ---
let tw: CGFloat = 80    // 2x
let th: CGFloat = 160   // 2x
let tx = bx + bw
let ty = (iconSize - th) / 2
let termRect = CGRect(x: tx, y: ty, width: tw, height: th)
let termPath = CGPath(roundedRect: termRect, cornerWidth: 32, cornerHeight: 32, transform: nil)
ctx.addPath(termPath)
ctx.fillPath()

// --- Lightning bolt ⚡ (2x coordinates) ---
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
let bolt = CGMutablePath()
bolt.move(to: CGPoint(x: 1140, y: 1400))
bolt.addLine(to: CGPoint(x: 840, y: 960))
bolt.addLine(to: CGPoint(x: 1020, y: 960))
bolt.addLine(to: CGPoint(x: 880, y: 640))
bolt.addLine(to: CGPoint(x: 1220, y: 1080))
bolt.addLine(to: CGPoint(x: 1040, y: 1080))
bolt.closeSubpath()
ctx.addPath(bolt)
ctx.fillPath()

img.unlockFocus()

// --- Sharpen via CIUnsharpMask ---
guard let tiff = img.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let cgImage = bitmap.cgImage else {
    print("❌ Failed to get bitmap")
    exit(1)
}

let ciImage = CIImage(cgImage: cgImage)
guard let filter = CIFilter(name: "CIUnsharpMask") else {
    print("❌ No CIUnsharpMask filter")
    exit(1)
}
filter.setValue(ciImage, forKey: kCIInputImageKey)
filter.setValue(2.5, forKey: kCIInputRadiusKey)    // sharpen radius
filter.setValue(1.2, forKey: kCIInputIntensityKey)  // sharpen strength

let context = CIContext(options: [.workingColorSpace: NSNull()])
guard let output = filter.outputImage,
      let sharpened = context.createCGImage(output, from: output.extent) else {
    print("❌ Sharpening failed")
    exit(1)
}

// --- Save as PNG ---
let sharpBitmap = NSBitmapImageRep(cgImage: sharpened)
guard let png = sharpBitmap.representation(using: .png, properties: [.compressionFactor: 1.0]) else {
    print("❌ Failed to encode PNG")
    exit(1)
}
let url = URL(fileURLWithPath: "\(NSTemporaryDirectory())/icon_2048.png")
try png.write(to: url)
print(url.path)
SWIFT

# Run the Swift script
GENERATED=$(swift "$TMPDIR/gen.swift" 2>/dev/null | tail -1)
echo "✅ Icon PNG: $GENERATED"

# Create iconset and convert to .icns
ICONSET="$TMPDIR/AppIcon.iconset"
mkdir -p "$ICONSET"

# Downscale from 2048×2048 sharpened source to all standard sizes
sips -z 16  16  "$GENERATED" --out "$ICONSET/icon_16x16.png"        > /dev/null 2>&1
sips -z 32  32  "$GENERATED" --out "$ICONSET/icon_16x16@2x.png"     > /dev/null 2>&1
sips -z 32  32  "$GENERATED" --out "$ICONSET/icon_32x32.png"        > /dev/null 2>&1
sips -z 64  64  "$GENERATED" --out "$ICONSET/icon_32x32@2x.png"     > /dev/null 2>&1
sips -z 128 128 "$GENERATED" --out "$ICONSET/icon_128x128.png"      > /dev/null 2>&1
sips -z 256 256 "$GENERATED" --out "$ICONSET/icon_128x128@2x.png"   > /dev/null 2>&1
sips -z 256 256 "$GENERATED" --out "$ICONSET/icon_256x256.png"      > /dev/null 2>&1
sips -z 512 512 "$GENERATED" --out "$ICONSET/icon_256x256@2x.png"   > /dev/null 2>&1
sips -z 512 512 "$GENERATED" --out "$ICONSET/icon_512x512.png"      > /dev/null 2>&1
sips -z 1024 1024 "$GENERATED" --out "$ICONSET/icon_512x512@2x.png" > /dev/null 2>&1

# Create .icns
iconutil -c icns "$ICONSET" -o "$OUT"
echo "✅ Icon created: $OUT"