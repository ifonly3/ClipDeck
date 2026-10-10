import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ClipboardImageSafetyLimits {
    static let maximumFinalBytes = 32 * 1024 * 1024
    static let maximumDimension = 12_000
    static let maximumPixelCount: Int64 = 16_000_000
}

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
    let previewData: Data?
    let additionalRepresentations: [String: Data]

    init(
        data: Data,
        typeIdentifier: String,
        pixelWidth: Int,
        pixelHeight: Int,
        fingerprint: Data,
        thumbnailData: Data,
        previewData: Data? = nil,
        additionalRepresentations: [String: Data] = [:]
    ) {
        self.data = data
        self.typeIdentifier = typeIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fingerprint = fingerprint
        self.thumbnailData = thumbnailData
        self.previewData = previewData
        self.additionalRepresentations = additionalRepresentations
    }
}

enum ImageProcessingFailure: Error, Equatable, Sendable {
    case cancelled
    case rawDataTooLarge
    case finalDataTooLarge
    case invalidFormat
    case dimensionsTooLarge
    case thumbnailCreationFailed
    case compatibilityEncodingFailed
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
        var maximumFinalBytes = ClipboardImageSafetyLimits.maximumFinalBytes
        var maximumDimension = ClipboardImageSafetyLimits.maximumDimension
        var maximumPixelCount = ClipboardImageSafetyLimits.maximumPixelCount
        var thumbnailMaximumDimension = 320
        var previewMaximumDimension = 960
        var maximumPreviewBytes = 4 * 1024 * 1024
        var pdfMaximumRenderDimension = 2_048
        var tiffNormalizationThresholdBytes = 8 * 1024 * 1024
        var maximumCompatibilityBytes = 72 * 1024 * 1024
        var maximumCompatibilityDecodedBytes = 64 * 1024 * 1024
        var maximumOptionalPNGDecodedBytes = 16 * 1024 * 1024
        var maximumOptionalPNGBytes = 16 * 1024 * 1024

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

