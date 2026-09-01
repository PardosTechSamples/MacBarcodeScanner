import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import Vision

struct PixelBox: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct PixelPoint: Codable {
    let x: Double
    let y: Double
}

struct DetectedBarcode: Codable {
    let format: String
    let rawValue: String
    let boundingBox: PixelBox
    let cornerPoints: [PixelPoint]
}

enum ScannerError: LocalizedError {
    case unreadableImage
    case noImageSource

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "Could not read this image. Try JPEG, PNG, or HEIC."
        case .noImageSource:
            return "The file does not contain a readable image."
        }
    }
}

struct LoadedImage {
    let display: CGImage
    let sensor: CGImage
    let orientation: CGImagePropertyOrientation
}

enum ImageLoader {
    static func load(from url: URL) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ScannerError.noImageSource
        }
        return try load(from: source)
    }

    static func load(from data: Data) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ScannerError.noImageSource
        }
        return try load(from: source)
    }

    private static func load(from source: CGImageSource) throws -> LoadedImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationRaw = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxEdge = max(pixelWidth, pixelHeight, 1)

        guard let sensor = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else {
            throw ScannerError.unreadableImage
        }

        let display: CGImage
        if orientation == .up {
            display = sensor
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxEdge,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ScannerError.unreadableImage
            }
            display = upright
        }

        return LoadedImage(display: display, sensor: sensor, orientation: orientation)
    }

    static func jpegData(from image: CGImage, quality: CGFloat = 0.88) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func resized(_ image: CGImage, maxEdge: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let edge = max(width, height)
        guard edge > maxEdge else { return image }
        let scale = maxEdge / edge
        let output = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(output, from: output.extent) ?? image
    }
}

enum VisionScanner {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let barcodeSymbologies: [VNBarcodeSymbology] = [
        .code128, .code39, .code93, .ean8, .ean13, .upce,
        .qr, .pdf417, .aztec, .dataMatrix, .codabar
    ]

    private struct RawHit {
        let barcode: DetectedBarcode
        let area: Double
        let score: Int
    }

    static func detect(in loaded: LoadedImage, progress: ((String) -> Void)? = nil) -> [DetectedBarcode] {
        var barcodes = detect(in: loaded.sensor, progress: progress).map { mapToDisplay($0, loaded: loaded) }
        progress?("Reading label text…")
        let fromText = ocrSupplement(in: loaded.display, existing: barcodes)
        if !fromText.isEmpty {
            var collected = barcodes.map {
                RawHit(barcode: $0, area: $0.boundingBox.width * $0.boundingBox.height, score: payloadScore($0.rawValue) + 50)
            }
            collected.append(contentsOf: fromText.map {
                RawHit(barcode: $0, area: $0.boundingBox.width * $0.boundingBox.height, score: payloadScore($0.rawValue))
            })
            barcodes = dedupe(collected)
        }
        return barcodes
    }

    static func detect(in image: CGImage, progress: ((String) -> Void)? = nil) -> [DetectedBarcode] {
        var collected: [RawHit] = []
        let lock = NSLock()

        func append(_ hits: [DetectedBarcode]) {
            lock.lock()
            collected.append(contentsOf: hits.compactMap { barcode -> RawHit? in
                guard isPlausible(barcode) else { return nil }
                return RawHit(
                    barcode: barcode,
                    area: barcode.boundingBox.width * barcode.boundingBox.height,
                    score: payloadScore(barcode.rawValue)
                )
            })
            lock.unlock()
        }

        progress?("Scanning full image…")
        append(runVision(image, offsetX: 0, offsetY: 0))

        if let boosted = enhanced(image) {
            progress?("Scanning enhanced image…")
            append(runVision(boosted, offsetX: 0, offsetY: 0))
        }

        if let mono = grayscale(image) {
            progress?("Scanning grayscale…")
            append(runVision(mono, offsetX: 0, offsetY: 0))
        }

        let angles: [CGFloat] = [-2, -1, 1, 2]
        progress?("Scanning rotated image…")
        DispatchQueue.concurrentPerform(iterations: angles.count) { index in
            guard let rotated = rotatedImage(image, degrees: angles[index]) else { return }
            let hits = runVision(rotated.image, offsetX: 0, offsetY: 0).map {
                remap($0, rotated.mapPoint)
            }
            append(hits)
        }

        let tiles = makeTiles(width: image.width, height: image.height)
        progress?("Scanning \(tiles.count) tiles…")
        DispatchQueue.concurrentPerform(iterations: tiles.count) { index in
            let tile = tiles[index]
            guard let cropped = image.cropping(to: tile) else { return }
            append(runVision(cropped, offsetX: tile.origin.x, offsetY: tile.origin.y))
            if let upscaled = scaled(cropped, factor: 2.2) {
                let hits = runVision(upscaled, offsetX: 0, offsetY: 0).map {
                    remapScale($0, factor: 2.2, offsetX: tile.origin.x, offsetY: tile.origin.y)
                }
                append(hits)
            }
        }

        return dedupe(collected)
    }

