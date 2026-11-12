@preconcurrency import AVFoundation
import Combine
@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation
import ImageIO
import Vision

@MainActor
final class HumanDetectionService: ObservableObject {
    @Published private(set) var latestFrame: PersonDetectionFrame = .empty
    @Published private(set) var currentTarget: TrackedTarget?
    @Published private(set) var isPreparingTarget = false
    @Published private(set) var gestureStatus: GestureStatus?
    @Published private(set) var gestureDiagnosticText: String?
    @Published private(set) var gestureCommandEvent: GestureCommandEvent?

    private let detector: VisionHumanDetector
    private let idleFramingBridge: IdleFramingBridge
    private var gestureDiagnosticLastChangedAt = Date.distantPast

    init(
        cameraManager: CameraManager,
        zoomTuningBridge: ZoomTuningBridge,
        trackingTuningBridge: TrackingTuningBridge,
        idleFramingBridge: IdleFramingBridge
    ) {
        self.idleFramingBridge = idleFramingBridge
        let detector = VisionHumanDetector(
            processingInterval: 0.125,
            zoomTuningBridge: zoomTuningBridge,
            trackingTuningBridge: trackingTuningBridge,
            idleFramingBridge: idleFramingBridge
        )
        self.detector = detector

        detector.onResult = { [weak self] frame, target in
            guard let service = self else { return }
            Task { @MainActor [service] in
                service.currentTarget = target
                service.latestFrame = frame
            }
        }

        detector.onGestureStatus = { [weak self] status in
            guard let service = self else { return }
            Task { @MainActor [service] in
                service.gestureStatus = status
            }
        }

        detector.onGestureDiagnostic = { [weak self] diagnosticText in
            guard let service = self else { return }
            Task { @MainActor [service] in
                guard service.gestureDiagnosticText != diagnosticText else { return }
                let now = Date()
                if diagnosticText != nil,
                   service.gestureDiagnosticText != nil,
                   now.timeIntervalSince(service.gestureDiagnosticLastChangedAt) < 1.0 {
                    return
                }
                service.gestureDiagnosticText = diagnosticText
                service.gestureDiagnosticLastChangedAt = now
            }
        }

        detector.onGestureCommand = { [weak self] command in
            guard let service = self else { return }
            Task { @MainActor [service] in
                service.gestureCommandEvent = GestureCommandEvent(command: command)
            }
        }

        cameraManager.setAnalysisFrameHandler { [weak detector] sampleBuffer, orientation in
            detector?.submit(sampleBuffer: sampleBuffer, orientation: orientation)
        }
    }

    func clear() {
        detector.clearTarget()
        latestFrame = .empty
        currentTarget = nil
        isPreparingTarget = false
        gestureStatus = nil
        gestureDiagnosticText = nil
        gestureDiagnosticLastChangedAt = .distantPast
        gestureCommandEvent = nil
    }

    var hasTarget: Bool {
        currentTarget != nil || isPreparingTarget
    }

    func prepareTarget(
        detectionID: UUID,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard !hasTarget else {
            completion(false)
            return
        }

        isPreparingTarget = true
        detector.prepareTarget(detectionID: detectionID) { [weak self] wasPrepared in
            guard let service = self else { return }
            Task { @MainActor [service] in
                service.isPreparingTarget = false
                completion(wasPrepared)
            }
        }
    }

    func activatePreparedTarget() {
        detector.activateTarget()
    }

    func clearTarget() {
        detector.clearTarget()
        currentTarget = nil
        isPreparingTarget = false
        applyIdleFramingToLatestFrame()
    }

    /// Makes slider changes visible immediately; Vision consumes the same crop
    /// from the bridge on its next scheduled analysis frame.
    func refreshIdleFraming() {
        guard !hasTarget else { return }
        applyIdleFramingToLatestFrame()
    }

    private func applyIdleFramingToLatestFrame() {
        let idleCrop = idleFramingBridge.crop()
        latestFrame = PersonDetectionFrame(
            detections: latestFrame.detections,
            orientedImageSize: latestFrame.orientedImageSize,
            trackingMetadata: TrackingFrameMetadata(
                timestamp: latestFrame.trackingMetadata.timestamp,
                analysisMode: .fullFrame,
                analysisRegion: idleCrop,
                displayCrop: idleCrop,
                zoomFactor: 1 / idleCrop.width,
                canonicalTargetBox: nil,
                targetConfidence: nil,
                targetVisibility: nil
            )
        )
    }

