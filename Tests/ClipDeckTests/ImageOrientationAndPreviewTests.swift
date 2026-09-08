import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClipDeck

@Test(arguments: Array(1...8))
func compatibilityRastersApplyEveryEXIFOrientation(_ orientation: Int) async throws {
    let source = try quadrantImageData(type: .jpeg, orientation: orientation)
    let result = await ImageProcessor().process(.init(typeIdentifier: UTType.jpeg.identifier, data: source))
    let processed = try successfulImage(result)
    #expect(processed.data == source)
    #expect(processed.pixelWidth == ((5...8).contains(orientation) ? 192 : 320))
    #expect(processed.pixelHeight == ((5...8).contains(orientation) ? 320 : 192))
    for type in [UTType.png, .tiff] {
        let encoded = try #require(processed.additionalRepresentations[type.identifier])
        #expect(try quadrantColors(in: encoded) == expectedQuadrants[orientation - 1])
        let decoded = try decodedImage(encoded)
        #expect(decoded.width == processed.pixelWidth)
        #expect(decoded.height == processed.pixelHeight)
    }
    #expect(try quadrantColors(in: processed.thumbnailData) == expectedQuadrants[orientation - 1])
    #expect(try quadrantColors(in: #require(processed.previewData)) == expectedQuadrants[orientation - 1])
}

@Test(arguments: Array(1...8))
func normalizedTIFFAppliesOrientationToPixels(_ orientation: Int) async throws {
    let source = try quadrantImageData(type: .tiff, orientation: orientation)
    var configuration = ImageProcessor.Configuration.default
    configuration.tiffNormalizationThresholdBytes = 0
    let processed = try successfulImage(await ImageProcessor(configuration: configuration).process(
        .init(typeIdentifier: UTType.tiff.identifier, data: source)
    ))
    #expect(processed.typeIdentifier == UTType.png.identifier)
    #expect(try quadrantColors(in: processed.data) == expectedQuadrants[orientation - 1])
    let decoded = try decodedImage(processed.data)
    #expect(decoded.width == processed.pixelWidth)
    #expect(decoded.height == processed.pixelHeight)
}

@Test
func detailPreviewHasItsOwnRetinaResolutionAndByteBudget() async throws {
    let source = try quadrantImageData(type: .png, orientation: 1, width: 1_200, height: 800)
    let processed = try successfulImage(await ImageProcessor().process(
        .init(typeIdentifier: UTType.png.identifier, data: source)
    ))
    let thumbnail = try decodedImage(processed.thumbnailData)
    let previewData = try #require(processed.previewData)
    let preview = try decodedImage(previewData)
    #expect(thumbnail.width == 320)
    #expect(preview.width == 960)
    #expect(preview.height == 640)
    #expect(previewData.count <= ImageProcessor.Configuration.default.maximumPreviewBytes)
    #expect(processed.data == source)

    var smallBudget = ImageProcessor.Configuration.default
    smallBudget.maximumPreviewBytes = 1
    let withoutPreview = try successfulImage(await ImageProcessor(configuration: smallBudget).process(
        .init(typeIdentifier: UTType.png.identifier, data: source)
    ))
    #expect(withoutPreview.previewData == nil)
    #expect(!withoutPreview.thumbnailData.isEmpty)
}

@Test
func pdfPreservesAllPagesAndAddsAnOrientedFirstPagePreview() async throws {
    let original = makePDFData(mediaBox: "0 0 100 50", cropBox: "10 5 90 45", rotation: 90)
    let processed = try successfulImage(await ImageProcessor().process(
        .init(typeIdentifier: UTType.pdf.identifier, data: original)
    ))
    #expect(processed.typeIdentifier == UTType.pdf.identifier)
    #expect(processed.data == original)
    let provider = try #require(CGDataProvider(data: processed.data as CFData))
    #expect(CGPDFDocument(provider)?.numberOfPages == 2)
    #expect(processed.pixelWidth == 80)
    #expect(processed.pixelHeight == 160)
    let raster = try #require(processed.additionalRepresentations[UTType.png.identifier])
    #expect(try quadrantColors(in: raster) == ["R", "R", "R", "R"])
    #expect(processed.previewData != nil)
}

