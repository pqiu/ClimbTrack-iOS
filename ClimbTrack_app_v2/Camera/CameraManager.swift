@preconcurrency import AVFoundation
import Combine
import CoreMedia
import Foundation
import ImageIO

@MainActor
final class CameraManager: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case configuring
        case running
        case permissionDenied
        case unavailable
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
    @Published private(set) var isSwitchingCamera = false

    let session = AVCaptureSession()
    let videoOutput = AVCaptureVideoDataOutput()

    private let sessionQueue = DispatchQueue(label: "com.pengqiu.ClimbTrack.camera-session")
    private let frameDistributor = CameraFrameDistributor()
    private var isConfigured = false

    init() {
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        videoOutput.setSampleBufferDelegate(
            frameDistributor,
            queue: frameDistributor.queue
        )
    }

    func setRecordingFrameHandler(
        _ handler: (@Sendable (CMSampleBuffer, CGImagePropertyOrientation) -> Void)?
    ) {
        frameDistributor.setRecordingHandler(handler)
    }

    func setAnalysisFrameHandler(
        _ handler: (@Sendable (CMSampleBuffer, CGImagePropertyOrientation) -> Void)?
    ) {
        frameDistributor.setAnalysisHandler(handler)
    }

    func start() {
        guard state == .idle else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()

        case .notDetermined:
            state = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] isGranted in
                guard let manager = self else { return }
                Task { @MainActor [manager] in
                    if isGranted {
                        manager.configureAndStart()
                    } else {
                        manager.state = .permissionDenied
                    }
                }
            }

        case .denied, .restricted:
            state = .permissionDenied

        @unknown default:
            state = .permissionDenied
        }
    }

    func stop() {
        guard isConfigured else { return }

        let session = session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }

        state = .idle
    }

    func addOutput(
        _ output: AVCaptureOutput,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard isConfigured else {
            completion(false)
            return
        }

        let session = session
        sessionQueue.async {
            let wasAdded: Bool

            if session.outputs.contains(where: { $0 === output }) {
                wasAdded = true
            } else {
                session.beginConfiguration()

                if session.canAddOutput(output) {
                    session.addOutput(output)
                    wasAdded = true
                } else {
                    wasAdded = false
                }

                session.commitConfiguration()
            }

            Task { @MainActor in
                completion(wasAdded)
            }
        }
    }

    func addAudioInput(completion: @escaping @MainActor (Bool) -> Void) {
        guard isConfigured else {
            completion(false)
            return
        }

        let session = session
        sessionQueue.async {
            let wasAdded = Self.addAudioInput(to: session)

            Task { @MainActor in
                completion(wasAdded)
            }
        }
    }

    func switchCamera(
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        guard state == .running, !isSwitchingCamera else {
            completion(false)
            return
        }

        isSwitchingCamera = true

        let session = session
        sessionQueue.async { [weak self] in
            let newPosition = Self.switchVideoInput(in: session)
            guard let manager = self else { return }

            Task { @MainActor [manager] in
                if let newPosition {
                    manager.cameraPosition = newPosition
                    manager.frameDistributor.setCameraPosition(newPosition)
                }

                manager.isSwitchingCamera = false
                completion(newPosition != nil)
            }
        }
    }

    private func configureAndStart() {
        guard !isConfigured else {
            startConfiguredSession()
            return
        }

        state = .configuring

        let session = session
        let videoOutput = videoOutput
        sessionQueue.async { [weak self] in
            let result = Self.configure(session, videoOutput: videoOutput)
            guard let manager = self else { return }

            Task { @MainActor [manager] in
                switch result {
                case .success:
                    manager.isConfigured = true
                    manager.startConfiguredSession()

                case .failure(.cameraUnavailable):
                    manager.state = .unavailable

                case .failure(.configurationFailed):
                    manager.state = .failed("The camera could not be configured.")
                }
            }
        }
    }

    private func startConfiguredSession() {
        state = .configuring

        let session = session
        sessionQueue.async { [weak self] in
            if !session.isRunning {
                session.startRunning()
            }

            guard let manager = self else { return }
            Task { @MainActor [manager] in
                manager.state = .running
            }
        }
    }

    // Session configuration stays out of the view layer and off the main thread.
    private nonisolated static func configure(
        _ session: AVCaptureSession,
        videoOutput: AVCaptureVideoDataOutput?
    ) -> Result<Void, CameraError> {
        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            return .failure(.cameraUnavailable)
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)

            session.beginConfiguration()
            defer { session.commitConfiguration() }

            session.sessionPreset = .high

            guard let videoOutput,
                  session.canAddInput(input),
                  session.canAddOutput(videoOutput) else {
                return .failure(.configurationFailed)
            }

            session.addInput(input)
            session.addOutput(videoOutput)
            return .success(())
        } catch {
            return .failure(.configurationFailed)
        }
    }

    private nonisolated static func addAudioInput(to session: AVCaptureSession) -> Bool {
        if session.inputs
            .compactMap({ $0 as? AVCaptureDeviceInput })
            .contains(where: { $0.device.hasMediaType(.audio) }) {
            return true
        }

        guard let microphone = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: microphone) else {
            return false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else { return false }

        session.addInput(input)
        return true
    }

    // Replacing only the video input keeps recording output and audio connected.
    private nonisolated static func switchVideoInput(
        in session: AVCaptureSession
    ) -> AVCaptureDevice.Position? {
        guard let currentInput = session.inputs
            .compactMap({ $0 as? AVCaptureDeviceInput })
            .first(where: { $0.device.hasMediaType(.video) }) else {
            return nil
        }

        let newPosition: AVCaptureDevice.Position =
            currentInput.device.position == .back ? .front : .back

        guard let newCamera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: newPosition
        ), let newInput = try? AVCaptureDeviceInput(device: newCamera) else {
            return nil
        }

        session.beginConfiguration()
        session.removeInput(currentInput)

        guard session.canAddInput(newInput) else {
            if session.canAddInput(currentInput) {
                session.addInput(currentInput)
            }
            session.commitConfiguration()
            return nil
        }

        session.addInput(newInput)
        session.commitConfiguration()
        return newPosition
    }
}

