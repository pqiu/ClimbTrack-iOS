@preconcurrency import AVFoundation
@preconcurrency import CoreImage
import CoreGraphics
@preconcurrency import CoreVideo
import Foundation
import UIKit

/// Generates selected presentation variants after capture so live tracking only
/// competes with one camera-frequency master encoder.
nonisolated final class RecordingVariantExporter: @unchecked Sendable {
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    func export(
        masterURL: URL,
        metadata: [RecordingMetadataSnapshot],
        mode: RecordingOutputMode,
        outputURL: URL,
        completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        Task.detached { [self] in
            do {
                try await renderVariant(
                    masterURL: masterURL,
                    metadata: metadata,
                    mode: mode,
                    outputURL: outputURL
                )
                completion(.success(outputURL))
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                completion(.failure(error))
            }
        }
    }

    private func renderVariant(
        masterURL: URL,
        metadata: [RecordingMetadataSnapshot],
        mode: RecordingOutputMode,
        outputURL: URL
    ) async throws {
        let asset = AVURLAsset(url: masterURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingVariantExportError.missingVideoTrack
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let naturalSize = try await videoTrack.load(.naturalSize)
        let outputSize = CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height))
        guard outputSize.width > 0, outputSize.height > 0 else {
            throw RecordingVariantExportError.invalidVideoDimensions
        }

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw RecordingVariantExportError.readerConfigurationFailed
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
            )
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let estimatedDataRate = try await videoTrack.load(.estimatedDataRate)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(outputSize.width),
                AVVideoHeightKey: Int(outputSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(Int(estimatedDataRate), 6_000_000),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw RecordingVariantExportError.writerConfigurationFailed
        }
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        var audioInput: AVAssetWriterInput?
        if let audioTrack, audioOutput != nil {
            let formatDescriptions = try await audioTrack.load(.formatDescriptions)
            let streamDescription = formatDescriptions.first.flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: streamDescription?.mSampleRate ?? 44_100,
                    AVNumberOfChannelsKey: Int(streamDescription?.mChannelsPerFrame ?? 1),
                    AVEncoderBitRateKey: 128_000
                ]
            )
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? RecordingVariantExportError.startFailed
        }
        let sourceStart = try await videoTrack.load(.timeRange).start
        writer.startSession(atSourceTime: sourceStart)

        var metadataIndex = 0
        while let sampleBuffer = videoOutput.copyNextSampleBuffer() {
            try waitUntilReady(videoInput, writer: writer)
            guard let source = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let pool = adaptor.pixelBufferPool else {
                throw RecordingVariantExportError.pixelBufferUnavailable
            }
            var destination: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
                  let destination else {
                throw RecordingVariantExportError.pixelBufferUnavailable
            }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let relativeTime = max(0, CMTimeGetSeconds(presentationTime - sourceStart))
            let selection = metadataSelection(
                at: relativeTime,
                metadata: metadata,
                index: &metadataIndex,
                mode: mode
            )
            render(
                source,
                into: destination,
                frame: selection.frame,
                gestureStatus: selection.gestureStatus,
                gestureDiagnosticText: selection.gestureDiagnosticText,
                crop: selection.crop,
                mode: mode,
                outputSize: outputSize
            )
            guard adaptor.append(destination, withPresentationTime: presentationTime) else {
                throw writer.error ?? RecordingVariantExportError.appendFailed
            }
        }
        videoInput.markAsFinished()

        if let audioOutput, let audioInput {
            while let sampleBuffer = audioOutput.copyNextSampleBuffer() {
                try waitUntilReady(audioInput, writer: writer)
                guard audioInput.append(sampleBuffer) else {
                    throw writer.error ?? RecordingVariantExportError.appendFailed
                }
            }
            audioInput.markAsFinished()
        }

        guard reader.status == .completed else {
            throw reader.error ?? RecordingVariantExportError.readFailed
        }
        try await finish(writer)
    }

    private struct FrameSelection {
        let frame: PersonDetectionFrame
        let gestureStatus: GestureStatus?
        let gestureDiagnosticText: String?
        let crop: CGRect
    }

    private func metadataSelection(
        at timestamp: TimeInterval,
        metadata: [RecordingMetadataSnapshot],
        index: inout Int,
        mode: RecordingOutputMode
    ) -> FrameSelection {
        guard !metadata.isEmpty else {
            return FrameSelection(
                frame: .empty,
                gestureStatus: nil,
                gestureDiagnosticText: nil,
                crop: TrackingGeometry.unitRectangle
            )
        }
        while index + 1 < metadata.count,
              metadata[index + 1].timestamp <= timestamp {
            index += 1
        }
        let current = metadata[index]
        let crop: CGRect
        switch mode {
        case .zoomedTracking:
            crop = TrackingGeometry.clipped(current.frame.trackingMetadata.displayCrop)
        case .smoothZoomedClean:
            if index + 1 < metadata.count {
                let next = metadata[index + 1]
                let interval = next.timestamp - current.timestamp
                let progress = interval > 0
                    ? CGFloat(min(1, max(0, (timestamp - current.timestamp) / interval)))
                    : 0
                crop = interpolatedCrop(
                    from: current.frame.trackingMetadata.displayCrop,
                    to: next.frame.trackingMetadata.displayCrop,
                    progress: progress
                )
            } else {
                crop = TrackingGeometry.clipped(current.frame.trackingMetadata.displayCrop)
            }
        }
        return FrameSelection(
            frame: current.frame,
            gestureStatus: current.gestureStatus,
            gestureDiagnosticText: current.gestureDiagnosticText,
            crop: crop
        )
    }

    private func interpolatedCrop(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        let start = TrackingGeometry.clipped(start)
        let end = TrackingGeometry.clipped(end)
        return TrackingGeometry.centeredRectangle(
            center: CGPoint(
                x: start.midX + (end.midX - start.midX) * progress,
                y: start.midY + (end.midY - start.midY) * progress
            ),
            size: CGSize(
                width: start.width + (end.width - start.width) * progress,
                height: start.height + (end.height - start.height) * progress
            )
        )
    }

    private func render(
        _ source: CVPixelBuffer,
        into destination: CVPixelBuffer,
        frame: PersonDetectionFrame,
        gestureStatus: GestureStatus?,
        gestureDiagnosticText: String?,
        crop: CGRect,
        mode: RecordingOutputMode,
        outputSize: CGSize
    ) {
        let normalized = CIImage(cvPixelBuffer: source)
        let cropRectangle = TrackingGeometry.imageRectangle(for: crop, in: normalized.extent)
        let cropped = normalized.cropped(to: cropRectangle).transformed(
            by: CGAffineTransform(translationX: -cropRectangle.minX, y: -cropRectangle.minY)
        )
        let rendered = cropped.transformed(by: CGAffineTransform(
            scaleX: outputSize.width / cropped.extent.width,
            y: outputSize.height / cropped.extent.height
        ))
        imageContext.render(
            rendered,
            to: destination,
            bounds: CGRect(origin: .zero, size: outputSize),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        switch mode {
        case .zoomedTracking:
            drawDebugOverlay(
                frame,
                gestureStatus: gestureStatus,
                gestureDiagnosticText: gestureDiagnosticText,
                displayCrop: crop,
                into: destination,
                outputSize: outputSize
            )
        case .smoothZoomedClean:
            break
        }
    }

    private func drawPeopleBoxes(
        _ frame: PersonDetectionFrame,
        displayCrop: CGRect,
        into pixelBuffer: CVPixelBuffer,
        outputSize: CGSize
    ) {
        withGraphicsContext(for: pixelBuffer, outputSize: outputSize) {
            for detection in frame.detections {
                guard let rectangle = outputRectangle(
                    for: detection.normalizedBoundingBox,
                    displayCrop: displayCrop,
                    outputSize: outputSize
                ) else { continue }
                let isTarget = frame.targetPresentation?.matchedDetectionID == detection.id
                stroke(rectangle, color: isTarget ? .systemRed : .systemGreen, width: isTarget ? 8 : 5)
            }
        }
    }

    private func drawDebugOverlay(
        _ frame: PersonDetectionFrame,
        gestureStatus: GestureStatus?,
        gestureDiagnosticText: String?,
        displayCrop: CGRect,
        into pixelBuffer: CVPixelBuffer,
        outputSize: CGSize
    ) {
        withGraphicsContext(for: pixelBuffer, outputSize: outputSize) {
            for detection in frame.detections {
                guard let rectangle = outputRectangle(
                    for: detection.normalizedBoundingBox,
                    displayCrop: displayCrop,
                    outputSize: outputSize
                ) else { continue }
                let isTarget = frame.targetPresentation?.matchedDetectionID == detection.id
                let color: UIColor = isTarget ? .systemRed : .systemGreen
                stroke(rectangle, color: color, width: isTarget ? 8 : 5)
                if let skeleton = detection.skeleton {
                    for connection in PersonSkeleton.limbConnections {
                        guard let first = skeleton.joints[connection.0],
                              let second = skeleton.joints[connection.1],
                              let start = outputPoint(
                                for: first.location,
                                displayCrop: displayCrop,
                                outputSize: outputSize
                              ),
                              let end = outputPoint(
                                for: second.location,
                                displayCrop: displayCrop,
                                outputSize: outputSize
                              ) else { continue }
                        let path = UIBezierPath()
                        path.move(to: start)
                        path.addLine(to: end)
                        path.lineWidth = isTarget ? 8 : 5
                        color.setStroke()
                        path.stroke()
                    }
                    let jointRadius = max(3, outputSize.width / 390 * 3)
                    for joint in skeleton.joints.values {
                        guard let point = outputPoint(
                            for: joint.location,
                            displayCrop: displayCrop,
                            outputSize: outputSize
                        ) else { continue }
                        color.setFill()
                        UIBezierPath(ovalIn: CGRect(
                            x: point.x - jointRadius,
                            y: point.y - jointRadius,
                            width: jointRadius * 2,
                            height: jointRadius * 2
                        )).fill()
                    }
                }
            }
            if frame.trackingMetadata.analysisRegion != TrackingGeometry.unitRectangle,
               let rectangle = outputRectangle(
                for: frame.trackingMetadata.analysisRegion,
                displayCrop: displayCrop,
                outputSize: outputSize
               ) {
                stroke(rectangle, color: .cyan, width: 5, dash: [14, 10])
            }
            if let uncertain = frame.targetPresentation?.uncertainBoundingBox,
               let rectangle = outputRectangle(
                for: uncertain,
                displayCrop: displayCrop,
                outputSize: outputSize
               ) {
                stroke(rectangle, color: .systemOrange, width: 8, dash: [18, 12])
            }
        }
    }

    private func withGraphicsContext(
        for pixelBuffer: CVPixelBuffer,
        outputSize: CGSize,
        drawing: () -> Void
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: baseAddress,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return }
        context.saveGState()
        context.translateBy(x: 0, y: outputSize.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        drawing()
        UIGraphicsPopContext()
        context.restoreGState()
    }

    private func outputRectangle(
        for canonicalRectangle: CGRect,
        displayCrop: CGRect,
        outputSize: CGSize
    ) -> CGRect? {
        guard let local = TrackingGeometry.localRectangle(
            fromCanonical: canonicalRectangle,
            in: displayCrop
        ) else { return nil }
        return CGRect(
            x: local.minX * outputSize.width,
            y: (1 - local.maxY) * outputSize.height,
            width: local.width * outputSize.width,
            height: local.height * outputSize.height
        )
    }

    private func outputPoint(
        for canonicalPoint: CGPoint,
        displayCrop: CGRect,
        outputSize: CGSize
    ) -> CGPoint? {
        guard displayCrop.contains(canonicalPoint) else { return nil }
        return CGPoint(
            x: (canonicalPoint.x - displayCrop.minX) / displayCrop.width * outputSize.width,
            y: (1 - (canonicalPoint.y - displayCrop.minY) / displayCrop.height) * outputSize.height
        )
    }

    private func stroke(
        _ rectangle: CGRect,
        color: UIColor,
        width: CGFloat,
        dash: [CGFloat] = []
    ) {
        let path = UIBezierPath(rect: rectangle)
        path.lineWidth = width
        if !dash.isEmpty { path.setLineDash(dash, count: dash.count, phase: 0) }
        color.setStroke()
        path.stroke()
    }

    private func waitUntilReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw writer.error ?? RecordingVariantExportError.appendFailed
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    private func finish(_ writer: AVAssetWriter) async throws {
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? RecordingVariantExportError.finishFailed
        }
    }
}

nonisolated private enum RecordingVariantExportError: LocalizedError {
    case missingVideoTrack
    case invalidVideoDimensions
    case readerConfigurationFailed
    case writerConfigurationFailed
    case startFailed
    case pixelBufferUnavailable
    case appendFailed
    case readFailed
    case finishFailed

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack: "The master recording has no video track."
        case .invalidVideoDimensions: "The master recording has invalid dimensions."
        case .readerConfigurationFailed: "The recorded video could not be read for export."
        case .writerConfigurationFailed: "A selected video format could not be configured."
        case .startFailed: "The selected video export could not start."
        case .pixelBufferUnavailable: "A video frame could not be allocated during export."
        case .appendFailed: "A video frame could not be written during export."
        case .readFailed: "The master recording could not be fully read."
        case .finishFailed: "The selected video export could not be finalized."
        }
    }
}
