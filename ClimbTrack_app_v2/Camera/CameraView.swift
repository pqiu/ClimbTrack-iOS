import AVFoundation
import Combine
import Foundation
import SwiftUI
import UIKit

struct CameraView: View {
    private enum SessionStartSource {
        case tap
        case gesture
    }

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var cameraManager: CameraManager
    @StateObject private var recordingManager: RecordingManager
    @StateObject private var humanDetectionService: HumanDetectionService
    @StateObject private var bleManager: BLEManager
    @StateObject private var motorOwnership: MotorControlOwnership
    @StateObject private var developerTuning: DeveloperTuningStore
    @StateObject private var automaticPanTiltController: AutomaticPanTiltController
    @StateObject private var idleAimController: IdleAimController
    @State private var showsBLEDeviceManagement = false
    @State private var targetSelectionMessage: String?
    @State private var pendingSessionStartSource: SessionStartSource?
    @State private var gestureConfirmationMessage: String?
    @State private var gestureConfirmationID = UUID()
    @State private var recordingGuidanceID = UUID()
    @State private var isTrackingSessionActive = false
    @State private var isAimExpanded = false

    init() {
        let cameraManager = CameraManager()
        let bleManager = BLEManager()
        let motorOwnership = MotorControlOwnership()
        let developerTuning = DeveloperTuningStore()
        let idleFramingBridge = IdleFramingBridge()
        _cameraManager = StateObject(wrappedValue: cameraManager)
        _recordingManager = StateObject(
            wrappedValue: RecordingManager(
                cameraManager: cameraManager,
                recordingOutputModes: developerTuning.recordingOutputModes
            )
        )
        _humanDetectionService = StateObject(
            wrappedValue: HumanDetectionService(
                cameraManager: cameraManager,
                zoomTuningBridge: developerTuning.zoomBridge,
                trackingTuningBridge: developerTuning.trackingBridge,
                idleFramingBridge: idleFramingBridge
            )
        )
        _bleManager = StateObject(wrappedValue: bleManager)
        _motorOwnership = StateObject(wrappedValue: motorOwnership)
        _developerTuning = StateObject(wrappedValue: developerTuning)
        _automaticPanTiltController = StateObject(
            wrappedValue: AutomaticPanTiltController(
                bleManager: bleManager,
                ownership: motorOwnership,
                tuningStore: developerTuning
            )
        )
        _idleAimController = StateObject(
            wrappedValue: IdleAimController(
                bleManager: bleManager,
                ownership: motorOwnership,
                tuningStore: developerTuning,
                framingBridge: idleFramingBridge
            )
        )
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            CameraPreview(
                session: cameraManager.session,
                displayCrop: humanDetectionService.latestFrame.trackingMetadata.displayCrop,
                orientedImageSize: humanDetectionService.latestFrame.orientedImageSize
            )
                .ignoresSafeArea()

            PersonDetectionOverlay(
                frame: humanDetectionService.latestFrame,
                gestureStatus: humanDetectionService.gestureStatus,
                gestureDiagnosticText: humanDetectionService.gestureDiagnosticText,
                allowsSelection: canSelectTarget,
                onSelect: selectTarget
            )
                .ignoresSafeArea()

            if TrackingDebugConfiguration.showsMotorControlOverlay {
                AutomaticPanTiltDebugOverlay(
                    controller: automaticPanTiltController,
                    frame: humanDetectionService.latestFrame
                )
                .ignoresSafeArea()
            }

            if let gestureConfirmationMessage {
                Text(gestureConfirmationMessage)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.72), in: Capsule())
                    .transition(.opacity.combined(with: .scale))
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(20)
            }

            VStack {
                if recordingManager.showsRecordingIndicator {
                    recordingBanner
                }

                Spacer()

                if canShowAimControls {
                    IdleAimControls(
                        controller: idleAimController,
                        canMoveMotors: bleManager.canSendCommands,
                        isExpanded: aimExpandedBinding
                    )
                }

                recordingControls
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            VStack {
                HStack {
                    Spacer()

                    Button {
                        isAimExpanded = false
                        idleAimController.deactivate(disableMotors: true)
                        showsBLEDeviceManagement = true
                    } label: {
                        BLEStatusControl(manager: bleManager)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            // Align with the recording-duration banner and keep diagnostics unobstructed.
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .onAppear {
            updateIdleTimer(for: scenePhase)
            idleAimController.updateCameraPosition(cameraManager.cameraPosition)
            cameraManager.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            idleAimController.deactivate(disableMotors: true)
            automaticPanTiltController.stopSession()
            humanDetectionService.clear()
            recordingManager.stopRecording()
            cameraManager.stop()
        }
        .onChange(of: recordingManager.state) { _, newState in
            handleRecordingStateChange(newState)
        }
        .onChange(of: humanDetectionService.gestureCommandEvent) { _, event in
            guard let event else { return }
            handleGestureCommand(event.command)
        }
        .onReceive(humanDetectionService.$latestFrame) { frame in
            automaticPanTiltController.process(
                frame: frame,
                target: humanDetectionService.currentTarget
            )
            recordingManager.updateTrackingFrame(frame)
            recordingManager.updateMotorControlDiagnostics(
                automaticPanTiltController.recordingDebugSnapshot
            )
        }
        .onChange(of: automaticPanTiltController.isMotorMoving) { _, isMoving in
            updateCameraMotionState()
        }
        .onChange(of: automaticPanTiltController.commandSequence) { _, _ in
            recordingManager.updateMotorControlDiagnostics(
                automaticPanTiltController.recordingDebugSnapshot
            )
        }
        .onChange(of: idleAimController.isMotorMoving) { _, isMoving in
            updateCameraMotionState()
        }
        .onChange(of: idleAimController.zoomFactor) { _, _ in
            humanDetectionService.refreshIdleFraming()
        }
        .onChange(of: bleManager.state) { _, newState in
            automaticPanTiltController.handleBLEStateChange(newState)
            idleAimController.handleBLEStateChange(newState)
        }
        .onReceive(bleManager.$latestDeviceStatus) { status in
            automaticPanTiltController.handleDeviceStatus(status)
            idleAimController.handleDeviceStatus(status)
        }
        .onReceive(bleManager.$latestWriteCompletionDiagnostic) { diagnostic in
            automaticPanTiltController.handleBLEWriteCompletion(diagnostic)
        }
        .onReceive(bleManager.$latestDeviceAcknowledgementDiagnostic) { diagnostic in
            automaticPanTiltController.handleDeviceAcknowledgement(diagnostic)
        }
        .onChange(of: motorOwnership.owner) { _, owner in
            automaticPanTiltController.handleOwnershipChange(owner)
        }
        .onChange(of: developerTuning.panTiltRevision) { _, _ in
            automaticPanTiltController.tuningDidChange()
            idleAimController.tuningDidChange()
        }
        .onChange(of: developerTuning.recordingOutputModes) { _, modes in
            recordingManager.updateRecordingOutputModes(modes)
        }
        .onReceive(humanDetectionService.$gestureStatus) { status in
            recordingManager.updateGestureDiagnostics(
                status: status,
                diagnosticText: humanDetectionService.gestureDiagnosticText
            )
        }
        .onReceive(humanDetectionService.$gestureDiagnosticText) { diagnosticText in
            recordingManager.updateGestureDiagnostics(
                status: humanDetectionService.gestureStatus,
                diagnosticText: diagnosticText
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            updateIdleTimer(for: newPhase)
            automaticPanTiltController.updateAppActivity(isActive: newPhase == .active)
            if newPhase != .active {
                isAimExpanded = false
                idleAimController.deactivate(disableMotors: true)
            }
        }
        .sheet(isPresented: $showsBLEDeviceManagement) {
            BLEDeviceManagementView(
                manager: bleManager,
                motorOwnership: motorOwnership,
                developerTuning: developerTuning
            )
        }
    }

    private var recordingControls: some View {
        VStack(spacing: 12) {
            if let recordingStatusMessage {
                Text(recordingStatusMessage)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
            }

            if let motorControlStatusMessage {
                Text(motorControlStatusMessage)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.yellow)
            }

            HStack {
                Button {
                    recordingManager.toggleMute()
                } label: {
                    Image(systemName: recordingManager.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.title3)
                        .foregroundStyle(recordingManager.isMuted ? .yellow : .white)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(
                    !recordingManager.isAudioAvailable
                )
                .opacity(
                    recordingManager.isAudioAvailable ? 1 : 0.55
                )
                .accessibilityLabel(recordingManager.isMuted ? "Unmute microphone" : "Mute microphone")

                Spacer()

                Button {
                    if recordingManager.canStopRecording {
                        stopSession()
                    } else {
                        showTrackingStartGuidance()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 76, height: 76)

                        if recordingManager.showsRecordingIndicator {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.red)
                                .frame(width: 30, height: 30)
                        } else {
                            Circle()
                                .fill(.red)
                                .frame(width: 62, height: 62)
                        }
                    }
                    .animation(
                        .easeInOut(duration: 0.15),
                        value: recordingManager.showsRecordingIndicator
                    )
                }
                .buttonStyle(.plain)
                .disabled(!isRecordButtonEnabled)
                .opacity(isRecordButtonEnabled ? 1 : 0.55)
                .accessibilityLabel(
                    recordingManager.showsRecordingIndicator
                        ? "Stop recording"
                        : "Select a person to start recording"
                )
                .accessibilityHint(
                    recordingManager.showsRecordingIndicator
                        ? "Stops recording and tracking"
                        : "Tap a green person box or use the Track Me gesture"
                )

                Spacer()

                Button {
                    isAimExpanded = false
                    idleAimController.deactivate(disableMotors: true)
                    automaticPanTiltController.cameraWillChange()
                    recordingManager.switchCamera { wasSwitched in
                        idleAimController.updateCameraPosition(cameraManager.cameraPosition)
                        automaticPanTiltController.cameraDidChange(
                            to: cameraManager.cameraPosition
                        )
                        if !wasSwitched, isTrackingSessionActive {
                            targetSelectionMessage = "Camera switch failed; motor control is waiting for a fresh target."
                        }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.45), in: Circle())
                        .rotationEffect(.degrees(cameraManager.isSwitchingCamera ? 180 : 0))
                        .animation(.easeInOut(duration: 0.25), value: cameraManager.isSwitchingCamera)
                }
                .buttonStyle(.plain)
                .disabled(
                    cameraManager.state != .running ||
                    cameraManager.isSwitchingCamera
                )
                .opacity(cameraManager.state == .running ? 1 : 0.55)
                .accessibilityLabel(
                    cameraManager.cameraPosition == .back
                        ? "Switch to front camera"
                        : "Switch to rear camera"
                )
            }
            .frame(maxWidth: 300)
        }
    }

    private var recordingBanner: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            HStack(spacing: 10) {
                Text("Recording")
                Text(formattedDuration(at: context.date))
                    .monospacedDigit()
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.red, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var isRecordButtonEnabled: Bool {
        if recordingManager.showsRecordingIndicator {
            return recordingManager.canStopRecording
        }

        return cameraManager.state == .running && recordingManager.canStartRecording
    }

    private var canShowAimControls: Bool {
        cameraManager.state == .running
            && recordingManager.canStartRecording
            && !humanDetectionService.hasTarget
    }

    private var aimExpandedBinding: Binding<Bool> {
        Binding(
            get: { isAimExpanded },
            set: { isExpanded in
                if !isExpanded {
                    idleAimController.deactivate(disableMotors: true)
                }
                isAimExpanded = isExpanded
            }
        )
    }

    private var recordingStatusMessage: String? {
        if humanDetectionService.isPreparingTarget {
            return "Initializing target identity…"
        }

        if let targetSelectionMessage {
            return targetSelectionMessage
        }

        return switch recordingManager.state {
        case .idle:
            recordingManager.isAudioAvailable
                ? nil
                : "Microphone unavailable. Videos will be silent."
        case .requestingPhotosPermission:
            "Requesting Photos access…"
        case .requestingMicrophonePermission:
            "Requesting microphone access…"
        case .preparing:
            "Preparing recording…"
        case .recording:
            nil
        case .stopping:
            nil
        case .saving:
            "Saving to Photos…"
        case .saved:
            "Saved to Photos"
        case .photosPermissionDenied:
            "Photos access is required to save videos."
        case .failed(let message):
            message
        }
    }

    private var motorControlStatusMessage: String? {
        guard isTrackingSessionActive else { return nil }
        return switch automaticPanTiltController.state {
        case .suspended(.bleDisconnected):
            "Motor control unavailable — tracking and recording continue"
        case .suspended(let reason):
            "Motor control suspended: \(reason.displayName.lowercased())"
        case .awaitingMotorEnable:
            "Enabling motors…"
        default:
            nil
        }
    }

    private func formattedDuration(at date: Date) -> String {
        let totalSeconds = Int(recordingManager.recordingDuration(at: date))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private var statusMessage: String? {
        switch cameraManager.state {
        case .idle, .requestingPermission, .configuring:
            "Starting camera…"

        case .running:
            nil

        case .permissionDenied:
            "Camera access is required to show the live preview."

        case .unavailable:
            "No camera is available."

        case .failed(let message):
            message
        }
    }

    private var canSelectTarget: Bool {
        cameraManager.state == .running
            && recordingManager.canStartRecording
            && !humanDetectionService.hasTarget
    }

    private func selectTarget(_ detectionID: UUID) {
        startSession(for: detectionID, source: .tap)
    }

    /// Tap and gesture selection share target preparation and recording startup.
    private func startSession(for detectionID: UUID, source: SessionStartSource) {
        guard canSelectTarget else { return }
        targetSelectionMessage = nil
        pendingSessionStartSource = source
        isAimExpanded = false
        idleAimController.prepareForAutomaticHandoff()

        humanDetectionService.prepareTarget(detectionID: detectionID) { wasPrepared in
            if wasPrepared {
                recordingManager.startRecording()
                // A previously denied Photos state may be assigned the same
                // value again and therefore not trigger SwiftUI's onChange.
                handleRecordingStateChange(recordingManager.state)
            } else {
                idleAimController.deactivate(disableMotors: true)
                pendingSessionStartSource = nil
                humanDetectionService.resetGestureRecognition(usesCooldown: false)
                targetSelectionMessage = "Target identity could not be initialized. Try a larger, clearer view."
            }
        }
    }

    private func handleRecordingStateChange(_ newState: RecordingManager.State) {
        switch newState {
        case .recording:
            if humanDetectionService.hasTarget {
                targetSelectionMessage = nil
                humanDetectionService.activatePreparedTarget()
                isTrackingSessionActive = true
                automaticPanTiltController.startSession(
                    cameraPosition: cameraManager.cameraPosition
                )
                if pendingSessionStartSource == .gesture {
                    print("Session started by Track Me gesture")
                    showGestureConfirmation("TRACKING STARTED")
                }
                pendingSessionStartSource = nil
            }

        case .photosPermissionDenied, .failed:
            idleAimController.deactivate(disableMotors: true)
            if humanDetectionService.hasTarget {
                humanDetectionService.clearTarget()
            }
            pendingSessionStartSource = nil
            isTrackingSessionActive = false
            automaticPanTiltController.stopSession()
            humanDetectionService.resetGestureRecognition(usesCooldown: false)

        case .idle, .requestingPhotosPermission, .requestingMicrophonePermission,
             .preparing, .stopping, .saving, .saved:
            break
        }
    }

    /// The camera stop control owns the complete target-recording session lifecycle.
    private func stopSession(triggeredByGesture: Bool = false) {
        if isTrackingSessionActive {
            automaticPanTiltController.stopSession()
            isTrackingSessionActive = false
        }
        recordingManager.stopRecording()
        if humanDetectionService.hasTarget {
            humanDetectionService.clearTarget()
        }
        humanDetectionService.resetGestureRecognition(usesCooldown: triggeredByGesture)
        targetSelectionMessage = nil
        pendingSessionStartSource = nil
        if triggeredByGesture {
            print("Session stopped by crossed-arms gesture")
            showGestureConfirmation("SESSION STOPPED")
        }
    }

    /// The center control remains discoverable while idle, but ClimbTrack only
    /// records sessions that have an initialized tracking target.
    private func showTrackingStartGuidance() {
        let guidance = "Select a person or use the Track Me gesture to start."
        let guidanceID = UUID()
        recordingGuidanceID = guidanceID
        targetSelectionMessage = guidance

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard recordingGuidanceID == guidanceID,
                  targetSelectionMessage == guidance else { return }
            targetSelectionMessage = nil
        }
    }

    private func handleGestureCommand(_ command: GestureCommand) {
        switch command {
        case .trackMe(let detectionID):
            guard canSelectTarget else {
                humanDetectionService.resetGestureRecognition(usesCooldown: false)
                return
            }
            startSession(for: detectionID, source: .gesture)

        case .stop:
            // A stop gesture is actionable only during an active recording session.
            guard recordingManager.canStopRecording,
                  humanDetectionService.hasTarget else {
                humanDetectionService.resetGestureRecognition(usesCooldown: false)
                return
            }
            stopSession(triggeredByGesture: true)
        }
    }

    private func showGestureConfirmation(_ message: String) {
        let confirmationID = UUID()
        gestureConfirmationID = confirmationID
        withAnimation(.easeInOut(duration: 0.18)) {
            gestureConfirmationMessage = message
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard gestureConfirmationID == confirmationID else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                gestureConfirmationMessage = nil
            }
        }
    }

    /// Keep the camera view awake, but restore normal Auto-Lock in the background.
    private func updateIdleTimer(for phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = phase == .active
    }

    private func updateCameraMotionState() {
        humanDetectionService.setCameraMotionActive(
            automaticPanTiltController.isMotorMoving || idleAimController.isMotorMoving
        )
    }
}