private enum CameraError: Error {
    case cameraUnavailable
    case configurationFailed
}

/// Fans out the session's single video-data stream without creating another
/// capture output. Recording work remains serialized by its own pipeline, while
/// Vision immediately hands frames to its separately throttled processing queue.
private final class CameraFrameDistributor: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    let queue = DispatchQueue(label: "com.pengqiu.ClimbTrack.camera-frames")

    private var cameraPosition: AVCaptureDevice.Position = .back
    private var recordingHandler: (@Sendable (
        CMSampleBuffer,
        CGImagePropertyOrientation
    ) -> Void)?
    private var analysisHandler: (@Sendable (
        CMSampleBuffer,
        CGImagePropertyOrientation
    ) -> Void)?

    func setCameraPosition(_ position: AVCaptureDevice.Position) {
        queue.async { [weak self] in
            self?.cameraPosition = position
        }
    }

    func setRecordingHandler(
        _ handler: (@Sendable (CMSampleBuffer, CGImagePropertyOrientation) -> Void)?
    ) {
        queue.async { [weak self] in
            self?.recordingHandler = handler
        }
    }

    func setAnalysisHandler(
        _ handler: (@Sendable (CMSampleBuffer, CGImagePropertyOrientation) -> Void)?
    ) {
        queue.async { [weak self] in
            self?.analysisHandler = handler
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // The app is portrait-only. Passing the camera's EXIF orientation into
        // Vision makes its normalized results upright; the mirrored front-camera
        // orientation also matches AVCaptureVideoPreviewLayer's presentation.
        let orientation: CGImagePropertyOrientation = cameraPosition == .front
            ? .leftMirrored
            : .right
        recordingHandler?(sampleBuffer, orientation)
        analysisHandler?(sampleBuffer, orientation)
    }
}
