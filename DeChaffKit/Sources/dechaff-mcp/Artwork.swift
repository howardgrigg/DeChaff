import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pixel size of an image, or nil if the data isn't an image ImageIO can read.
func imageSize(_ data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int,
          let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (width, height)
}

/// Re-encodes any image as JPEG, as the app does when artwork is chosen — the ID3 tag
/// always labels cover art image/jpeg. Pass `maxPixel` to also scale it down.
func jpegImage(_ data: Data, maxPixel: Int? = nil, quality: Double = 0.85) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let image: CGImage?
    if let maxPixel {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    } else {
        image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    guard let image else { return nil }
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image,
                               [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return out as Data
}