        if UTType(candidate.typeIdentifier)?.conforms(to: .pdf) == true {
            return processPDF(candidate, configuration: configuration)
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
        let previewData = makePreviewData(from: source, configuration: configuration)

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

        var additionalRepresentations: [String: Data] = [:]
        let decodedByteEstimate = Int64(dimensions.width)
            * Int64(dimensions.height)
            * 4
        let normalizedType = UTType(normalized.typeIdentifier)
        let alreadyHasCompatibleRepresentation = normalizedType?.conforms(to: .png) == true
            || normalizedType?.conforms(to: .tiff) == true
        if !alreadyHasCompatibleRepresentation {
            guard decodedByteEstimate
                    <= Int64(configuration.maximumCompatibilityDecodedBytes),
                  let compatibilityImage = makeOrientedImage(from: source),
                  let tiffData = makeEncodedData(
                      from: compatibilityImage,
                      typeIdentifier: UTType.tiff.identifier
                  ),
                  tiffData.count <= configuration.maximumCompatibilityBytes else {
                return .failure(.compatibilityEncodingFailed)
            }
            additionalRepresentations[UTType.tiff.identifier] = tiffData

            if normalized.typeIdentifier != UTType.png.identifier,
               decodedByteEstimate
                    <= Int64(configuration.maximumOptionalPNGDecodedBytes),
               let pngData = makeEncodedData(
                   from: compatibilityImage,
                   typeIdentifier: UTType.png.identifier
               ),
               pngData.count <= configuration.maximumOptionalPNGBytes {
                additionalRepresentations[UTType.png.identifier] = pngData
            }
        }

        guard !Task.isCancelled else { return .failure(.cancelled) }
        let digest = Data(SHA256.hash(data: normalized.data))
        return .success(
            ProcessedClipboardImage(
                data: normalized.data,
                typeIdentifier: normalized.typeIdentifier,
                pixelWidth: dimensions.width,
                pixelHeight: dimensions.height,
                fingerprint: digest,
                thumbnailData: thumbnailData,
                previewData: previewData,
                additionalRepresentations: additionalRepresentations
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

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
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

        return makeEncodedData(from: thumbnail, typeIdentifier: UTType.png.identifier)
    }

    /// ImageIO's transform also handles mirrored EXIF orientations, and using
    /// the original longest side preserves every source pixel at full size.
    private nonisolated static func makeOrientedImage(from source: CGImageSource) -> CGImage? {
        guard let dimensions = pixelDimensions(from: source), !Task.isCancelled else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(dimensions.width, dimensions.height),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    private nonisolated static func makePreviewData(
        from source: CGImageSource,
        configuration: Configuration
    ) -> Data? {
        guard !Task.isCancelled else { return nil }
        // This preview is independent of the tiny list thumbnail. Its compressed
        // bytes are budgeted by the history store alongside the original image.
        guard let data = makeThumbnailData(
            from: source,
            maximumDimension: configuration.previewMaximumDimension
        ), data.count <= configuration.maximumPreviewBytes else {
            return nil
        }
        return data
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
        guard let image = makeOrientedImage(from: source) else {
            return nil
        }

        return makeEncodedData(
            from: image,
            typeIdentifier: UTType.png.identifier
        )
    }

    private nonisolated static func makeEncodedData(
        from image: CGImage,
        typeIdentifier: String
    ) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            typeIdentifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 1
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return output as Data
    }

    private nonisolated static func processPDF(
        _ candidate: ImageProcessingCandidate,
        configuration: Configuration
    ) -> ImageProcessingOutcome {
        guard candidate.data.count <= configuration.maximumFinalBytes else {
            return .failure(.finalDataTooLarge)
        }
        let renderedImage: CGImage
        switch renderFirstPDFPage(candidate.data, configuration: configuration) {
        case .success(let image): renderedImage = image
        case .failure(let failure): return .failure(failure)
        }
        guard let pngData = makeEncodedData(
                  from: renderedImage,
                  typeIdentifier: UTType.png.identifier
              ),
              pngData.count <= configuration.maximumCompatibilityBytes,
              let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let thumbnailData = makeThumbnailData(
                  from: source,
                  maximumDimension: configuration.thumbnailMaximumDimension
              ) else {
            return .failure(.compatibilityEncodingFailed)
        }
        let previewData = makePreviewData(from: source, configuration: configuration)
        guard !Task.isCancelled else { return .failure(.cancelled) }
        return .success(ProcessedClipboardImage(
            data: candidate.data,
            typeIdentifier: UTType.pdf.identifier,
            pixelWidth: renderedImage.width,
            pixelHeight: renderedImage.height,
            fingerprint: Data(SHA256.hash(data: candidate.data)),
            thumbnailData: thumbnailData,
            previewData: previewData,
            additionalRepresentations: [UTType.png.identifier: pngData]
        ))
    }

    /// Rasterizes page one of a PDF within the decode budget. Shared by capture
    /// and by rebuilding a dropped compatibility raster, so both match.
    private nonisolated static func renderFirstPDFPage(
        _ data: Data,
        configuration: Configuration
    ) -> Result<CGImage, ImageProcessingFailure> {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              !document.isEncrypted || document.isUnlocked,
              let page = document.page(at: 1) else {
            return .failure(.invalidFormat)
        }
        let bounds = page.getBoxRect(.cropBox)
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              abs(bounds.origin.x) <= 100_000, abs(bounds.origin.y) <= 100_000,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0,
              bounds.width <= 100_000, bounds.height <= 100_000,
              configuration.pdfMaximumRenderDimension > 0 else {
            return .failure(.dimensionsTooLarge)
        }
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        let swapsAxes = rotation == 90 || rotation == 270
        let pageWidth = swapsAxes ? bounds.height : bounds.width
        let pageHeight = swapsAxes ? bounds.width : bounds.height
        let longestSide = min(configuration.pdfMaximumRenderDimension, configuration.maximumDimension)
        // Two pixels per PDF point is sharp at typical document sizes. Limit
        // the raster to 2048px and the existing decode budget before allocation.
        let scale = min(2, CGFloat(longestSide) / max(pageWidth, pageHeight))
        let width = max(1, Int(ceil(pageWidth * scale)))
        let height = max(1, Int(ceil(pageHeight * scale)))
        let pixelCount = Int64(width) * Int64(height)
        guard width <= configuration.maximumDimension,
              height <= configuration.maximumDimension,
              pixelCount <= configuration.maximumPixelCount,
              pixelCount <= Int64(configuration.maximumCompatibilityDecodedBytes) / 4,
              !Task.isCancelled else {
            return .failure(Task.isCancelled ? .cancelled : .dimensionsTooLarge)
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return .failure(.thumbnailCreationFailed)
        }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(target)
        context.saveGState()
        // Apply the raster scale explicitly: the PDF drawing transform can
        // center a small page without enlarging it when asked for a larger rect.
        context.scaleBy(x: CGFloat(width) / pageWidth, y: CGFloat(height) / pageHeight)
        context.concatenate(page.getDrawingTransform(
            .cropBox,
            rect: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight),
            rotate: 0,
            preserveAspectRatio: true
        ))
        context.drawPDFPage(page)
        context.restoreGState()
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard let image = context.makeImage() else { return .failure(.compatibilityEncodingFailed) }
        return .success(image)
    }

    /// Rebuilds compatibility rasters that history dropped to stay within its
    /// memory budget. Runs synchronously: restoring an older item is a
    /// user-initiated action, and the source image already decoded at capture.
    nonisolated static func rebuildDerivedRepresentations(
        _ types: [String],
        fromPrimary data: Data,
        typeIdentifier: String,
        configuration: Configuration = .default
    ) -> [String: Data] {
        let wanted = types.filter { $0 == UTType.png.identifier || $0 == UTType.tiff.identifier }
        guard !wanted.isEmpty else { return [:] }
        let image: CGImage?
        if UTType(typeIdentifier)?.conforms(to: .pdf) == true {
            image = try? renderFirstPDFPage(data, configuration: configuration).get()
        } else if let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) {
            image = makeOrientedImage(from: source)
        } else {
            image = nil
        }
        guard let image else { return [:] }
        var rebuilt: [String: Data] = [:]
        for type in wanted {
            rebuilt[type] = makeEncodedData(from: image, typeIdentifier: type)
        }
        return rebuilt
    }
}
