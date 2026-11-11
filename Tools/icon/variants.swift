import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Foundation

let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let variants: [(String, Double)] = [("Blue", 195), ("Purple", 250), ("Green", 115), ("Pink", 320)]
let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
let input = CIImage(contentsOf: src)!

func write(_ image: CIImage, size: CGFloat, to url: URL, opaque: Bool) {
    let scale = size / image.extent.width
    var img = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    if opaque {
        img = img.composited(over: CIImage(color: .white).cropped(to: img.extent))
    }
    let cg = ctx.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    // App icons must not have alpha: draw into an opaque RGB context.
    let rgb = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    rgb.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, rgb.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

write(input, size: 240, to: outDir.appendingPathComponent("preview-Default.png"), opaque: true)
for (name, degrees) in variants {
    let f = CIFilter.hueAdjust()
    f.inputImage = input
    f.angle = Float(degrees * .pi / 180)
    let out = f.outputImage!.cropped(to: input.extent)
    write(out, size: 1024, to: outDir.appendingPathComponent("AppIcon\(name)-1024.png"), opaque: true)
    write(out, size: 240, to: outDir.appendingPathComponent("preview-\(name).png"), opaque: true)
}
print("ok")