    func resetGestureRecognition(usesCooldown: Bool) {
        detector.resetGestureRecognition(usesCooldown: usesCooldown)
        gestureStatus = nil
        gestureDiagnosticText = nil
        gestureDiagnosticLastChangedAt = .distantPast
    }

    func setCameraMotionActive(_ isActive: Bool) {
        detector.setCameraMotionActive(isActive)
    }
}

private final class VisionHumanDetector: @unchecked Sendable {
    private struct DetectionResult {
        let frame: PersonDetectionFrame
        let bodyObservations: [VNHumanBodyPoseObservation]
        let bodyObservationRegion: CGRect
    }

    private struct LatestContext {
        var frame: PersonDetectionFrame
        let pixelBuffer: CVPixelBuffer
        let orientation: CGImagePropertyOrientation
        let timestamp: TimeInterval
    }

    nonisolated(unsafe) var onResult: (@Sendable (
        PersonDetectionFrame,
        TrackedTarget?
    ) -> Void)?
    nonisolated(unsafe) var onGestureStatus: (@Sendable (GestureStatus?) -> Void)?
    nonisolated(unsafe) var onGestureDiagnostic: (@Sendable (String?) -> Void)?
    nonisolated(unsafe) var onGestureCommand: (@Sendable (GestureCommand) -> Void)?

