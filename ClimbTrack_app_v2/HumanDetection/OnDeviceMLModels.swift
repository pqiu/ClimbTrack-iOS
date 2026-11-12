@preconcurrency import CoreImage
import CoreML
import Foundation

nonisolated struct OnDevicePersonResult: Sendable {
    let boundingBox: CGRect
    let confidence: Float
}

/// Model input plus the unpadding transform needed to return detections to the
/// original analysis crop. All detector boxes supplied here use normalized
/// bottom-left coordinates, matching Vision and the rest of the app.
private nonisolated struct LetterboxedModelInput {
    let pixelBuffer: CVPixelBuffer
    let contentRectangle: CGRect

    func sourceRectangle(fromModelRectangle box: CGRect) -> CGRect {
        guard contentRectangle.width > 0, contentRectangle.height > 0 else {
            return .null
        }
        return CGRect(
            x: (box.minX - contentRectangle.minX) / contentRectangle.width,
            y: (box.minY - contentRectangle.minY) / contentRectangle.height,
            width: box.width / contentRectangle.width,
            height: box.height / contentRectangle.height
        ).intersection(TrackingGeometry.unitRectangle)
    }
}

private nonisolated enum ModelImageLetterboxer {
    /// Preserve camera-crop proportions and use the conventional neutral-gray
    /// detector padding instead of stretching a portrait image into a square.
    static func makeInput(
        from image: CIImage,
        width: Int,
        height: Int,
        context: CIContext
    ) throws -> LetterboxedModelInput {
        guard image.extent.width > 0, image.extent.height > 0,
              width > 0, height > 0 else {
            throw ModelRuntimeError.imageConversionFailed
        }
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw ModelRuntimeError.imageConversionFailed
        }

        let targetSize = CGSize(width: width, height: height)
        let scale = min(
            targetSize.width / image.extent.width,
            targetSize.height / image.extent.height
        )
        let contentSize = CGSize(
            width: image.extent.width * scale,
            height: image.extent.height * scale
        )
        // Core Image uses a bottom-left origin. Moving the image upward
        // reproduces YOLOX's top-left placement and right/bottom padding.
        let contentOrigin = CGPoint(x: 0, y: targetSize.height - contentSize.height)
        let contentRectangle = CGRect(
            x: contentOrigin.x,
            y: contentOrigin.y,
            width: contentSize.width,
            height: contentSize.height
        )
        let normalizedImage = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX,
            y: -image.extent.minY
        ))
        let positionedImage = normalizedImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: contentRectangle.minX,
                y: contentRectangle.minY
            ))
        let targetRectangle = CGRect(origin: .zero, size: targetSize)
        let padding = CIImage(color: CIColor(
            red: 114 / 255,
            green: 114 / 255,
            blue: 114 / 255,
            alpha: 1
        )).cropped(to: targetRectangle)
        context.render(
            positionedImage.composited(over: padding),
            to: pixelBuffer,
            bounds: targetRectangle,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return LetterboxedModelInput(
            pixelBuffer: pixelBuffer,
            contentRectangle: CGRect(
                x: contentRectangle.minX / targetSize.width,
                y: contentRectangle.minY / targetSize.height,
                width: contentRectangle.width / targetSize.width,
                height: contentRectangle.height / targetSize.height
            )
        )
    }
}

nonisolated enum YOLOXVariant: Sendable {
    case nano
    case tiny
    case small

    var modelName: String {
        switch self {
        case .nano: "YOLOXNano"
        case .tiny: "YOLOXTiny"
        case .small: "YOLOXS"
        }
    }

    var displayName: String {
        switch self {
        case .nano: "YOLOX-Nano"
        case .tiny: "YOLOX-Tiny"
        case .small: "YOLOX-S"
        }
    }
}