    private static func mapToDisplay(_ barcode: DetectedBarcode, loaded: LoadedImage) -> DetectedBarcode {
        guard loaded.orientation != .up else { return barcode }
        let corners = barcode.cornerPoints.map { mapPoint($0, loaded: loaded) }
        return boxFromCorners(format: barcode.format, rawValue: barcode.rawValue, corners: corners)
    }

    private static func mapPoint(_ point: PixelPoint, loaded: LoadedImage) -> PixelPoint {
        let w = Double(loaded.sensor.width)
        let h = Double(loaded.sensor.height)
        let x = point.x
        let y = point.y
        switch loaded.orientation {
        case .up: return point
        case .upMirrored: return PixelPoint(x: w - x, y: y)
        case .down: return PixelPoint(x: w - x, y: h - y)
        case .downMirrored: return PixelPoint(x: x, y: h - y)
        case .leftMirrored: return PixelPoint(x: y, y: x)
        case .right: return PixelPoint(x: h - y, y: x)
        case .rightMirrored: return PixelPoint(x: h - y, y: w - x)
        case .left: return PixelPoint(x: y, y: w - x)
        default: return point
        }
    }

    private static func remap(_ barcode: DetectedBarcode, _ map: (CGPoint) -> CGPoint) -> DetectedBarcode {
        let corners = barcode.cornerPoints.map { point -> PixelPoint in
            let mapped = map(CGPoint(x: point.x, y: point.y))
            return PixelPoint(x: mapped.x, y: mapped.y)
        }
        return boxFromCorners(format: barcode.format, rawValue: barcode.rawValue, corners: corners)
    }

    private static func remapScale(
        _ barcode: DetectedBarcode,
        factor: CGFloat,
        offsetX: CGFloat,
        offsetY: CGFloat
    ) -> DetectedBarcode {
        let corners = barcode.cornerPoints.map { point in
            PixelPoint(
                x: point.x / Double(factor) + Double(offsetX),
                y: point.y / Double(factor) + Double(offsetY)
            )
        }
        return boxFromCorners(format: barcode.format, rawValue: barcode.rawValue, corners: corners)
    }

    private static func boxFromCorners(format: String, rawValue: String, corners: [PixelPoint]) -> DetectedBarcode {
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return DetectedBarcode(
            format: format,
            rawValue: rawValue,
            boundingBox: PixelBox(
                x: xs.min() ?? 0,
                y: ys.min() ?? 0,
                width: (xs.max() ?? 0) - (xs.min() ?? 0),
                height: (ys.max() ?? 0) - (ys.min() ?? 0)
            ),
            cornerPoints: corners
        )
    }

