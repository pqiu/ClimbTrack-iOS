@preconcurrency import AVFoundation
import Combine
@preconcurrency import CoreImage
import CoreGraphics
@preconcurrency import CoreVideo
import Foundation
import ImageIO
import Photos
import UIKit

@MainActor
final class RecordingManager: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPhotosPermission
        case requestingMicrophonePermission
        case preparing
        case recording
        case stopping
        case saving
        case saved
        case photosPermissionDenied
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isMuted = false
    @Published private(set) var isAudioAvailable = true

    private(set) var recordingStartedAt: Date?
    private(set) var recordingStoppedAt: Date?

    private weak var cameraManager: CameraManager?
    private let audioOutput = AVCaptureAudioDataOutput()
    private let recordingQueue: DispatchQueue
    private let pipelines: [RecordingOutputMode: RecordingPipeline]
    private let audioFanout: RecordingAudioFanout
    private var areCaptureOutputsConfigured = false
    private var currentFileURLs: [URL] = []
    private var selectedOutputModes: Set<RecordingOutputMode>
    private var activeOutputModes: [RecordingOutputMode] = []
    private var pendingPreparationCount = 0
    private var preparationError: Error?
    private var pendingStopCount = 0
    private var completedFileURLs: [URL] = []
    private var stopErrors: [Error] = []
    private var activeVideoFanout: RecordingVideoFanout?

    init(
        cameraManager: CameraManager,
        recordingOutputModes: Set<RecordingOutputMode>
    ) {
        self.cameraManager = cameraManager
        selectedOutputModes = recordingOutputModes.isEmpty
            ? [.smoothZoomedClean]
            : recordingOutputModes
        let queue = DispatchQueue(label: "com.pengqiu.ClimbTrack.recording")
        recordingQueue = queue
        var pipelines: [RecordingOutputMode: RecordingPipeline] = [:]
        for mode in RecordingOutputMode.allCases {
            pipelines[mode] = RecordingPipeline(outputMode: mode, queue: queue)
        }
        self.pipelines = pipelines
        audioFanout = RecordingAudioFanout(pipelines: Array(pipelines.values))
        super.init()

        audioOutput.setSampleBufferDelegate(audioFanout, queue: recordingQueue)

        for pipeline in pipelines.values {
            pipeline.onRecordingStarted = { [weak self] in
                guard let self else { return }
                Task { @MainActor [self] in
                    guard self.state == .preparing else { return }
                    self.recordingStartedAt = Date()
                    self.state = .recording
                }
            }
        }
    }

    var canStartRecording: Bool {
        switch state {
        case .idle, .saved, .photosPermissionDenied, .failed:
            true
        default:
            false
        }
    }

    var canStopRecording: Bool {
        state == .recording
    }

    var showsRecordingIndicator: Bool {
        state == .recording || state == .stopping
    }

    func recordingDuration(at date: Date) -> TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return max(0, (recordingStoppedAt ?? date).timeIntervalSince(recordingStartedAt))
    }

    func toggleMute() {
        guard isAudioAvailable else { return }

        isMuted.toggle()
        // Muting only drops audio samples; it never reconfigures or stops the writer.
        for pipeline in pipelines.values {
            pipeline.setAudioEnabled(!isMuted)
        }
    }

    func switchCamera(completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        // The writer consumes the video output, which remains installed while the
        // camera input is replaced. A brief frame gap does not end the movie.
        cameraManager?.switchCamera(completion: completion)
    }

    func updateTrackingFrame(_ frame: PersonDetectionFrame) {
        for pipeline in pipelines.values {
            pipeline.updateTrackingFrame(frame)
        }
    }

    func updateRecordingOutputModes(_ modes: Set<RecordingOutputMode>) {
        guard !modes.isEmpty else { return }
        selectedOutputModes = modes
    }

    func startRecording() {
        guard canStartRecording else { return }

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            prepareAudioAndStartRecording()

        case .notDetermined:
            state = .requestingPhotosPermission
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
                guard let manager = self else { return }
                Task { @MainActor [manager] in
                    if status == .authorized || status == .limited {
                        manager.prepareAudioAndStartRecording()
                    } else {
                        manager.state = .photosPermissionDenied
                    }
                }
            }

        case .denied, .restricted:
            state = .photosPermissionDenied

        @unknown default:
            state = .photosPermissionDenied
        }
    }

    func stopRecording() {
        guard state == .recording else { return }

        recordingStoppedAt = Date()
        state = .stopping
        cameraManager?.setRecordingFrameHandler(nil)
        activeVideoFanout = nil

        let activePipelines = activeOutputModes.compactMap { pipelines[$0] }
        pendingStopCount = activePipelines.count
        completedFileURLs = []
        stopErrors = []
        for pipeline in activePipelines {
            pipeline.stop { [weak self] result in
                guard let manager = self else { return }
                Task { @MainActor [manager] in
                    manager.handlePipelineStop(result)
                }
            }
        }
    }

    private func prepareAudioAndStartRecording() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            addAudioInputAndStartRecording()

        case .notDetermined:
            state = .requestingMicrophonePermission
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] isGranted in
                guard let manager = self else { return }
                Task { @MainActor [manager] in
                    if isGranted {
                        manager.addAudioInputAndStartRecording()
                    } else {
                        manager.continueWithoutAudio()
                    }
                }
            }

        case .denied, .restricted:
            continueWithoutAudio()

        @unknown default:
            continueWithoutAudio()
        }
    }

    private func addAudioInputAndStartRecording() {
        guard let cameraManager else {
            state = .failed("The camera is not ready.")
            return
        }

        state = .preparing
        cameraManager.addAudioInput { [weak self] wasAdded in
            guard let self else { return }

            self.isAudioAvailable = wasAdded
            if !wasAdded {
                self.isMuted = true
            }
            self.configureOutputsAndStartRecording()
        }
    }

    private func continueWithoutAudio() {
        isAudioAvailable = false
        isMuted = true
        configureOutputsAndStartRecording()
    }

    private func configureOutputsAndStartRecording() {
        guard let cameraManager, cameraManager.state == .running else {
            state = .failed("The camera is not ready.")
            return
        }

        state = .preparing

        if areCaptureOutputsConfigured {
            prepareWriterAndStart()
            return
        }

        guard isAudioAvailable else {
            areCaptureOutputsConfigured = true
            prepareWriterAndStart()
            return
        }

        cameraManager.addOutput(audioOutput) { [weak self] audioWasAdded in
            guard let self else { return }
            self.isAudioAvailable = audioWasAdded
            if !audioWasAdded {
                self.isMuted = true
            }
            self.areCaptureOutputsConfigured = true
            self.prepareWriterAndStart()
        }
    }

    private func prepareWriterAndStart() {
        guard let cameraManager,
              let videoSettings = cameraManager.videoOutput.recommendedVideoSettingsForAssetWriter(
            writingTo: .mov
        ) else {
            state = .failed("Video recording settings are unavailable.")
            return
        }

        let audioSettings = isAudioAvailable
            ? audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
            : nil
        activeOutputModes = RecordingOutputMode.allCases.filter(selectedOutputModes.contains)
        currentFileURLs = activeOutputModes.map { mode in
            FileManager.default.temporaryDirectory
                .appendingPathComponent("ClimbTrack-\(mode.fileNameComponent)-\(UUID().uuidString)")
                .appendingPathExtension("mov")
        }
        recordingStartedAt = nil
        recordingStoppedAt = nil
        pendingPreparationCount = activeOutputModes.count
        preparationError = nil

        for (mode, fileURL) in zip(activeOutputModes, currentFileURLs) {
            guard let pipeline = pipelines[mode] else { continue }
            pipeline.prepare(
                fileURL: fileURL,
                videoSettings: videoSettings,
                audioSettings: audioSettings,
                audioEnabled: !isMuted
            ) { [weak self] error in
                guard let manager = self else { return }
                Task { @MainActor [manager] in
                    manager.handlePipelinePreparation(error)
                }
            }
        }
    }

    private func handlePipelinePreparation(_ error: Error?) {
        guard state == .preparing, pendingPreparationCount > 0 else { return }
        if preparationError == nil {
            preparationError = error
        }
        pendingPreparationCount -= 1
        guard pendingPreparationCount == 0 else { return }

        if let preparationError {
            for mode in activeOutputModes {
                pipelines[mode]?.cancel()
            }
            discardTemporaryRecordings()
            state = .failed(preparationError.localizedDescription)
            return
        }

        let activePipelines = activeOutputModes.compactMap { pipelines[$0] }
        let fanout = RecordingVideoFanout(
            pipelines: activePipelines,
            queue: recordingQueue
        )
        activeVideoFanout = fanout
        cameraManager?.setRecordingFrameHandler { [weak fanout] sampleBuffer, orientation in
            fanout?.enqueue(sampleBuffer, orientation: orientation)
        }
    }

    private func handlePipelineStop(_ result: Result<RecordingCaptureResult, Error>) {
        guard pendingStopCount > 0 else { return }
        switch result {
        case .success(let capture):
            completedFileURLs.append(capture.fileURL)
        case .failure(let error):
            stopErrors.append(error)
        }
        pendingStopCount -= 1
        guard pendingStopCount == 0 else { return }

        guard !completedFileURLs.isEmpty else {
            let message = stopErrors.first?.localizedDescription
                ?? "None of the selected videos could be finalized."
            discardTemporaryRecordings()
            state = .failed(message)
            return
        }

        let warning = stopErrors.isEmpty
            ? nil
            : "Saved \(completedFileURLs.count) video(s), but \(stopErrors.count) selected output(s) failed."
        saveToPhotos(completedFileURLs, warning: warning)
    }

    private func saveToPhotos(_ fileURLs: [URL], warning: String?) {
        cameraManager?.setRecordingFrameHandler(nil)
        state = .saving

        PHPhotoLibrary.shared().performChanges {
            for fileURL in fileURLs {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }
        } completionHandler: { [weak self] wasSaved, error in
            guard let manager = self else { return }
            Task { @MainActor [manager] in
                manager.discardTemporaryRecordings()
                if wasSaved {
                    manager.state = warning.map(RecordingManager.State.failed) ?? .saved
                } else {
                    manager.state = .failed(
                        error?.localizedDescription ?? "The videos could not be saved."
                    )
                }
            }
        }
    }

    private func discardTemporaryRecordings() {
        for fileURL in currentFileURLs {
            try? FileManager.default.removeItem(at: fileURL)
        }
        currentFileURLs = []
    }
}

