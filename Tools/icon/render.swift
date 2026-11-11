import AppKit
import ImageIO
import UniformTypeIdentifiers
// render.swift <in.svg> <out.png> <size>: SVG → PNG opaco (sin canal alfa), como pide Apple para íconos.
let a = CommandLine.arguments
let size = Int(a[3])!
guard let img = NSImage(contentsOf: URL(fileURLWithPath: a[1])) else { fatalError("no pude leer el SVG") }
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