    private static func runVision(_ image: CGImage, offsetX: CGFloat, offsetY: CGFloat) -> [DetectedBarcode] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = barcodeSymbologies
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return [] }

        return (request.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !payload.isEmpty else {
                return nil
            }

            let box = visionBoxToPixels(
                observation.boundingBox,
                width: width,
                height: height,
                offsetX: offsetX,
                offsetY: offsetY
            )
            let corners = [
                observation.topLeft,
                observation.topRight,
                observation.bottomRight,
                observation.bottomLeft
            ].map { point in
                PixelPoint(
                    x: Double(point.x * width + offsetX),
                    y: Double((1 - point.y) * height + offsetY)
                )
            }
            return DetectedBarcode(
                format: displayName(observation.symbology),
                rawValue: payload,
                boundingBox: box,
                cornerPoints: corners
            )
        }
    }

    private static func visionBoxToPixels(
        _ box: CGRect,
        width: CGFloat,
        height: CGFloat,
        offsetX: CGFloat,
        offsetY: CGFloat
    ) -> PixelBox {
        PixelBox(
            x: Double(box.origin.x * width + offsetX),
            y: Double((1 - box.origin.y - box.size.height) * height + offsetY),
            width: Double(box.size.width * width),
            height: Double(box.size.height * height)
        )
    }

    private static func makeTiles(width: Int, height: Int) -> [CGRect] {
        let target = 800
        let overlap = 0.42
        let tileW = min(target, width)
        let tileH = min(target, height)
        let stepX = max(1, Int(Double(tileW) * (1 - overlap)))
        let stepY = max(1, Int(Double(tileH) * (1 - overlap)))
        var rects: [CGRect] = []
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let w = min(tileW, width - x)
                let h = min(tileH, height - y)
                if w >= 120 && h >= 120 {
                    rects.append(CGRect(x: x, y: y, width: w, height: h))
                }
                if x + w >= width { break }
                x += stepX
            }
            if y + min(tileH, height - y) >= height { break }
            y += stepY
        }
        return rects
    }

    private static func enhanced(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(1.35, forKey: kCIInputContrastKey)
        filter.setValue(0.05, forKey: kCIInputBrightnessKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: output.extent)
    }

    private static func grayscale(_ image: CGImage) -> CGImage? {
        let output = CIImage(cgImage: image).applyingFilter("CIPhotoEffectMono")
        return ciContext.createCGImage(output, from: output.extent)
    }

    private static func scaled(_ image: CGImage, factor: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        return ciContext.createCGImage(output, from: output.extent)
    }

    private static func rotatedImage(_ image: CGImage, degrees: CGFloat) -> (image: CGImage, mapPoint: (CGPoint) -> CGPoint)? {
        let input = CIImage(cgImage: image)
        let radians = degrees * .pi / 180
        let width = input.extent.width
        let height = input.extent.height
        let transform = CGAffineTransform(translationX: width / 2, y: height / 2)
            .rotated(by: radians)
            .translatedBy(x: -width / 2, y: -height / 2)
        let output = input.transformed(by: transform)
        guard let cgImage = ciContext.createCGImage(output, from: output.extent) else { return nil }
        let extent = output.extent
        let cgHeight = CGFloat(cgImage.height)
        let inverse = transform.inverted()
        let mapPoint: (CGPoint) -> CGPoint = { point in
            let ciPoint = CGPoint(
                x: extent.minX + point.x,
                y: extent.minY + cgHeight - point.y
            )
            let original = ciPoint.applying(inverse)
            return CGPoint(x: original.x, y: height - original.y)
        }
        return (cgImage, mapPoint)
    }

    private static func ocrSupplement(in image: CGImage, existing: [DetectedBarcode]) -> [DetectedBarcode] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let known = Set(existing.map(\.rawValue))
        let alreadyHasCSCO = existing.contains { $0.rawValue.hasPrefix("CSCO+") }
        let cluster = expandedCluster(of: existing, imageWidth: width, imageHeight: height)
        var extras: [DetectedBarcode] = []

        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            let payloads = payloadsFromOCR(text).filter { payload in
                if payload.count < 4 || known.contains(payload) { return false }
                if payload.hasPrefix("CSCO+"), alreadyHasCSCO { return false }
                return true
            }
            guard !payloads.isEmpty else { continue }
            let box = visionBoxToPixels(observation.boundingBox, width: width, height: height, offsetX: 0, offsetY: 0)
            if let cluster, !boxIntersects(box, cluster) { continue }
            let corners = [
                PixelPoint(x: box.x, y: box.y),
                PixelPoint(x: box.x + box.width, y: box.y),
                PixelPoint(x: box.x + box.width, y: box.y + box.height),
                PixelPoint(x: box.x, y: box.y + box.height)
            ]
            for payload in payloads where !extras.contains(where: { $0.rawValue == payload }) {
                extras.append(DetectedBarcode(
                    format: "code_128",
                    rawValue: payload,
                    boundingBox: box,
                    cornerPoints: corners
                ))
            }
        }
        return extras
    }

    private static func expandedCluster(of barcodes: [DetectedBarcode], imageWidth: CGFloat, imageHeight: CGFloat) -> PixelBox? {
        guard !barcodes.isEmpty else { return nil }
        let minX = barcodes.map(\.boundingBox.x).min()!
        let minY = barcodes.map(\.boundingBox.y).min()!
        let maxX = barcodes.map { $0.boundingBox.x + $0.boundingBox.width }.max()!
        let maxY = barcodes.map { $0.boundingBox.y + $0.boundingBox.height }.max()!
        let padX = max(80, (maxX - minX) * 0.2)
        let padY = max(120, (maxY - minY) * 0.25)
        let x = max(0, minX - padX)
        let y = max(0, minY - padY)
        return PixelBox(
            x: x,
            y: y,
            width: min(Double(imageWidth), maxX + padX) - x,
            height: min(Double(imageHeight), maxY + padY) - y
        )
    }

    private static func boxIntersects(_ a: PixelBox, _ b: PixelBox) -> Bool {
        a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y
    }

    private static func payloadsFromOCR(_ text: String) -> [String] {
        let compact = text.replacingOccurrences(of: " ", with: "").uppercased()
        var payloads: [String] = []
        if let match = firstMatch(in: compact, pattern: #"CSCO\+[0-9A-Z]+"#) {
            payloads.append(match)
        }
        if let serial = firstMatch(in: compact, pattern: #"STW[0-9]{5,}[A-Z0-9]*"#) {
            payloads.append("S" + serial)
        }
        return payloads
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func isPlausible(_ barcode: DetectedBarcode) -> Bool {
        let value = barcode.rawValue
        guard value.count >= 4 else { return false }
        if barcode.format == "itf" || barcode.format == "itf14" { return false }
        let weird = value.unicodeScalars.contains { scalar in
            !CharacterSet.alphanumerics.contains(scalar)
                && !"+-._/".unicodeScalars.contains(scalar)
        }
        return !weird
    }

    private static func dedupe(_ hits: [RawHit]) -> [DetectedBarcode] {
        let sorted = hits.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.area > $1.area
        }
        var unique: [DetectedBarcode] = []
        for hit in sorted {
            let isDuplicate = unique.contains { existing in
                if existing.rawValue == hit.barcode.rawValue { return true }
                return boxesOverlap(existing.boundingBox, hit.barcode.boundingBox, threshold: 0.45)
            }
            if !isDuplicate {
                unique.append(hit.barcode)
            }
        }
        return unique
    }

    private static func payloadScore(_ value: String) -> Int {
        var score = 0
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                score += 3
            } else if "+-._/".unicodeScalars.contains(scalar) {
                score += 1
            } else {
                score -= 5
            }
        }
        return score
    }

    private static func boxesOverlap(_ a: PixelBox, _ b: PixelBox, threshold: Double) -> Bool {
        let overlapX = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
        let overlapY = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        let overlapArea = overlapX * overlapY
        let minArea = min(a.width * a.height, b.width * b.height)
        guard minArea > 0 else { return overlapArea > 0 }
        return overlapArea > minArea * threshold
    }

    private static func displayName(_ symbology: VNBarcodeSymbology) -> String {
        switch symbology {
        case .qr: return "qr_code"
        case .aztec: return "aztec"
        case .pdf417: return "pdf417"
        case .dataMatrix: return "data_matrix"
        case .code128: return "code_128"
        case .code39: return "code_39"
        case .code93: return "code_93"
        case .ean8: return "ean_8"
        case .ean13: return "ean_13"
        case .upce: return "upc_e"
        case .i2of5: return "itf"
        case .itf14: return "itf14"
        case .codabar: return "codabar"
        default:
            return symbology.rawValue
                .replacingOccurrences(of: "VNBarcodeSymbology", with: "")
                .replacingOccurrences(of: "Symbology", with: "")
        }
    }
}