nonisolated struct RecordingMetadataSnapshot: Sendable {
    let timestamp: TimeInterval
    let frame: PersonDetectionFrame
    let gestureStatus: GestureStatus?
    let gestureDiagnosticText: String?
}

nonisolated struct RecordingCaptureResult: Sendable {
    let fileURL: URL
}

/// Serializes all AVAssetWriter access with incoming capture samples.
private final class RecordingPipeline: NSObject, @unchecked Sendable {
    private struct CropKeyframe {
        let timestamp: TimeInterval
        let crop: CGRect
    }

    private struct BufferedVideoFrame {
        let sampleBuffer: SendableSampleBuffer
        let orientation: CGImagePropertyOrientation
        let presentationTime: CMTime
    }

    private struct BracketedVideoFrame {
        let frame: BufferedVideoFrame
        let crop: CGRect
    }

    let queue: DispatchQueue
    var onRecordingStarted: (@Sendable () -> Void)?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var fileURL: URL?
    private var hasStartedSession = false
    private var audioEnabled = true
    private var outputSize = CGSize.zero
    private var latestTrackingFrame = PersonDetectionFrame.empty
    private var outputMode: RecordingOutputMode
    private var previousSmoothCropKeyframe: CropKeyframe?
    private var unbracketedSmoothFrames: [BufferedVideoFrame] = []
    private var bracketedSmoothFrames: [BracketedVideoFrame] = []
    private var lastAppendedVideoTimestamp: CMTime?
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    // A stalled Vision pipeline must not retain an unbounded number of camera
    // pixel buffers. Normal operation holds only about 0.125 seconds.
    private static let maximumSmoothBufferDuration: TimeInterval = 1.0