    private let processingQueue = DispatchQueue(
        label: "com.pengqiu.ClimbTrack.human-detection",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private nonisolated let targetTracker: TargetTracker
    private nonisolated let multiScaleCoordinator: MultiScaleTrackingCoordinator
    private nonisolated let gestureRecognizer = PersonGestureRecognizer()
    private nonisolated let yoloxNanoDetector = YOLOXDetector(variant: .nano)
    private nonisolated let yoloxTinyDetector = YOLOXDetector(variant: .tiny)
    private nonisolated let yoloxSmallDetector = YOLOXDetector(variant: .small)
    private nonisolated let trackingTuningBridge: TrackingTuningBridge
    private let processingInterval: TimeInterval
    private nonisolated(unsafe) var isProcessing = false
    private nonisolated(unsafe) var lastProcessingStart: TimeInterval = 0
    private nonisolated(unsafe) var lastLoggedError: String?
    private nonisolated(unsafe) var latestContext: LatestContext?

    init(
        processingInterval: TimeInterval,
        zoomTuningBridge: ZoomTuningBridge,
        trackingTuningBridge: TrackingTuningBridge,
        idleFramingBridge: IdleFramingBridge
    ) {
        self.processingInterval = processingInterval
        self.trackingTuningBridge = trackingTuningBridge
        targetTracker = TargetTracker(tuningBridge: trackingTuningBridge)
        multiScaleCoordinator = MultiScaleTrackingCoordinator(
            zoomTuningBridge: zoomTuningBridge,
            idleFramingBridge: idleFramingBridge
        )
    }

    nonisolated func submit(
        sampleBuffer: CMSampleBuffer,
        orientation: CGImagePropertyOrientation
    ) {
        let now = ProcessInfo.processInfo.systemUptime

        stateLock.lock()
        guard !isProcessing, now - lastProcessingStart >= processingInterval else {
            stateLock.unlock()
            return
        }
        isProcessing = true
        lastProcessingStart = now
        stateLock.unlock()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            finishProcessing()
            return
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let captureTimestamp = CMTimeGetSeconds(presentationTime)
        let timestamp = captureTimestamp.isFinite && captureTimestamp >= 0
            ? captureTimestamp
            : now
        let sendablePixelBuffer = SendablePixelBuffer(value: pixelBuffer)

        processingQueue.async { [weak self] in
            guard let self else { return }
            defer { self.finishProcessing() }

            let initialTracking = self.targetTracker.output()
            let initialMode = self.gestureMode(for: initialTracking)
            let analysisPlan = self.multiScaleCoordinator.analysisPlan(for: initialTracking)
            let includesBodyPose = self.gestureRecognizer.shouldAnalyze(
                mode: initialMode,
                timestamp: timestamp
            )
            // Idle pose analysis follows the manual display crop. Preserve the
            // established full-frame pose path while a target is being tracked.
            let bodyPoseRegion = initialMode == .unlocked
                ? analysisPlan.region
                : TrackingGeometry.unitRectangle
            let detectionResult = self.detectPeople(
                in: sendablePixelBuffer.value,
                orientation: orientation,
                includesBodyPose: includesBodyPose,
                plan: analysisPlan,
                bodyPoseRegion: bodyPoseRegion,
                verifiesPartialScale: initialTracking.target != nil
            )
            let tracking = self.targetTracker.process(
                detections: detectionResult.frame.detections,
                pixelBuffer: sendablePixelBuffer.value,
                orientation: orientation,
                timestamp: timestamp,
                continuityRegion: analysisPlan.region
            )
            let presentedFrame = PersonDetectionFrame(
                detections: detectionResult.frame.detections,
                orientedImageSize: detectionResult.frame.orientedImageSize,
                targetPresentation: tracking.presentation,
                trackingMetadata: self.multiScaleCoordinator.metadata(
                    after: tracking,
                    plan: analysisPlan,
                    timestamp: timestamp
                )
            )
            self.latestContext = LatestContext(
                frame: presentedFrame,
                pixelBuffer: sendablePixelBuffer.value,
                orientation: orientation,
                timestamp: timestamp
            )
            self.onResult?(presentedFrame, tracking.target)

            guard includesBodyPose else {
                self.onGestureStatus?(self.gestureRecognizer.currentStatus)
                self.onGestureDiagnostic?(self.gestureRecognizer.currentDiagnosticText)
                return
            }
            let gestureResult = self.gestureRecognizer.process(
                bodyObservations: detectionResult.bodyObservations,
                detections: presentedFrame.detections,
                pixelBuffer: sendablePixelBuffer.value,
                orientation: orientation,
                mode: self.gestureMode(for: tracking),
                timestamp: timestamp,
                bodyObservationRegion: detectionResult.bodyObservationRegion
            )
            self.onGestureStatus?(gestureResult.status)
            self.onGestureDiagnostic?(self.gestureRecognizer.currentDiagnosticText)
            if let command = gestureResult.command {
                self.onGestureCommand?(command)
            }
        }
    }

    nonisolated func prepareTarget(
        detectionID: UUID,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        processingQueue.async { [weak self] in
            guard let self,
                  let context = self.latestContext,
                  let detection = context.frame.detections.first(where: { $0.id == detectionID })
            else {
                completion(false)
                return
            }

            let wasPrepared = self.targetTracker.initialize(
                with: detection,
                pixelBuffer: context.pixelBuffer,
                orientation: context.orientation,
                timestamp: context.timestamp
            )
            if wasPrepared {
                self.publishCurrentTrackingState()
            }
            completion(wasPrepared)
        }
    }

    nonisolated func activateTarget() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.targetTracker.activateSession()
            self.publishCurrentTrackingState()
        }
    }

    nonisolated func clearTarget() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.targetTracker.clear()
            self.multiScaleCoordinator.reset()
            self.publishCurrentTrackingState()
        }
    }

    nonisolated func resetGestureRecognition(usesCooldown: Bool) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.gestureRecognizer.reset(
                timestamp: ProcessInfo.processInfo.systemUptime,
                usesCooldown: usesCooldown
            )
            self.onGestureStatus?(nil)
            self.onGestureDiagnostic?(nil)
        }
    }

    nonisolated func setCameraMotionActive(_ isActive: Bool) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.targetTracker.setCameraMotionActive(isActive)
        }
    }

    private nonisolated func detectPeople(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        includesBodyPose: Bool,
        plan: TrackingAnalysisPlan,
        bodyPoseRegion: CGRect,
        verifiesPartialScale: Bool
    ) -> DetectionResult {
        let imageSize = orientedImageSize(for: pixelBuffer, orientation: orientation)
        let orientedImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let normalizedImage = orientedImage.transformed(by: CGAffineTransform(
            translationX: -orientedImage.extent.minX,
            y: -orientedImage.extent.minY
        ))
        let cropRectangle = TrackingGeometry.imageRectangle(
            for: plan.region,
            in: normalizedImage.extent
        )
        let analysisImage = normalizedImage.cropped(to: cropRectangle)
            .transformed(by: CGAffineTransform(
                translationX: -cropRectangle.minX,
                y: -cropRectangle.minY
            ))
        let bodyObservations = includesBodyPose
            ? detectBodyPose(in: normalizedImage, region: bodyPoseRegion)
            : []
        let tuning = trackingTuningBridge.snapshot()

        do {
            let detections: [PersonDetection]
            var usedFallback = false
            switch tuning.detectionBackend {
            case .appleVision:
                detections = try detectPeopleWithAppleVision(
                    in: analysisImage,
                    canonicalRegion: plan.region
                )
            case .appleVisionSkeleton:
                let poseObservations = includesBodyPose && bodyPoseRegion == plan.region
                    ? bodyObservations
                    : detectBodyPose(in: normalizedImage, region: plan.region)
                let initial = attachSkeletons(
                    poseObservations,
                    to: try detectPeopleWithAppleVision(
                        in: analysisImage,
                        canonicalRegion: plan.region
                    ),
                    canonicalRegion: plan.region,
                    imageSize: imageSize,
                    minimumConfidence: tuning.poseMinimumJointConfidence
                )
                detections = verifiesPartialScale
                    ? try verifyPartialPersonScales(
                        initial,
                        in: normalizedImage,
                        startingRegion: plan.region,
                        imageSize: imageSize,
                        minimumConfidence: tuning.poseMinimumJointConfidence
                    )
                    : initial
            case .yoloxNano:
                detections = try detectPeopleWithYOLOX(
                    detector: yoloxNanoDetector,
                    name: "YOLOX-Nano",
                    in: analysisImage,
                    canonicalRegion: plan.region,
                    usedFallback: &usedFallback
                )
            case .yoloxTiny:
                detections = try detectPeopleWithYOLOX(
                    detector: yoloxTinyDetector,
                    name: "YOLOX-Tiny",
                    in: analysisImage,
                    canonicalRegion: plan.region,
                    usedFallback: &usedFallback
                )
            case .yoloxSmall:
                detections = try detectPeopleWithYOLOX(
                    detector: yoloxSmallDetector,
                    name: "YOLOX-S",
                    in: analysisImage,
                    canonicalRegion: plan.region,
                    usedFallback: &usedFallback
                )
            }
            if !usedFallback {
                lastLoggedError = nil
            }
            return DetectionResult(
                frame: PersonDetectionFrame(
                    detections: detections,
                    orientedImageSize: imageSize
                ),
                bodyObservations: bodyObservations,
                bodyObservationRegion: bodyPoseRegion
            )
        } catch {
            let message = error.localizedDescription
            if message != lastLoggedError {
                print("Human detection failed: \(message)")
                lastLoggedError = message
            }
            return DetectionResult(
                frame: PersonDetectionFrame(detections: [], orientedImageSize: imageSize),
                bodyObservations: bodyObservations,
                bodyObservationRegion: bodyPoseRegion
            )
        }
    }

    private nonisolated func detectPeopleWithAppleVision(
        in analysisImage: CIImage,
        canonicalRegion: CGRect
    ) throws -> [PersonDetection] {
        let fullBodyRequest = VNDetectHumanRectanglesRequest()
        fullBodyRequest.revision = VNDetectHumanRectanglesRequestRevision2
        fullBodyRequest.upperBodyOnly = false
        let upperBodyRequest = VNDetectHumanRectanglesRequest()
        upperBodyRequest.revision = VNDetectHumanRectanglesRequestRevision2
        upperBodyRequest.upperBodyOnly = true
        let faceRequest = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(ciImage: analysisImage, orientation: .up).perform([
            fullBodyRequest,
            upperBodyRequest,
            faceRequest
        ])

        let fullBodies = (fullBodyRequest.results ?? []).map {
            DetectionMerging.Evidence(
                boundingBox: TrackingGeometry.canonicalRectangle(
                    fromLocal: $0.boundingBox,
                    in: canonicalRegion
                ),
                source: .body,
                confidence: $0.confidence
            )
        }
        let upperBodies = (upperBodyRequest.results ?? []).map {
            DetectionMerging.Evidence(
                boundingBox: TrackingGeometry.canonicalRectangle(
                    fromLocal: $0.boundingBox,
                    in: canonicalRegion
                ),
                source: .upperBody,
                confidence: $0.confidence
            )
        }
        let faces = (faceRequest.results ?? []).map {
            DetectionMerging.Evidence(
                boundingBox: TrackingGeometry.canonicalRectangle(
                    fromLocal: $0.boundingBox,
                    in: canonicalRegion
                ),
                source: .face,
                confidence: $0.confidence
            )
        }
        return DetectionMerging.merge(
            fullBodies: fullBodies,
            upperBodies: upperBodies,
            faces: faces
        )
    }

    private nonisolated func detectPeopleWithYOLOX(
        detector: YOLOXDetector,
        name: String,
        in analysisImage: CIImage,
        canonicalRegion: CGRect,
        usedFallback: inout Bool
    ) throws -> [PersonDetection] {
        do {
            return try detector.detect(in: analysisImage).map {
                PersonDetection(
                    id: UUID(),
                    normalizedBoundingBox: TrackingGeometry.canonicalRectangle(
                        fromLocal: $0.boundingBox,
                        in: canonicalRegion
                    ),
                    source: .yolox,
                    confidence: $0.confidence
                )
            }
        } catch {
            usedFallback = true
            logDetectionError("\(name) unavailable; using Apple Vision: \(error.localizedDescription)")
            return try detectPeopleWithAppleVision(
                in: analysisImage,
                canonicalRegion: canonicalRegion
            )
        }
    }

    /// Associate Vision pose observations to the Apple person boxes without
    /// changing the boxes themselves. The same person detector therefore feeds
    /// both Apple modes and remains directly comparable in field tests.
    private nonisolated func attachSkeletons(
        _ observations: [VNHumanBodyPoseObservation],
        to detections: [PersonDetection],
        canonicalRegion: CGRect,
        imageSize: CGSize,
        minimumConfidence: Float
    ) -> [PersonDetection] {
        let skeletons = observations.compactMap {
            PersonSkeleton(
                observation: $0,
                canonicalRegion: canonicalRegion,
                imageSize: imageSize,
                minimumConfidence: minimumConfidence
            )
        }
        var unused = Set(skeletons.indices)

        return detections.map { detection in
            let expandedBox = detection.normalizedBoundingBox.insetBy(
                dx: -detection.normalizedBoundingBox.width * 0.18,
                dy: -detection.normalizedBoundingBox.height * 0.12
            ).intersection(TrackingGeometry.unitRectangle)
            let bestIndex = unused.compactMap { index -> (Int, CGFloat)? in
                let skeleton = skeletons[index]
                guard let anchor = skeleton.torsoCenter,
                      expandedBox.contains(anchor) else { return nil }
                let distance = hypot(
                    anchor.x - detection.normalizedBoundingBox.midX,
                    anchor.y - detection.normalizedBoundingBox.midY
                ) / max(detection.normalizedBoundingBox.height, 0.01)
                return (index, distance)
            }.min { $0.1 < $1.1 }?.0
            let skeleton = bestIndex.map { skeletons[$0] }
            if let bestIndex { unused.remove(bestIndex) }
            let measurement: PersonScaleMeasurement?
            if let length = skeleton?.articulatedBodyLength {
                measurement = PersonScaleMeasurement(value: length, kind: .articulatedPose)
            } else if detection.source == .body {
                measurement = PersonScaleMeasurement(
                    value: detection.normalizedBoundingBox.height,
                    kind: .fullBodyBox
                )
            } else {
                measurement = nil
            }
            return PersonDetection(
                id: detection.id,
                normalizedBoundingBox: detection.normalizedBoundingBox,
                source: detection.source,
                confidence: detection.confidence,
                skeleton: skeleton,
                scaleMeasurement: measurement
            )
        }
    }

    /// A partial candidate in a zoomed crop may be a nearby passerby. Inspect
    /// up to two progressively wider, candidate-centered crops without changing
    /// the preview or recording crop. This work is opt-in with the skeleton mode.
    private nonisolated func verifyPartialPersonScales(
        _ detections: [PersonDetection],
        in normalizedImage: CIImage,
        startingRegion: CGRect,
        imageSize: CGSize,
        minimumConfidence: Float
    ) throws -> [PersonDetection] {
        var verified = detections
        let candidates = detections.indices.filter {
            detections[$0].scaleMeasurement?.isReliableForHistory != true
        }.prefix(2)

        for index in candidates {
            let original = detections[index]
            var replacementSkeleton: PersonSkeleton?
            var replacementMeasurement: PersonScaleMeasurement?
            var previousRegion = startingRegion

            for scale in [CGFloat(2), CGFloat(4)] {
                let region = TrackingGeometry.centeredRectangle(
                    center: CGPoint(
                        x: original.normalizedBoundingBox.midX,
                        y: original.normalizedBoundingBox.midY
                    ),
                    size: CGSize(
                        width: min(1, startingRegion.width * scale),
                        height: min(1, startingRegion.height * scale)
                    )
                )
                guard region != previousRegion else { continue }
                previousRegion = region
                let rectangle = TrackingGeometry.imageRectangle(
                    for: region,
                    in: normalizedImage.extent
                )
                let image = normalizedImage.cropped(to: rectangle).transformed(
                    by: CGAffineTransform(translationX: -rectangle.minX, y: -rectangle.minY)
                )
                let wider = attachSkeletons(
                    detectBodyPose(in: normalizedImage, region: region),
                    to: try detectPeopleWithAppleVision(in: image, canonicalRegion: region),
                    canonicalRegion: region,
                    imageSize: imageSize,
                    minimumConfidence: minimumConfidence
                )
                let match = wider.filter {
                    $0.normalizedBoundingBox.contains(CGPoint(
                        x: original.normalizedBoundingBox.midX,
                        y: original.normalizedBoundingBox.midY
                    )) || TargetAssociation.intersectionOverUnion(
                        $0.normalizedBoundingBox,
                        original.normalizedBoundingBox
                    ) > 0.15
                }.min {
                    abs($0.normalizedBoundingBox.midX - original.normalizedBoundingBox.midX)
                        < abs($1.normalizedBoundingBox.midX - original.normalizedBoundingBox.midX)
                }
                if let match,
                   match.scaleMeasurement?.isReliableForHistory == true {
                    replacementSkeleton = match.skeleton
                    replacementMeasurement = match.scaleMeasurement
                    break
                }
            }

            verified[index] = PersonDetection(
                id: original.id,
                normalizedBoundingBox: original.normalizedBoundingBox,
                source: original.source,
                confidence: original.confidence,
                skeleton: replacementSkeleton ?? original.skeleton,
                scaleMeasurement: replacementMeasurement ?? PersonScaleMeasurement(
                    value: original.normalizedBoundingBox.height,
                    kind: .partialLowerBound
                )
            )
        }
        return verified
    }

    private nonisolated func logDetectionError(_ message: String) {
        guard message != lastLoggedError else { return }
        print(message)
        lastLoggedError = message
    }

    private nonisolated func detectBodyPose(
        in normalizedImage: CIImage,
        region: CGRect
    ) -> [VNHumanBodyPoseObservation] {
        let imageRectangle = TrackingGeometry.imageRectangle(
            for: region,
            in: normalizedImage.extent
        )
        let analysisImage = normalizedImage.cropped(to: imageRectangle)
            .transformed(by: CGAffineTransform(
                translationX: -imageRectangle.minX,
                y: -imageRectangle.minY
            ))
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(ciImage: analysisImage, orientation: .up)
        do {
            try handler.perform([request])
            return request.results ?? []
        } catch {
            return []
        }
    }

    private nonisolated func gestureMode(
        for tracking: TargetTrackerOutput
    ) -> GestureEvaluationMode {
        guard tracking.target != nil else { return .unlocked }
        guard tracking.presentation?.state == .lockedVisible,
              let detectionID = tracking.presentation?.matchedDetectionID,
              let matchConfidence = tracking.target?.matchConfidence else {
            return .lockedUnavailable
        }
        return .lockedVisible(
            detectionID: detectionID,
            matchConfidence: matchConfidence
        )
    }

    private nonisolated func orientedImageSize(
        for pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> CGSize {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: height, height: width)
        default:
            return CGSize(width: width, height: height)
        }
    }

    private nonisolated func finishProcessing() {
        stateLock.lock()
        isProcessing = false
        stateLock.unlock()
    }

    private nonisolated func publishCurrentTrackingState() {
        let tracking = targetTracker.output()
        guard var context = latestContext else {
            onResult?(.empty, tracking.target)
            return
        }
        let metadata: TrackingFrameMetadata
        if tracking.target == nil {
            let idlePlan = multiScaleCoordinator.analysisPlan(for: tracking)
            metadata = multiScaleCoordinator.metadata(
                after: tracking,
                plan: idlePlan,
                timestamp: context.timestamp
            )
        } else {
            metadata = context.frame.trackingMetadata
        }
        context.frame = PersonDetectionFrame(
            detections: context.frame.detections,
            orientedImageSize: context.frame.orientedImageSize,
            targetPresentation: tracking.presentation,
            trackingMetadata: metadata
        )
        latestContext = context
        onResult?(context.frame, tracking.target)
    }
}

private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}
