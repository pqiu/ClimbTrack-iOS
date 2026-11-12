@preconcurrency import CoreImage
import CoreGraphics
@preconcurrency import CoreVideo
import Foundation
import ImageIO
import Vision

nonisolated struct PersonAppearanceSample {
    let identityBackend: IdentityMatchingBackend
    let identityRepresentation: PersonIdentityRepresentation
    let colorHistogram: [Float]
    let normalizedCropArea: CGFloat
    let normalizedPersonArea: CGFloat
    let personAspectRatio: CGFloat
}

nonisolated enum PersonIdentityRepresentation {
    case appleFeaturePrint(VNFeaturePrintObservation)
}

nonisolated struct PersonAppearanceMatch {
    let sampleIndex: Int
    let featureSimilarity: Float
    let colorSimilarity: Float
    let combinedSimilarity: Float
}

nonisolated struct PersonAppearanceExtractionOutcome {
    let sample: PersonAppearanceSample?
    let failureReason: String?
}

/// Apple-native appearance extraction that can later be replaced by a person-ReID model.
nonisolated final class PersonAppearanceExtractor: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let sampleDimension = 24

    /// ROI magnification must not turn a tiny original-frame detection into a
    /// seemingly high-quality identity sample. This gate always uses canonical
    /// box size against the original upright frame resolution.
    func identityQualityFailureReason(
        personBox: CGRect,
        orientedImageSize: CGSize
    ) -> String? {
        let clipped = TrackingGeometry.clipped(personBox)
        let torsoWidth = clipped.width * 0.60 * orientedImageSize.width
        let torsoHeight = clipped.height * 0.43 * orientedImageSize.height
        let personArea = clipped.width * clipped.height
        if personArea < 0.0025 {
            return String(format: "ID PERSON AREA %.4f < 0.0025", personArea)
        }
        if torsoWidth < 28 {
            return String(format: "ID TORSO WIDTH %.0fPX < 28PX", torsoWidth)
        }
        if torsoHeight < 36 {
            return String(format: "ID TORSO HEIGHT %.0fPX < 36PX", torsoHeight)
        }
        return nil
    }

    func extract(
        from pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        personBox: CGRect,
        backend: IdentityMatchingBackend
    ) -> PersonAppearanceSample? {
        extractWithDiagnostic(
            from: pixelBuffer,
            orientation: orientation,
            personBox: personBox,
            backend: backend
        ).sample
    }

    func extractWithDiagnostic(
        from pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        personBox: CGRect,
        backend: IdentityMatchingBackend
    ) -> PersonAppearanceExtractionOutcome {
        let orientedImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let torsoBox = torsoRectangle(in: personBox)
        let torsoCropRectangle = imageRectangle(for: torsoBox, in: orientedImage.extent)

        guard torsoCropRectangle.width >= 20 else {
            return PersonAppearanceExtractionOutcome(
                sample: nil,
                failureReason: String(
                    format: "ID CROP WIDTH %.0fPX < 20PX",
                    torsoCropRectangle.width
                )
            )
        }
        guard torsoCropRectangle.height >= 20 else {
            return PersonAppearanceExtractionOutcome(
                sample: nil,
                failureReason: String(
                    format: "ID CROP HEIGHT %.0fPX < 20PX",
                    torsoCropRectangle.height
                )
            )
        }

        let torsoCrop = orientedImage.cropped(to: torsoCropRectangle)
            .transformed(by: CGAffineTransform(
                translationX: -torsoCropRectangle.minX,
                y: -torsoCropRectangle.minY
            ))
        guard let histogram = colorHistogram(for: torsoCrop) else {
            return PersonAppearanceExtractionOutcome(
                sample: nil,
                failureReason: "ID COLOR HISTOGRAM GENERATION FAILED"
            )
        }

        let request = VNGenerateImageFeaturePrintRequest()

        do {
            try VNImageRequestHandler(ciImage: torsoCrop, orientation: .up).perform([request])
        } catch {
            return PersonAppearanceExtractionOutcome(
                sample: nil,
                failureReason: "FEATURE PRINT REQUEST: " + error.localizedDescription
            )
        }

        guard let featurePrint = request.results?.first as? VNFeaturePrintObservation else {
            return PersonAppearanceExtractionOutcome(
                sample: nil,
                failureReason: "FEATURE PRINT RESULT MISSING"
            )
        }

        return PersonAppearanceExtractionOutcome(
            sample: makeSample(
                backend: backend,
                representation: .appleFeaturePrint(featurePrint),
                histogram: histogram,
                torsoBox: torsoBox,
                personBox: personBox
            ),
            failureReason: nil
        )
    }

    func bestMatch(
        for sample: PersonAppearanceSample,
        in gallery: [PersonAppearanceSample]
    ) -> PersonAppearanceMatch? {
        gallery.enumerated().compactMap { index, gallerySample in
            guard let feature = featureSimilarity(between: sample, and: gallerySample) else {
                return nil
            }
            let color = colorSimilarity(between: sample, and: gallerySample)
            // These normalized weights mirror the tracker's 35:20 appearance split.
            let combined = feature * (35 / 55) + color * (20 / 55)
            return PersonAppearanceMatch(
                sampleIndex: index,
                featureSimilarity: feature,
                colorSimilarity: color,
                combinedSimilarity: combined
            )
        }.max { $0.combinedSimilarity < $1.combinedSimilarity }
    }

    func diversity(
        between first: PersonAppearanceSample,
        and second: PersonAppearanceSample
    ) -> Float {
        guard let feature = featureSimilarity(between: first, and: second) else { return 1 }
        let color = colorSimilarity(between: first, and: second)
        let appearanceDifference = 1 - (feature * 0.70 + color * 0.30)
        let areaDifference = normalizedRatioDifference(
            first.normalizedPersonArea,
            second.normalizedPersonArea
        )
        let aspectDifference = normalizedRatioDifference(
            first.personAspectRatio,
            second.personAspectRatio
        )
        return appearanceDifference * 0.80 + areaDifference * 0.10 + aspectDifference * 0.10
    }

    private func featureSimilarity(
        between first: PersonAppearanceSample,
        and second: PersonAppearanceSample
    ) -> Float? {
        switch (first.identityRepresentation, second.identityRepresentation) {
        case let (.appleFeaturePrint(firstPrint), .appleFeaturePrint(secondPrint)):
            var distance: Float = 0
            do {
                try firstPrint.computeDistance(&distance, to: secondPrint)
                // Feature-print distance is not a probability; this is a monotonic score.
                return exp(-distance)
            } catch {
                return nil
            }
        }
    }

    private func makeSample(
        backend: IdentityMatchingBackend,
        representation: PersonIdentityRepresentation,
        histogram: [Float],
        torsoBox: CGRect,
        personBox: CGRect
    ) -> PersonAppearanceSample {
        PersonAppearanceSample(
            identityBackend: backend,
            identityRepresentation: representation,
            colorHistogram: histogram,
            normalizedCropArea: torsoBox.width * torsoBox.height,
            normalizedPersonArea: personBox.width * personBox.height,
            personAspectRatio: personBox.width / max(personBox.height, .leastNonzeroMagnitude)
        )
    }

    private func colorSimilarity(
        between first: PersonAppearanceSample,
        and second: PersonAppearanceSample
    ) -> Float {
        zip(first.colorHistogram, second.colorHistogram)
            .reduce(Float.zero) { $0 + sqrt($1.0 * $1.1) }
    }

    private func normalizedRatioDifference(_ first: CGFloat, _ second: CGFloat) -> Float {
        guard first > 0, second > 0 else { return 1 }
        return Float(min(abs(log(first / second)) / 2, 1))
    }

    private func torsoRectangle(in personBox: CGRect) -> CGRect {
        let clipped = personBox.standardized.intersection(
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )

        // Vision uses a bottom-left origin. Keep the central shoulder/torso
        // region and avoid pose-varying limbs, legs, and background near edges.
        return CGRect(
            x: clipped.minX + clipped.width * 0.20,
            y: clipped.minY + clipped.height * 0.35,
            width: clipped.width * 0.60,
            height: clipped.height * 0.43
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func imageRectangle(for normalizedBox: CGRect, in extent: CGRect) -> CGRect {
        CGRect(
            x: extent.minX + normalizedBox.minX * extent.width,
            y: extent.minY + normalizedBox.minY * extent.height,
            width: normalizedBox.width * extent.width,
            height: normalizedBox.height * extent.height
        ).integral.intersection(extent)
    }

    private func colorHistogram(for image: CIImage) -> [Float]? {
        let size = CGFloat(sampleDimension)
        let resized = image.transformed(by: CGAffineTransform(
            scaleX: size / image.extent.width,
            y: size / image.extent.height
        ))
        var pixels = [UInt8](repeating: 0, count: sampleDimension * sampleDimension * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

        context.render(
            resized,
            toBitmap: &pixels,
            rowBytes: sampleDimension * 4,
            bounds: CGRect(x: 0, y: 0, width: sampleDimension, height: sampleDimension),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        // 24 chromatic bins (12 hue x 2 saturation) plus 6 grayscale/value bins.
        var histogram = [Float](repeating: 0, count: 30)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Float(pixels[index]) / 255
            let green = Float(pixels[index + 1]) / 255
            let blue = Float(pixels[index + 2]) / 255
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let delta = maximum - minimum
            let saturation = maximum > 0 ? delta / maximum : 0

            if saturation < 0.15 || delta == 0 {
                let valueBin = min(5, Int(maximum * 6))
                histogram[24 + valueBin] += 1
                continue
            }

            let hue: Float
            if maximum == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            let normalizedHue = (hue / 6 + 1).truncatingRemainder(dividingBy: 1)
            let hueBin = min(11, Int(normalizedHue * 12))
            let saturationBin = saturation >= 0.55 ? 1 : 0
            histogram[hueBin * 2 + saturationBin] += 1
        }

        let total = histogram.reduce(0, +)
        guard total > 0 else { return nil }
        return histogram.map { $0 / total }
    }
}
