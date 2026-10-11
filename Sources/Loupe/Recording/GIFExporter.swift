import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Converts a recorded movie into a looping animated GIF.
enum GIFExporter {
    static let framesPerSecond = 15
    /// GIFs get large fast; keep the longest side to this many pixels.
    static let maxDimension: CGFloat = 1000

    static func export(movie: URL, to url: URL) async throws {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw RecordingError.noFrames }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)

        let frameCount = max(1, Int((duration * Double(framesPerSecond)).rounded(.up)))
        let delay = 1 / Double(framesPerSecond)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary

        for index in 0..<frameCount {
            try Task.checkCancellation()
            let time = CMTime(seconds: min(Double(index) * delay, duration), preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
