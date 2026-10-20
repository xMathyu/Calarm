//
//  InvitePhoto.swift
//  Calarm
//
//  An alarm's photo icon, shrunk to travel inside an invitation link.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo can't travel by reference — the site behind invitation links
/// stores nothing — so it travels *in* the link: a tiny square JPEG,
/// base64url in the `f` query parameter (`InviteLink.make`). The link preview
/// shows the tile at roughly 60 points, so 64 pixels is enough.
///
/// ImageIO and CoreGraphics only (no UIKit), so it also runs on a Mac, which
/// is how the link codec gets checked against the site without a device.
enum InvitePhoto {
    static let side = 64
    /// Before base64url: ~2,400 characters of link at most.
    static let maxBytes = 1_800

    /// A center-cropped, upright `side`×`side` JPEG of `imageData`, stripped of
    /// metadata, at the best quality that fits `maxBytes`. Nil when the data
    /// isn't an image or nothing fits — the invitation then shows the category's
    /// symbol, as it did before photos travelled.
    static func thumbnail(from imageData: Data) -> Data? {
        // Downsampled while decoding: a 12-megapixel photo is never fully decoded.
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // EXIF orientation applied
            kCGImageSourceThumbnailMaxPixelSize: side * 4,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let square = squared(upright) else { return nil }
        for quality in [0.6, 0.5, 0.4, 0.3] {
            if let jpeg = encodeJPEG(square, quality: quality), jpeg.count <= maxBytes {
                return jpeg
            }
        }
        return nil
    }

    /// The centered square of `image`, scaled to `side`, the way the app's
    /// round avatar crops a photo (`scaledToFill`).
    private static func squared(_ image: CGImage) -> CGImage? {
        let edge = min(image.width, image.height)
        let crop = CGRect(x: (image.width - edge) / 2, y: (image.height - edge) / 2, width: edge, height: edge)
        guard edge > 0,
              let cropped = image.cropping(to: crop),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        // JPEG has no transparency: a transparent PNG lands on white, not black.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(cropped, in: bounds)
        return context.makeImage()
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return strippingMetadata(data as Data)
    }

    /// Drops the APP1…APP15 and COM segments: EXIF, comments and above all the
    /// ICC profile ImageIO embeds, which alone outweighs a 64-pixel image. The
    /// pixels were drawn in sRGB, which is what any decoder assumes for a JPEG
    /// without a profile. Anything unexpected returns the JPEG untouched.
    static func strippingMetadata(_ jpeg: Data) -> Data {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return jpeg }
        var out: [UInt8] = [0xFF, 0xD8]
        var index = 2
        while index + 4 <= bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            if marker == 0xFF { // fill byte before a marker
                index += 1
                continue
            }
            if marker == 0xDA { // start of scan: from here on it's image data
                out += bytes[index...]
                return Data(out)
            }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let end = index + 2 + length
            guard length >= 2, end <= bytes.count else { return jpeg }
            let isMetadata = (0xE1...0xEF).contains(marker) || marker == 0xFE
            if !isMetadata { out += bytes[index..<end] }
            index = end
        }
        return jpeg
    }
}