    init(outputMode: RecordingOutputMode, queue: DispatchQueue) {
        self.outputMode = outputMode
        self.queue = queue
        super.init()
    }

    nonisolated func enqueueVideoSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        orientation: CGImagePropertyOrientation
    ) {
        let sendableSampleBuffer = SendableSampleBuffer(value: sampleBuffer)
        queue.async { [weak self] in
            self?.appendVideo(sendableSampleBuffer.value, orientation: orientation)
        }
    }

    nonisolated func updateTrackingFrame(_ frame: PersonDetectionFrame) {
        queue.async { [weak self] in
            guard let self else { return }
            latestTrackingFrame = frame
            if outputMode == .smoothZoomedClean {
                acceptSmoothCropKeyframe(from: frame)
            }
        }
    }

    nonisolated func setOutputMode(_ mode: RecordingOutputMode) {
        queue.async { [weak self] in
            guard let self, outputMode != mode else { return }
            if outputMode == .smoothZoomedClean {
                // A mode change intentionally abandons the incomplete final
                // interpolation interval before newer direct frames are written.
                unbracketedSmoothFrames.removeAll()
                bracketedSmoothFrames.removeAll()
            }
            outputMode = mode
            if mode == .smoothZoomedClean {
                previousSmoothCropKeyframe = cropKeyframe(from: latestTrackingFrame)
            } else {
                previousSmoothCropKeyframe = nil
            }
        }
    }

    func prepare(
        fileURL: URL,
        videoSettings: [String: Any],
        audioSettings: [String: Any]?,
        audioEnabled: Bool,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            do {
                let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mov)
                let sourceWidth = Self.integerValue(videoSettings[AVVideoWidthKey])
                let sourceHeight = Self.integerValue(videoSettings[AVVideoHeightKey])
                guard sourceWidth > 0, sourceHeight > 0 else {
                    throw RecordingError.videoWriterUnavailable
                }
                let outputWidth = min(sourceWidth, sourceHeight)
                let outputHeight = max(sourceWidth, sourceHeight)
                var renderedVideoSettings = videoSettings
                renderedVideoSettings[AVVideoWidthKey] = outputWidth
                renderedVideoSettings[AVVideoHeightKey] = outputHeight

                let videoInput = AVAssetWriterInput(
                    mediaType: .video,
                    outputSettings: renderedVideoSettings
                )
                videoInput.expectsMediaDataInRealTime = true

                guard writer.canAdd(videoInput) else {
                    throw RecordingError.videoWriterUnavailable
                }
                writer.add(videoInput)
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: videoInput,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String:
                            Int(kCVPixelFormatType_32BGRA),
                        kCVPixelBufferWidthKey as String: outputWidth,
                        kCVPixelBufferHeightKey as String: outputHeight,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                    ]
                )

                var audioInput: AVAssetWriterInput?
                if let audioSettings {
                    let input = AVAssetWriterInput(
                        mediaType: .audio,
                        outputSettings: audioSettings
                    )
                    input.expectsMediaDataInRealTime = true
                    if writer.canAdd(input) {
                        writer.add(input)
                        audioInput = input
                    }
                }

                self.writer = writer
                self.videoInput = videoInput
                self.pixelBufferAdaptor = adaptor
                self.audioInput = audioInput
                self.fileURL = fileURL
                self.hasStartedSession = false
                self.audioEnabled = audioEnabled
                self.outputSize = CGSize(width: outputWidth, height: outputHeight)
                self.lastAppendedVideoTimestamp = nil
                self.previousSmoothCropKeyframe = self.outputMode == .smoothZoomedClean
                    ? self.cropKeyframe(from: self.latestTrackingFrame)
                    : nil
                self.unbracketedSmoothFrames.removeAll()
                self.bracketedSmoothFrames.removeAll()
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func setAudioEnabled(_ isEnabled: Bool) {
        queue.async { [weak self] in
            self?.audioEnabled = isEnabled
        }
    }

    nonisolated func enqueueAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let sendableSampleBuffer = SendableSampleBuffer(value: sampleBuffer)
        queue.async { [weak self] in
            self?.appendAudio(sendableSampleBuffer.value)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            writer?.cancelWriting()
            reset()
        }
    }

    func stop(completion: @escaping @Sendable (Result<RecordingCaptureResult, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, let writer, let fileURL else {
                completion(.failure(RecordingError.writerNotReady))
                return
            }

            guard hasStartedSession else {
                completion(.failure(RecordingError.noVideoFrames))
                self.reset()
                return
            }

            if outputMode == .smoothZoomedClean {
                // Frames after the final known crop keyframe have no right-hand
                // interpolation endpoint and are deliberately omitted.
                unbracketedSmoothFrames.removeAll()
                drainBracketedSmoothFrames()
                bracketedSmoothFrames.removeAll()
            }

            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            let sendableWriter = SendableAssetWriter(value: writer)
            let capture = RecordingCaptureResult(
                fileURL: fileURL
            )
            writer.finishWriting { [weak self] in
                let writer = sendableWriter.value
                if writer.status == .completed {
                    completion(.success(capture))
                } else {
                    completion(.failure(writer.error ?? RecordingError.finishFailed))
                }
                self?.queue.async {
                    self?.reset()
                }
            }
        }
    }

    private func appendVideo(
        _ sampleBuffer: CMSampleBuffer,
        orientation: CGImagePropertyOrientation
    ) {
        guard let writer,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !hasStartedSession {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: presentationTime)
            hasStartedSession = true
            onRecordingStarted?()
        }

        if outputMode == .smoothZoomedClean {
            unbracketedSmoothFrames.append(BufferedVideoFrame(
                sampleBuffer: SendableSampleBuffer(value: sampleBuffer),
                orientation: orientation,
                presentationTime: presentationTime
            ))
            trimUnbracketedSmoothFrames()
            drainBracketedSmoothFrames()
            return
        }

        let crop = outputMode == .zoomedTracking
            ? TrackingGeometry.clipped(latestTrackingFrame.trackingMetadata.displayCrop)
            : TrackingGeometry.unitRectangle
        if outputMode.usesEightHertzFrames,
           let lastAppendedVideoTimestamp,
           CMTimeGetSeconds(presentationTime - lastAppendedVideoTimestamp) < 0.125 {
            return
        }
        let didAppend = renderAndAppend(
            sampleBuffer,
            orientation: orientation,
            presentationTime: presentationTime,
            crop: crop,
            mode: outputMode
        )
        if didAppend {
            lastAppendedVideoTimestamp = presentationTime
        }
    }

    @discardableResult
    private func renderAndAppend(
        _ sampleBuffer: CMSampleBuffer,
        orientation: CGImagePropertyOrientation,
        presentationTime: CMTime,
        crop: CGRect,
        mode: RecordingOutputMode
    ) -> Bool {
        guard writer?.status == .writing,
              let videoInput,
              videoInput.isReadyForMoreMediaData,
              let pixelBufferAdaptor,
              let pool = pixelBufferAdaptor.pixelBufferPool,
              let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return false
        }

        var renderedPixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            nil,
            pool,
            &renderedPixelBuffer
        ) == kCVReturnSuccess, let renderedPixelBuffer else { return false }

        render(
            sourcePixelBuffer,
            orientation: orientation,
            into: renderedPixelBuffer,
            frame: latestTrackingFrame,
            crop: crop,
            mode: mode
        )
        return pixelBufferAdaptor.append(
            renderedPixelBuffer,
            withPresentationTime: presentationTime
        )
    }

    private func cropKeyframe(from frame: PersonDetectionFrame) -> CropKeyframe? {
        let timestamp = frame.trackingMetadata.timestamp
        guard timestamp.isFinite, timestamp >= 0 else { return nil }
        return CropKeyframe(
            timestamp: timestamp,
            crop: TrackingGeometry.clipped(frame.trackingMetadata.displayCrop)
        )
    }

    private func acceptSmoothCropKeyframe(from frame: PersonDetectionFrame) {
        guard let keyframe = cropKeyframe(from: frame) else { return }
        guard let previous = previousSmoothCropKeyframe else {
            previousSmoothCropKeyframe = keyframe
            unbracketedSmoothFrames.removeAll {
                CMTimeGetSeconds($0.presentationTime) <= keyframe.timestamp
            }
            return
        }
        guard keyframe.timestamp > previous.timestamp else { return }

        let interval = keyframe.timestamp - previous.timestamp
        var stillUnbracketed: [BufferedVideoFrame] = []
        stillUnbracketed.reserveCapacity(unbracketedSmoothFrames.count)
        for buffered in unbracketedSmoothFrames {
            let timestamp = CMTimeGetSeconds(buffered.presentationTime)
            guard timestamp.isFinite, timestamp >= previous.timestamp else { continue }
            guard timestamp <= keyframe.timestamp else {
                stillUnbracketed.append(buffered)
                continue
            }
            let progress = CGFloat(min(
                1,
                max(0, (timestamp - previous.timestamp) / interval)
            ))
            bracketedSmoothFrames.append(BracketedVideoFrame(
                frame: buffered,
                crop: interpolatedCrop(
                    from: previous.crop,
                    to: keyframe.crop,
                    progress: progress
                )
            ))
        }
        unbracketedSmoothFrames = stillUnbracketed
        previousSmoothCropKeyframe = keyframe
        drainBracketedSmoothFrames()
    }

    private func drainBracketedSmoothFrames() {
        while let next = bracketedSmoothFrames.first {
            guard renderAndAppend(
                next.frame.sampleBuffer.value,
                orientation: next.frame.orientation,
                presentationTime: next.frame.presentationTime,
                crop: next.crop,
                mode: .smoothZoomedClean
            ) else { return }
            bracketedSmoothFrames.removeFirst()
        }
    }

    private func trimUnbracketedSmoothFrames() {
        guard let newest = unbracketedSmoothFrames.last else { return }
        let newestTime = CMTimeGetSeconds(newest.presentationTime)
        guard newestTime.isFinite else { return }
        while let oldest = unbracketedSmoothFrames.first {
            let oldestTime = CMTimeGetSeconds(oldest.presentationTime)
            guard oldestTime.isFinite,
                  newestTime - oldestTime > Self.maximumSmoothBufferDuration else { return }
            unbracketedSmoothFrames.removeFirst()
        }
    }

    private func interpolatedCrop(
        from start: CGRect,
        to end: CGRect,
        progress: CGFloat
    ) -> CGRect {
        let center = CGPoint(
            x: start.midX + (end.midX - start.midX) * progress,
            y: start.midY + (end.midY - start.midY) * progress
        )
        let width = start.width + (end.width - start.width) * progress
        return TrackingGeometry.centeredRectangle(
            center: center,
            size: CGSize(width: width, height: width)
        )
    }

    private func render(
        _ source: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        into destination: CVPixelBuffer,
        frame: PersonDetectionFrame,
        crop: CGRect,
        mode: RecordingOutputMode
    ) {
        let oriented = CIImage(cvPixelBuffer: source).oriented(orientation)
        let normalized = oriented.transformed(by: CGAffineTransform(
            translationX: -oriented.extent.minX,
            y: -oriented.extent.minY
        ))
        let cropRectangle = TrackingGeometry.imageRectangle(for: crop, in: normalized.extent)
        let cropped = normalized.cropped(to: cropRectangle)
            .transformed(by: CGAffineTransform(
                translationX: -cropRectangle.minX,
                y: -cropRectangle.minY
            ))
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
            drawDebugOverlay(frame, displayCrop: crop, into: destination)
        case .smoothZoomedClean:
            break
        }
    }


    private func drawPeopleBoxes(
        _ frame: PersonDetectionFrame,
        displayCrop: CGRect,
        into pixelBuffer: CVPixelBuffer
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
        defer {
            UIGraphicsPopContext()
            context.restoreGState()
        }

        for detection in frame.detections {
            guard let rectangle = outputRectangle(
                for: detection.normalizedBoundingBox,
                displayCrop: displayCrop
            ) else { continue }
            let isTarget = frame.targetPresentation?.matchedDetectionID == detection.id
            stroke(
                rectangle,
                color: isTarget ? .systemRed : .systemGreen,
                width: isTarget ? 8 : 5
            )
        }
    }

    private func drawDebugOverlay(
        _ frame: PersonDetectionFrame,
        displayCrop: CGRect,
        into pixelBuffer: CVPixelBuffer
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
        defer {
            UIGraphicsPopContext()
            context.restoreGState()
        }

        let interfaceScale = max(1, outputSize.width / 390)
        for detection in frame.detections {
            guard let rectangle = outputRectangle(
                for: detection.normalizedBoundingBox,
                displayCrop: displayCrop
            ) else { continue }
            let isTarget = frame.targetPresentation?.matchedDetectionID == detection.id
            let color: UIColor = isTarget ? .systemRed : .systemGreen
            stroke(rectangle, color: color, width: isTarget ? 8 : 5)
            if let skeleton = detection.skeleton {
                for connection in PersonSkeleton.limbConnections {
                    guard let first = skeleton.joints[connection.0],
                          let second = skeleton.joints[connection.1],
                          let start = outputPoint(for: first.location, displayCrop: displayCrop),
                          let end = outputPoint(for: second.location, displayCrop: displayCrop)
                    else { continue }
                    let path = UIBezierPath()
                    path.move(to: start)
                    path.addLine(to: end)
                    path.lineWidth = isTarget ? 8 : 5
                    color.setStroke()
                    path.stroke()
                }
                for joint in skeleton.joints.values {
                    guard let point = outputPoint(
                        for: joint.location,
                        displayCrop: displayCrop
                    ) else { continue }
                    fillCircle(
                        at: point,
                        radius: 3 * interfaceScale,
                        color: color
                    )
                }
            }
            drawDetectionLabel(
                detection,
                isTarget: isTarget,
                color: color,
                rectangle: rectangle,
                interfaceScale: interfaceScale
            )
        }

        if frame.trackingMetadata.analysisRegion != TrackingGeometry.unitRectangle,
           let roi = outputRectangle(
            for: frame.trackingMetadata.analysisRegion,
            displayCrop: displayCrop
           ) {
            stroke(roi, color: .cyan, width: 5, dash: [14, 10])
        }

        if let uncertain = frame.targetPresentation?.uncertainBoundingBox,
           let rectangle = outputRectangle(
                for: uncertain,
                displayCrop: displayCrop
           ) {
            stroke(rectangle, color: .systemOrange, width: 8, dash: [18, 12])
        }

    }

    private func drawDetectionLabel(
        _ detection: PersonDetection,
        isTarget: Bool,
        color: UIColor,
        rectangle: CGRect,
        interfaceScale: CGFloat
    ) {
        let confidence = Int(detection.confidence * 100)
        let text = isTarget
            ? "TARGET · \(detection.source.rawValue) \(confidence)%"
            : "\(detection.source.rawValue) \(confidence)%"
        let font = UIFont.monospacedSystemFont(
            ofSize: 10 * interfaceScale,
            weight: .semibold
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let horizontalPadding = 4 * interfaceScale
        let verticalPadding = 2 * interfaceScale
        let panel = CGRect(
            x: rectangle.minX,
            y: rectangle.minY,
            width: min(
                outputSize.width - rectangle.minX,
                textSize.width + horizontalPadding * 2
            ),
            height: textSize.height + verticalPadding * 2
        )
        color.withAlphaComponent(0.9).setFill()
        UIBezierPath(rect: panel).fill()
        (text as NSString).draw(
            at: CGPoint(
                x: panel.minX + horizontalPadding,
                y: panel.minY + verticalPadding
            ),
            withAttributes: attributes
        )
    }

    private func fillCircle(at point: CGPoint, radius: CGFloat, color: UIColor) {
        color.setFill()
        UIBezierPath(ovalIn: CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )).fill()
    }

    private func outputRectangle(
        for canonicalRectangle: CGRect,
        displayCrop: CGRect
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
        displayCrop: CGRect
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
        if !dash.isEmpty {
            path.setLineDash(dash, count: dash.count, phase: 0)
        }
        color.setStroke()
        path.stroke()
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard audioEnabled,
              hasStartedSession,
              writer?.status == .writing,
              let audioInput,
              audioInput.isReadyForMoreMediaData else { return }

        audioInput.append(sampleBuffer)
    }

    private func reset() {
        writer = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        audioInput = nil
        fileURL = nil
        hasStartedSession = false
        outputSize = .zero
        lastAppendedVideoTimestamp = nil
        previousSmoothCropKeyframe = nil
        unbracketedSmoothFrames.removeAll()
        bracketedSmoothFrames.removeAll()
    }

    private static func integerValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }
}

