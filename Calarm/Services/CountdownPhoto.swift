//
//  CountdownPhoto.swift
//  Calarm
//
//  La foto de fondo de una cuenta regresiva: se reduce al elegirla (una foto de
//  12 megapíxeles pesa varios MB en iCloud y tarda en decodificarse en cada
//  tarjeta) y se guarda decodificada en memoria para no repetir el trabajo al
//  hacer scroll.
//

import ImageIO
import UIKit
import UniformTypeIdentifiers

enum CountdownPhoto {
    /// Lado mayor en píxeles: sobra para una tarjeta a lo ancho de un iPad.
    nonisolated static let maxPixelSize = 1600

    /// JPEG reducido, con la orientación aplicada y sin metadatos (ni ubicación
    /// ni cámara viajan a iCloud). Nil si los datos no son una imagen.
    /// `nonisolated` para hacerlo fuera del hilo principal al elegir la foto.
    nonisolated static func prepared(from imageData: Data, maxPixelSize: Int = CountdownPhoto.maxPixelSize) -> Data? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        return cache
    }()

    /// La imagen decodificada de `data`, reutilizada mientras sea la misma foto.
    /// `key` identifica la cuenta; el tamaño separa una foto de la siguiente.
    static func image(for data: Data, key: UUID) -> UIImage? {
        // El final del JPEG cambia de una foto a otra; la cabecera, casi nunca.
        let cacheKey = "\(key.uuidString)-\(data.count)-\(data.suffix(128).hashValue)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        guard let decoded = UIImage(data: data) else { return nil }
        let image = decoded.preparingForDisplay() ?? decoded
        cache.setObject(image, forKey: cacheKey)
        return image
    }
}