@Test
func pdfRejectsInvalidOrExcessiveInputsAndBoundsTheRaster() async throws {
    let processor = ImageProcessor()
    if case .failure(.invalidFormat) = await processor.process(.init(typeIdentifier: UTType.pdf.identifier, data: Data("not a PDF".utf8))) {} else {
        Issue.record("Invalid PDF must fail before rasterization")
    }
    let excessive = makePDFData(mediaBox: "0 0 100001 100", cropBox: nil, rotation: 0)
    if case .failure(.dimensionsTooLarge) = await processor.process(.init(typeIdentifier: UTType.pdf.identifier, data: excessive)) {} else {
        Issue.record("Extreme PDF dimensions must be rejected")
    }
    let large = makePDFData(mediaBox: "0 0 10000 5000", cropBox: nil, rotation: 0)
    let processed = try successfulImage(await processor.process(.init(typeIdentifier: UTType.pdf.identifier, data: large)))
    #expect(processed.pixelWidth == 2_048)
    #expect(processed.pixelHeight == 1_024)

    var byteLimited = ImageProcessor.Configuration.default
    byteLimited.maximumFinalBytes = 64
    if case .failure(.finalDataTooLarge) = await ImageProcessor(configuration: byteLimited).process(.init(typeIdentifier: UTType.pdf.identifier, data: large)) {} else {
        Issue.record("PDF originals must obey the original-data byte limit")
    }
}

@Test(arguments: [0, 90, 180, 270])
func pdfPageRotationTransformsTheRasterPixels(_ rotation: Int) async throws {
    let quadrants = "1 0 0 rg 0 25 50 25 re f\n0 1 0 rg 50 25 50 25 re f\n0 0 1 rg 0 0 50 25 re f\n1 1 0 rg 50 0 50 25 re f\n"
    let source = makePDFData(mediaBox: "0 0 100 50", cropBox: nil, rotation: rotation, firstPageContent: quadrants)
    let processed = try successfulImage(await ImageProcessor().process(.init(typeIdentifier: UTType.pdf.identifier, data: source)))
    let raster = try #require(processed.additionalRepresentations[UTType.png.identifier])
    let expected = [expectedQuadrants[0], expectedQuadrants[5], expectedQuadrants[2], expectedQuadrants[7]][rotation / 90]
    let actual = try quadrantColors(in: raster)
    #expect(actual == expected)
}

private let expectedQuadrants = [
    ["R", "G", "B", "Y"], ["G", "R", "Y", "B"],
    ["Y", "B", "G", "R"], ["B", "Y", "R", "G"],
    ["R", "B", "G", "Y"], ["B", "R", "Y", "G"],
    ["Y", "G", "B", "R"], ["G", "Y", "R", "B"]
]

private func successfulImage(_ outcome: ImageProcessingOutcome) throws -> ProcessedClipboardImage {
    if case .success(let processed) = outcome { return processed }
    Issue.record("Expected image processing success, got \(outcome)")
    throw ImageProcessingFailure.invalidFormat
}

private func quadrantImageData(type: UTType, orientation: Int, width: Int = 320, height: Int = 192) throws -> Data {
    let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
    var pixels = [UInt8]()
    pixels.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            pixels.append(contentsOf: colors[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)])
        }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyOrientation: orientation,
        kCGImageDestinationLossyCompressionQuality: 1.0
    ] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

private func decodedImage(_ data: Data) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

private func quadrantColors(in data: Data) throws -> [String] {
    let image = try decodedImage(data)
    return try [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map { x, y in
        let pixel = try #require(image.cropping(to: CGRect(x: Int(Double(image.width) * x), y: Int(Double(image.height) * y), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try #require(CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        if bytes[0] > 150 && bytes[1] > 150 { return "Y" }
        if bytes[0] > 150 { return "R" }
        if bytes[1] > 150 { return "G" }
        return "B"
    }
}

private func makePDFData(mediaBox: String, cropBox: String?, rotation: Int, firstPageContent: String? = nil) -> Data {
    let crop = cropBox.map { "/CropBox [\($0)]" } ?? ""
    let red = firstPageContent ?? "1 0 0 rg\n0 0 10000 10000 re f\n"
    let blue = "0 0 1 rg\n0 0 10000 10000 re f\n"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [\(mediaBox)] \(crop) /Rotate \(rotation) /Resources << >> /Contents 4 0 R >>",
        "<< /Length \(red.utf8.count) >>\nstream\n\(red)endstream",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 50] /Resources << >> /Contents 6 0 R >>",
        "<< /Length \(blue.utf8.count) >>\nstream\n\(blue)endstream"
    ]
    var pdf = "%PDF-1.4\n"
    var offsets: [Int] = [0]
    for (index, object) in objects.enumerated() {
        offsets.append(pdf.utf8.count)
        pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let crossReferenceOffset = pdf.utf8.count
    pdf += "xref\n0 \(offsets.count)\n0000000000 65535 f \n"
    for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
    pdf += "trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(crossReferenceOffset)\n%%EOF\n"
    return Data(pdf.utf8)
}