private struct SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

private struct SendableAssetWriter: @unchecked Sendable {
    let value: AVAssetWriter
}

/// Drops a camera frame when the previous frame is still being rendered. This
/// bounds retained camera buffers if several selected encoders cannot keep up.
private nonisolated final class RecordingVideoFanout: @unchecked Sendable {
    private let pipelines: [RecordingPipeline]
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var isFramePending = false

    init(pipelines: [RecordingPipeline], queue: DispatchQueue) {
        self.pipelines = pipelines
        self.queue = queue
    }

    func enqueue(
        _ sampleBuffer: CMSampleBuffer,
        orientation: CGImagePropertyOrientation
    ) {
        lock.lock()
        guard !isFramePending else {
            lock.unlock()
            return
        }
        isFramePending = true
        lock.unlock()

        for pipeline in pipelines {
            pipeline.enqueueVideoSampleBuffer(sampleBuffer, orientation: orientation)
        }
        queue.async { [weak self] in
            guard let self else { return }
            lock.lock()
            isFramePending = false
            lock.unlock()
        }
    }
}

private final class RecordingAudioFanout: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    private let pipelines: [RecordingPipeline]

    init(pipelines: [RecordingPipeline]) {
        self.pipelines = pipelines
        super.init()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureAudioDataOutput {
            for pipeline in pipelines {
                pipeline.enqueueAudioSampleBuffer(sampleBuffer)
            }
        }
    }
}

private enum RecordingError: LocalizedError {
    case videoWriterUnavailable
    case writerNotReady
    case noVideoFrames
    case finishFailed

    var errorDescription: String? {
        switch self {
        case .videoWriterUnavailable:
            "The video writer could not be configured."
        case .writerNotReady:
            "The recording was not ready to stop."
        case .noVideoFrames:
            "No video frames were captured."
        case .finishFailed:
            "The video could not be finalized."
        }
    }
}
