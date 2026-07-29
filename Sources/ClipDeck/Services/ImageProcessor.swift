import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageProcessingCandidate: Sendable {
    let typeIdentifier: String
    let data: Data
}

struct ProcessedClipboardImage: Sendable {
    let data: Data
    let typeIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    let fingerprint: Data
    let thumbnailData: Data
}

enum ImageProcessingFailure: Error, Equatable, Sendable {
    case cancelled
    case rawDataTooLarge
    case finalDataTooLarge
    case invalidFormat
    case dimensionsTooLarge
    case thumbnailCreationFailed
}

enum ImageProcessingOutcome: Sendable {
    case success(ProcessedClipboardImage)
    case failure(ImageProcessingFailure)
}

protocol ImageProcessing: Sendable {
    func process(_ candidate: ImageProcessingCandidate) async -> ImageProcessingOutcome
}

/// Serializes memory-intensive image work away from the main actor.
actor ImageProcessor: ImageProcessing {
    struct Configuration: Sendable {
        var maximumRawBytes = 96 * 1024 * 1024
        var maximumFinalBytes = 32 * 1024 * 1024
        var maximumDimension = 12_000
        var maximumPixelCount: Int64 = 20_000_000
        var thumbnailMaximumDimension = 320
        var tiffNormalizationThresholdBytes = 8 * 1024 * 1024

        static let `default` = Configuration()
    }

    private let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    func process(_ candidate: ImageProcessingCandidate) async -> ImageProcessingOutcome {
        guard !Task.isCancelled else {
            return .failure(.cancelled)
        }

        return autoreleasepool {
            Self.processSynchronously(candidate, configuration: configuration)
        }
    }

    private nonisolated static func processSynchronously(
        _ candidate: ImageProcessingCandidate,
        configuration: Configuration
    ) -> ImageProcessingOutcome {
        guard !Task.isCancelled else {
            return .failure(.cancelled)
        }
        guard candidate.data.count <= configuration.maximumRawBytes else {
            return .failure(.rawDataTooLarge)
        }

        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(
            candidate.data as CFData,
            sourceOptions
        ),
        let detectedTypeIdentifier = CGImageSourceGetType(source) as String?,
        let detectedType = UTType(detectedTypeIdentifier),
        detectedType.conforms(to: .image),
        let dimensions = pixelDimensions(from: source) else {
            return .failure(.invalidFormat)
        }

        let isTIFF = detectedType.conforms(to: .tiff)
        guard isTIFF || candidate.data.count <= configuration.maximumFinalBytes else {
            return .failure(.finalDataTooLarge)
        }

        guard dimensions.width <= configuration.maximumDimension,
              dimensions.height <= configuration.maximumDimension,
              dimensions.height <= Int64.max / Int64(dimensions.width),
              Int64(dimensions.width) * Int64(dimensions.height)
                <= configuration.maximumPixelCount else {
            return .failure(.dimensionsTooLarge)
        }

        guard !Task.isCancelled else {
            return .failure(.cancelled)
        }

        guard let thumbnailData = makeThumbnailData(
            from: source,
            maximumDimension: configuration.thumbnailMaximumDimension
        ) else {
            return .failure(.thumbnailCreationFailed)
        }

        guard !Task.isCancelled else {
            return .failure(.cancelled)
        }

        let normalized = normalizeIfUseful(
            candidate: candidate,
            source: source,
            detectedTypeIdentifier: detectedTypeIdentifier,
            isTIFF: isTIFF,
            maximumFinalBytes: configuration.maximumFinalBytes,
            tiffNormalizationThresholdBytes: configuration.tiffNormalizationThresholdBytes
        )
        guard let normalized else {
            return .failure(.finalDataTooLarge)
        }

        guard !Task.isCancelled else {
            return .failure(.cancelled)
        }

        let digest = Data(SHA256.hash(data: normalized.data))
        return .success(
            ProcessedClipboardImage(
                data: normalized.data,
                typeIdentifier: normalized.typeIdentifier,
                pixelWidth: dimensions.width,
                pixelHeight: dimensions.height,
                fingerprint: digest,
                thumbnailData: thumbnailData
            )
        )
    }

    private nonisolated static func pixelDimensions(
        from source: CGImageSource
    ) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            return nil
        }

        return (width, height)
    }

    private nonisolated static func makeThumbnailData(
        from source: CGImageSource,
        maximumDimension: Int
    ) -> Data? {
        guard maximumDimension > 0 else {
            return nil
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return output as Data
    }

    private nonisolated static func normalizeIfUseful(
        candidate: ImageProcessingCandidate,
        source: CGImageSource,
        detectedTypeIdentifier: String,
        isTIFF: Bool,
        maximumFinalBytes: Int,
        tiffNormalizationThresholdBytes: Int
    ) -> (data: Data, typeIdentifier: String)? {
        guard isTIFF else {
            guard candidate.data.count <= maximumFinalBytes else {
                return nil
            }
            return (candidate.data, detectedTypeIdentifier)
        }

        if candidate.data.count <= min(
            maximumFinalBytes,
            max(0, tiffNormalizationThresholdBytes)
        ) {
            return (candidate.data, detectedTypeIdentifier)
        }

        if let pngData = makePNGData(from: source),
           pngData.count <= maximumFinalBytes,
           pngData.count < candidate.data.count {
            return (pngData, UTType.png.identifier)
        }

        guard candidate.data.count <= maximumFinalBytes else {
            return nil
        }
        return (candidate.data, detectedTypeIdentifier)
    }

    private nonisolated static func makePNGData(from source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return output as Data
    }
}