/// Official YOLOX COCO models exported with their raw inference head. YOLOX
/// applies sigmoid to objectness and class scores in the model; this wrapper
/// performs the official grid/stride decode and person-only NMS.
nonisolated final class YOLOXDetector: @unchecked Sendable {
    private let variant: YOLOXVariant
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var modelResult: Result<MLModel, Error>?
    private let confidenceThreshold: Float = 0.25
    private let nmsThreshold: CGFloat = 0.45
    private let channelCount = 85
    private let strides = [8, 16, 32]

    init(variant: YOLOXVariant) {
        self.variant = variant
    }

    func detect(in image: CIImage) throws -> [OnDevicePersonResult] {
        let model = try loadModel()
        guard let inputDescription = model.modelDescription.inputDescriptionsByName.first,
              let constraint = inputDescription.value.imageConstraint else {
            throw ModelRuntimeError.unsupportedInput(
                "\(variant.displayName) expects a BGR image input"
            )
        }
        let letterboxedInput = try ModelImageLetterboxer.makeInput(
            from: image,
            width: constraint.pixelsWide,
            height: constraint.pixelsHigh,
            context: context
        )
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            inputDescription.key: MLFeatureValue(
                pixelBuffer: letterboxedInput.pixelBuffer
            )
        ])
        let prediction = try model.prediction(from: provider)
        let expectedCandidateCount = strides.reduce(0) { count, stride in
            count + (constraint.pixelsWide / stride) * (constraint.pixelsHigh / stride)
        }
        guard let output = prediction.featureNames.compactMap({
            prediction.featureValue(for: $0)?.multiArrayValue
        }).first(where: {
            $0.shape.map(\.intValue) == [1, expectedCandidateCount, channelCount]
        }) else {
            throw ModelRuntimeError.unsupportedOutput(
                "\(variant.displayName) 1 x \(expectedCandidateCount) x 85 output is missing"
            )
        }

        func value(candidate: Int, channel: Int) -> Float {
            // Core ML may return a non-contiguous MLMultiArray on device.
            // Dimension-aware indexing lets MLMultiArray apply its internal
            // strides safely; treating those strides as a flat subscript can
            // raise an Objective-C bounds exception and abort the process.
            output[
                [
                    NSNumber(value: 0),
                    NSNumber(value: candidate),
                    NSNumber(value: channel)
                ]
            ].floatValue
        }

        var candidates: [OnDevicePersonResult] = []
        candidates.reserveCapacity(16)
        var candidateOffset = 0
        for stride in strides {
            let gridWidth = constraint.pixelsWide / stride
            let gridHeight = constraint.pixelsHigh / stride
            let levelCount = gridWidth * gridHeight
            for levelIndex in 0..<levelCount {
                let candidateIndex = candidateOffset + levelIndex
                let confidence = value(candidate: candidateIndex, channel: 4)
                    * value(candidate: candidateIndex, channel: 5)
                guard confidence >= confidenceThreshold else { continue }

                let gridX = levelIndex % gridWidth
                let gridY = levelIndex / gridWidth
                let centerX = (CGFloat(value(candidate: candidateIndex, channel: 0))
                    + CGFloat(gridX)) * CGFloat(stride) / CGFloat(constraint.pixelsWide)
                let centerY = (CGFloat(value(candidate: candidateIndex, channel: 1))
                    + CGFloat(gridY)) * CGFloat(stride) / CGFloat(constraint.pixelsHigh)
                let width = CGFloat(Foundation.exp(
                    Double(value(candidate: candidateIndex, channel: 2))
                )) * CGFloat(stride) / CGFloat(constraint.pixelsWide)
                let height = CGFloat(Foundation.exp(
                    Double(value(candidate: candidateIndex, channel: 3))
                )) * CGFloat(stride) / CGFloat(constraint.pixelsHigh)
                let modelBox = CGRect(
                    x: centerX - width / 2,
                    y: 1 - centerY - height / 2,
                    width: width,
                    height: height
                )
                let box = letterboxedInput.sourceRectangle(fromModelRectangle: modelBox)
                guard box.width > 0, box.height > 0 else { continue }
                candidates.append(OnDevicePersonResult(
                    boundingBox: box,
                    confidence: confidence
                ))
            }
            candidateOffset += levelCount
        }

        return nonMaximumSuppression(candidates.sorted {
            $0.confidence > $1.confidence
        })
    }

    private func loadModel() throws -> MLModel {
        if let modelResult { return try modelResult.get() }
        let result = Result { try BundledModelLoader.load(named: variant.modelName) }
        modelResult = result
        return try result.get()
    }

    private func nonMaximumSuppression(
        _ candidates: [OnDevicePersonResult]
    ) -> [OnDevicePersonResult] {
        var accepted: [OnDevicePersonResult] = []
        for candidate in candidates {
            guard !accepted.contains(where: {
                TargetAssociation.intersectionOverUnion(
                    candidate.boundingBox,
                    $0.boundingBox
                ) >= nmsThreshold
            }) else { continue }
            accepted.append(candidate)
        }
        return accepted
    }
}

private nonisolated enum BundledModelLoader {
    static func load(named name: String) throws -> MLModel {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            throw ModelRuntimeError.modelNotBundled(name)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try MLModel(contentsOf: url, configuration: configuration)
    }
}

private nonisolated enum ModelRuntimeError: LocalizedError {
    case modelNotBundled(String)
    case unsupportedInput(String)
    case unsupportedOutput(String)
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .modelNotBundled(let name): "\(name).mlmodelc is not bundled"
        case .unsupportedInput(let detail), .unsupportedOutput(let detail): detail
        case .imageConversionFailed: "The camera crop could not be converted for Core ML"
        }
    }
}
