// Turns the logo into the 1024 point master of the app icon: drops the
// faint specks left around it, trims it to its artwork and centres it on
// the macOS icon canvas.
//
//     swift scripts/IconFromLogo.swift docs/assets/logo-source.png /tmp/icon-1024.png

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let source = NSImage(contentsOfFile: arguments[1]),
      let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("usage: IconFromLogo <logo.png> <icon-1024.png>")
}

let width = cgSource.width, height = cgSource.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let info = CGImageAlphaInfo.premultipliedLast.rawValue
let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info)!
context.draw(cgSource, in: CGRect(x: 0, y: 0, width: width, height: height))

// Nearly transparent pixels are leftovers from cutting out the logo.
let speck: UInt8 = 64
var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        if pixels[i + 3] < speck {
            pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
        } else {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
let cleaned = context.makeImage()!
// The bitmap's rows run bottom up in Core Graphics.
let artwork = cleaned.cropping(to: CGRect(x: minX, y: height - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1))!

// The macOS grid keeps artwork inside about 824 of 1024 points.
let canvas = 1024, fit: CGFloat = 860
let scale = fit / CGFloat(max(artwork.width, artwork.height))
let drawn = CGSize(width: CGFloat(artwork.width) * scale, height: CGFloat(artwork.height) * scale)
let output = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
output.interpolationQuality = .high
output.draw(artwork, in: CGRect(x: (CGFloat(canvas) - drawn.width) / 2, y: (CGFloat(canvas) - drawn.height) / 2,
                                width: drawn.width, height: drawn.height))
let data = NSBitmapImageRep(cgImage: output.makeImage()!).representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: arguments[2]))
print("Wrote \(arguments[2])")
