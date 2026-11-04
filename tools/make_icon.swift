// Draws the app icon: a curved patch of quads on off-white.  swift tools/make_icon.swift out.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(srgbRed: 0.965, green: 0.955, blue: 0.93, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

// A patch bent as if lying on a sphere.
let cells = 5
func point(_ u: Double, _ v: Double) -> CGPoint {
    let a = (u - 0.5) * 1.5, b = (v - 0.5) * 1.5
    let x = sin(a) * cos(b * 0.6), y = sin(b) * cos(a * 0.6)
    return CGPoint(x: 512 + x * 400, y: 512 + y * 400)
}
for i in 0..<cells {
    for j in 0..<cells {
        let u0 = Double(i) / Double(cells), u1 = Double(i + 1) / Double(cells)
        let v0 = Double(j) / Double(cells), v1 = Double(j + 1) / Double(cells)
        let warm = (i + j) % 2 == 0
        context.setFillColor(warm ? CGColor(srgbRed: 0.87, green: 0.62, blue: 0.46, alpha: 1) : CGColor(srgbRed: 0.92, green: 0.75, blue: 0.62, alpha: 1))
        context.beginPath()
        context.addLines(between: [point(u0, v0), point(u1, v0), point(u1, v1), point(u0, v1)])
        context.closePath()
        context.fillPath()
    }
}
context.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.16, blue: 0.14, alpha: 1))
context.setLineWidth(11)
context.setLineJoin(.round)
context.setLineCap(.round)
for i in 0...cells {
    let t = Double(i) / Double(cells)
    context.addLines(between: (0...40).map { point(t, Double($0) / 40) })
    context.addLines(between: (0...40).map { point(Double($0) / 40, t) })
}
context.strokePath()
context.setFillColor(CGColor(srgbRed: 0.2, green: 0.16, blue: 0.14, alpha: 1))
for i in 0...cells {
    for j in 0...cells {
        let p = point(Double(i) / Double(cells), Double(j) / Double(cells))
        context.fillEllipse(in: CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36))
    }
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
