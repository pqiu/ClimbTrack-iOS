import AVFoundation
import Combine
import CoreGraphics
import Foundation

struct AutomaticPanTiltConfiguration: Sendable {
    // Identity and freshness gates.
    let minimumTargetConfidence: Float = 0.65
    let requiredStableObservationCount: Int
    let maximumObservationAge: TimeInterval = 0.35
    let maximumFrameSilence: TimeInterval = 0.55
    let maximumStableErrorChange: CGFloat = 0.15

    // Fractions of the currently displayed crop, not the original camera frame.
    let horizontalOuterThreshold: CGFloat
    let verticalOuterThreshold: CGFloat
    let horizontalInnerThreshold: CGFloat
    let verticalInnerThreshold: CGFloat
    let horizontalTargetOffset: CGFloat
    let verticalTargetOffset: CGFloat

    // MOVE parameters are continuous motor speeds in steps per second.
    let minimumPanSpeed: Int
    let maximumPanSpeed: Int
    let minimumTiltSpeed: Int
    let maximumTiltSpeed: Int
    let conservativeMaximumSpeed: Int
    let minimumSpeedChange: Int
    let commandInterval: TimeInterval
    let motorCommandLeaseDuration: TimeInterval

    let motorEnableTimeout: TimeInterval = 1.5
    let directionValidationMinimumDisplacement: CGFloat = 0.06
    let directionValidationFailureCount = 2
    let cropBoundaryWarningMargin: CGFloat = 0.06
    let cropBoundaryUrgentMargin: CGFloat = 0.025

    nonisolated init(tuning: PanTiltTuningSnapshot) {
        requiredStableObservationCount = tuning.requiredStableObservationCount
        horizontalOuterThreshold = tuning.horizontalOuterThreshold
        verticalOuterThreshold = tuning.verticalOuterThreshold
        horizontalInnerThreshold = tuning.horizontalInnerThreshold
        verticalInnerThreshold = tuning.verticalInnerThreshold
        horizontalTargetOffset = tuning.horizontalTargetOffset
        verticalTargetOffset = tuning.verticalTargetOffset
        minimumPanSpeed = min(tuning.minimumPanSpeed, tuning.maximumPanSpeed)
        maximumPanSpeed = max(tuning.minimumPanSpeed, tuning.maximumPanSpeed)
        minimumTiltSpeed = min(tuning.minimumTiltSpeed, tuning.maximumTiltSpeed)
        maximumTiltSpeed = max(tuning.minimumTiltSpeed, tuning.maximumTiltSpeed)
        conservativeMaximumSpeed = tuning.conservativeMaximumSpeed
        minimumSpeedChange = tuning.minimumSpeedChange
        commandInterval = tuning.commandInterval
        motorCommandLeaseDuration = tuning.motorCommandLeaseDuration
    }
}

enum AutomaticPanTiltSuspensionReason: Equatable {
    case noActiveSession
    case bleDisconnected
    case motorNotEnabled
    case targetMissing
    case targetAmbiguous
    case targetConfidenceLow
    case observationStale
    case manualControlActive
    case cameraChanged
    case unexpectedMovementDirection
    case firmwareError(String)
    case appInactive

    var displayName: String {
        switch self {
        case .noActiveSession: "NO ACTIVE SESSION"
        case .bleDisconnected: "BLE DISCONNECTED"
        case .motorNotEnabled: "MOTOR NOT ENABLED"
        case .targetMissing: "TARGET MISSING"
        case .targetAmbiguous: "TARGET AMBIGUOUS"
        case .targetConfidenceLow: "TARGET CONFIDENCE LOW"
        case .observationStale: "OBSERVATION STALE"
        case .manualControlActive: "MANUAL CONTROL ACTIVE"
        case .cameraChanged: "CAMERA CHANGED"
        case .unexpectedMovementDirection: "DIRECTION RESPONSE ERROR"
        case .firmwareError(let message): "FIRMWARE: \(message)"
        case .appInactive: "APP INACTIVE"
        }
    }
}

enum AutomaticPanTiltState: Equatable {
    case disabled
    case awaitingMotorEnable
    case awaitingStableTarget
    case idle
    case correcting
    case suspended(AutomaticPanTiltSuspensionReason)

    var displayName: String {
        switch self {
        case .disabled: "DISABLED"
        case .awaitingMotorEnable: "AWAITING ENABLE"
        case .awaitingStableTarget: "AWAITING STABLE TARGET"
        case .idle: "CENTERED"
        case .correcting: "CORRECTING"
        case .suspended(let reason): "SUSPENDED · \(reason.displayName)"
        }
    }
}

enum CropBoundaryPressure: String, Sendable {
    case none = "NONE"
    case warning = "WARNING"
    case urgent = "URGENT"
}

enum AutomaticMotorCommandKind: Sendable {
    case none
    case move
    case stop
}

struct CameraMotorDirectionMapping: Sendable {
    let panSign: Int
    let tiltSign: Int

    static func mapping(for position: AVCaptureDevice.Position) -> Self {
        // Both axes reverse when using the front-facing camera on the physical
        // mount. Keep these sign changes centralized and independent of preview
        // mirroring.
        switch position {
        case .front:
            Self(panSign: -1, tiltSign: -1)
        default:
            Self(panSign: 1, tiltSign: 1)
        }
    }
}

@MainActor
final class AutomaticPanTiltController: ObservableObject {
    @Published private(set) var state: AutomaticPanTiltState = .disabled
    @Published private(set) var normalizedHorizontalError: CGFloat = 0
    @Published private(set) var normalizedVerticalError: CGFloat = 0
    @Published private(set) var normalizedTargetHorizontalOffset: CGFloat = 0
    @Published private(set) var normalizedTargetVerticalOffset: CGFloat = 0
    @Published private(set) var stableObservationCount = 0
    @Published private(set) var lastPanSpeed = 0
    @Published private(set) var lastTiltSpeed = 0
    @Published private(set) var motorsEnabled = false
    @Published private(set) var correctionEpisode = 0
    @Published private(set) var cropBoundaryPressure: CropBoundaryPressure = .none
    @Published private(set) var targetConfidence: Float = 0
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
    @Published private(set) var commandSequence = 0
    @Published private(set) var lastCommandKind: AutomaticMotorCommandKind = .none
    @Published private(set) var lastCommandPanSpeed = 0
    @Published private(set) var lastCommandTiltSpeed = 0
    @Published private(set) var lastCommandTargetHorizontalOffset: CGFloat = 0
    @Published private(set) var lastCommandTargetVerticalOffset: CGFloat = 0
    @Published private(set) var lastCommandHorizontalError: CGFloat = 0
    @Published private(set) var lastCommandVerticalError: CGFloat = 0
    @Published private(set) var lastAcknowledgementStatus = "NONE"
    @Published private(set) var bleWriteDiagnosticText = "BLE WRITE · NONE"
    @Published private(set) var deviceAcknowledgementDiagnosticText = "MCU ACK · NONE"
    @Published private(set) var waitingForFreshObservation = false

    private let tuningStore: DeveloperTuningStore

    private weak var bleManager: BLEManager?
    private let ownership: MotorControlOwnership
    private var sessionID: UUID?
    private var enableTimeoutTask: Task<Void, Never>?
    private var staleFrameWatchdog: Task<Void, Never>?
    private var motorCommandLeaseTask: Task<Void, Never>?
    private var disableTask: Task<Void, Never>?
    private var lastFrameTimestamp: TimeInterval = 0
    private var lastFrameReceivedAt: TimeInterval = 0
    private var previousStableError: CGPoint?
    private var panCorrectionActive = false
    private var tiltCorrectionActive = false
    private var lastCommandSentAt: TimeInterval = 0
    private var directionIsValidated = false
    private var validationReference: CGPoint?
    private var validationDirection = CGPoint.zero
    private var directionValidationFailures = 0
    private var requiresFramesAfter: TimeInterval = 0
    private var appIsActive = true

    init(
        bleManager: BLEManager,
        ownership: MotorControlOwnership,
        tuningStore: DeveloperTuningStore
    ) {
        self.bleManager = bleManager
        self.ownership = ownership
        self.tuningStore = tuningStore
    }

    var configuration: AutomaticPanTiltConfiguration {
        AutomaticPanTiltConfiguration(tuning: tuningStore.panTiltSnapshot)
    }

    var isSessionActive: Bool { sessionID != nil }
    var isMotorMoving: Bool { lastPanSpeed != 0 || lastTiltSpeed != 0 }
    var directionMapping: CameraMotorDirectionMapping {
        .mapping(for: cameraPosition)
    }
    var suspensionReason: AutomaticPanTiltSuspensionReason? {
        guard case .suspended(let reason) = state else { return nil }
        return reason
    }

    func startSession(cameraPosition: AVCaptureDevice.Position) {
        let id = UUID()
        stopTasks()
        resetRuntimeState()
        sessionID = id
        self.cameraPosition = cameraPosition
        startStaleFrameWatchdog(for: id)

        guard ownership.claimAutomaticControl() else {
            suspend(.manualControlActive, sendsStop: false)
            return
        }

        print("Automatic pan-tilt session started: \(id)")
        handleBLEStateChange(bleManager?.state ?? .neverSelected)
    }

    /// STOP is sent before DISABLE and all delayed work is invalidated first.
    func stopSession() {
        guard let stoppedSession = sessionID else {
            state = .disabled
            return
        }
        sessionID = nil
        stopTasks()
        sendStopIfNeeded(force: true)
        scheduleDisable()
        ownership.clear()
        resetRuntimeState()
        state = .disabled
        print("Automatic pan-tilt session stopped: \(stoppedSession)")
    }

    func process(frame: PersonDetectionFrame, target: TrackedTarget?) {
        guard sessionID != nil else { return }
        let timestamp = frame.trackingMetadata.timestamp
        guard timestamp > lastFrameTimestamp else { return }
        lastFrameTimestamp = timestamp
        lastFrameReceivedAt = ProcessInfo.processInfo.systemUptime

        guard appIsActive else {
            suspend(.appInactive)
            return
        }
        guard ownership.owner == .automaticTracking else {
            suspend(.manualControlActive)
            return
        }
        guard bleManager?.canSendCommands == true else {
            motorsEnabled = false
            suspend(.bleDisconnected, sendsStop: false)
            return
        }
        guard motorsEnabled else {
            if state != .awaitingMotorEnable { requestMotorEnable() }
            return
        }
        guard let target else {
            rejectObservation(.targetMissing)
            return
        }

        targetConfidence = target.matchConfidence
        switch target.visibilityState {
        case .lockedVisible:
            break
        case .lockedAmbiguous:
            rejectObservation(.targetAmbiguous)
            return
        case .lockedMissing, .unlocked:
            rejectObservation(.targetMissing)
            return
        }
        guard target.matchConfidence >= configuration.minimumTargetConfidence else {
            rejectObservation(.targetConfidenceLow)
            return
        }
        guard timestamp - target.lastSeenTimestamp <= configuration.maximumObservationAge else {
            rejectObservation(.observationStale)
            return
        }
        guard timestamp > requiresFramesAfter else { return }
        waitingForFreshObservation = false

        let crop = frame.trackingMetadata.displayCrop
        guard crop.width > 0, crop.height > 0 else { return }
        let targetOffset = CGPoint(
            x: (target.aimingCenter.x - crop.midX) / crop.width,
            y: (target.aimingCenter.y - crop.midY) / crop.height
        )
        normalizedTargetHorizontalOffset = targetOffset.x
        normalizedTargetVerticalOffset = targetOffset.y
        let error = CGPoint(
            x: targetOffset.x - configuration.horizontalTargetOffset,
            y: targetOffset.y - configuration.verticalTargetOffset
        )
        normalizedHorizontalError = error.x
        normalizedVerticalError = error.y
        cropBoundaryPressure = boundaryPressure(for: crop, error: error)

        if shouldRejectDirectionResponse(for: error) {
            suspend(.unexpectedMovementDirection)
            return
        }

        guard registerStableObservation(error) else {
            if isMotorMoving { sendStopIfNeeded(force: false) }
            state = .awaitingStableTarget
            return
        }

        updateCorrectionAxes(for: error)
        guard panCorrectionActive || tiltCorrectionActive else {
            sendStopIfNeeded(force: false)
            state = .idle
            return
        }

        if !isMotorMoving {
            correctionEpisode += 1
            print(String(format: "Correction %d started: x %.3f y %.3f", correctionEpisode, error.x, error.y))
        }
        sendVelocity(
            for: error,
            frameTimestamp: timestamp,
            zoomFactor: frame.trackingMetadata.zoomFactor
        )
    }

    func handleBLEStateChange(_ newState: BLEConnectionState) {
        guard sessionID != nil else { return }
        guard newState == .connected else {
            motorsEnabled = false
            suspend(.bleDisconnected, sendsStop: false)
            return
        }
        guard appIsActive, ownership.owner == .automaticTracking else { return }
        requestMotorEnable()
    }

    func handleDeviceStatus(_ status: String?) {
        guard sessionID != nil, let status else { return }
        let normalized = status.uppercased()
        lastAcknowledgementStatus = status
        if normalized.contains("OK ENABLE") {
            enableTimeoutTask?.cancel()
            enableTimeoutTask = nil
            motorsEnabled = true
            clearObservations(requiresFreshFrame: true)
            state = .awaitingStableTarget
            print("Automatic pan-tilt motors enabled")
        } else if normalized.contains("OK DISABLE") {
            motorsEnabled = false
        } else if normalized.hasPrefix("ERR") || normalized.contains("ERROR") {
            suspend(.firmwareError(status))
        }
    }

    func handleBLEWriteCompletion(_ diagnostic: BLEWriteCompletionDiagnostic?) {
        guard let diagnostic else { return }
        let result = diagnostic.errorDescription.map { "ERROR · \($0)" } ?? "OK"
        bleWriteDiagnosticText = String(
            format: "BLE WRITE · %@ · %@ · Q%.0fms W%.0fms",
            diagnostic.command,
            result,
            diagnostic.queueDelay * 1_000,
            diagnostic.latency * 1_000
        )
    }

    func handleDeviceAcknowledgement(
        _ diagnostic: BLEDeviceAcknowledgementDiagnostic?
    ) {
        guard let diagnostic else { return }
        if let latency = diagnostic.matchingCommandLatency {
            deviceAcknowledgementDiagnosticText = String(
                format: "MCU ACK · %@ · +%.0fms",
                diagnostic.status,
                latency * 1_000
            )
        } else {
            deviceAcknowledgementDiagnosticText = "MCU ACK · \(diagnostic.status) · UNMATCHED"
        }
    }

    func handleOwnershipChange(_ owner: MotorControlOwner) {
        guard sessionID != nil else { return }
        switch owner {
        case .manual:
            suspend(.manualControlActive)
        case .none:
            guard ownership.claimAutomaticControl() else { return }
            clearObservations(requiresFreshFrame: true)
            if bleManager?.canSendCommands == true {
                requestMotorEnable()
            } else {
                suspend(.bleDisconnected, sendsStop: false)
            }
        case .automaticTracking:
            break
        }
    }

    func cameraWillChange() {
        guard sessionID != nil else { return }
        suspend(.cameraChanged)
        clearObservations(requiresFreshFrame: true)
    }

    func cameraDidChange(to position: AVCaptureDevice.Position) {
        cameraPosition = position
        directionIsValidated = false
        clearObservations(requiresFreshFrame: true)
        if sessionID != nil, motorsEnabled, ownership.owner == .automaticTracking {
            state = .awaitingStableTarget
        }
        print("Automatic pan-tilt camera changed: \(position.rawValue)")
    }

    func updateAppActivity(isActive: Bool) {
        appIsActive = isActive
        guard sessionID != nil else { return }
        if !isActive {
            suspend(.appInactive)
            motorsEnabled = false
            scheduleDisable()
        } else if bleManager?.canSendCommands == true,
                  ownership.owner == .automaticTracking {
            requestMotorEnable()
        }
    }

    func tuningDidChange() {
        guard sessionID != nil else { return }
        sendStopIfNeeded(force: false)
        clearObservations(requiresFreshFrame: true)
        directionIsValidated = false
        if motorsEnabled, ownership.owner == .automaticTracking {
            state = .awaitingStableTarget
        }
    }

    private func requestMotorEnable() {
        guard let sessionID,
              bleManager?.canSendCommands == true,
              ownership.owner == .automaticTracking else { return }
        disableTask?.cancel()
        disableTask = nil
        enableTimeoutTask?.cancel()
        state = .awaitingMotorEnable
        motorsEnabled = false
        guard bleManager?.send(.enable) == true else {
            suspend(.bleDisconnected, sendsStop: false)
            return
        }
        print("Automatic pan-tilt requested motor enable: \(sessionID)")
        enableTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.configuration.motorEnableTimeout ?? 1.5))
            guard !Task.isCancelled,
                  let self,
                  self.sessionID == sessionID,
                  !self.motorsEnabled else { return }
            self.suspend(.motorNotEnabled)
        }
    }

    private func registerStableObservation(_ error: CGPoint) -> Bool {
        if let previousStableError {
            let change = hypot(error.x - previousStableError.x, error.y - previousStableError.y)
            let horizontalConsistent = abs(error.x) <= configuration.horizontalOuterThreshold
                || abs(previousStableError.x) <= configuration.horizontalOuterThreshold
                || error.x.sign == previousStableError.x.sign
            let verticalConsistent = abs(error.y) <= configuration.verticalOuterThreshold
                || abs(previousStableError.y) <= configuration.verticalOuterThreshold
                || error.y.sign == previousStableError.y.sign
            if change > configuration.maximumStableErrorChange
                || !horizontalConsistent || !verticalConsistent {
                stableObservationCount = 1
            } else {
                stableObservationCount += 1
            }
        } else {
            stableObservationCount = 1
        }
        previousStableError = error
        return stableObservationCount >= configuration.requiredStableObservationCount
    }

    private func updateCorrectionAxes(for error: CGPoint) {
        if panCorrectionActive {
            if abs(error.x) <= configuration.horizontalInnerThreshold {
                panCorrectionActive = false
            }
        } else if abs(error.x) > configuration.horizontalOuterThreshold {
            panCorrectionActive = true
        }

        if tiltCorrectionActive {
            if abs(error.y) <= configuration.verticalInnerThreshold {
                tiltCorrectionActive = false
            }
        } else if abs(error.y) > configuration.verticalOuterThreshold {
            tiltCorrectionActive = true
        }
    }

    private func sendVelocity(
        for error: CGPoint,
        frameTimestamp: TimeInterval,
        zoomFactor: CGFloat
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let minimumPanSpeed = zoomScaledSpeed(
            configuration.minimumPanSpeed,
            zoomFactor: zoomFactor
        )
        let maximumPanSpeed = zoomScaledSpeed(
            configuration.maximumPanSpeed,
            zoomFactor: zoomFactor
        )
        let minimumTiltSpeed = zoomScaledSpeed(
            configuration.minimumTiltSpeed,
            zoomFactor: zoomFactor
        )
        let maximumTiltSpeed = zoomScaledSpeed(
            configuration.maximumTiltSpeed,
            zoomFactor: zoomFactor
        )
        let pressureMultiplier: CGFloat = switch cropBoundaryPressure {
        case .none: 1
        case .warning: 1.15
        case .urgent: 1.30
        }
        let panMagnitude = panCorrectionActive
            ? proportionalSpeed(
                error: abs(error.x),
                innerThreshold: configuration.horizontalInnerThreshold,
                minimum: minimumPanSpeed,
                maximum: maximumPanSpeed,
                multiplier: pressureMultiplier
            ) : 0
        let tiltMagnitude = tiltCorrectionActive
            ? proportionalSpeed(
                error: abs(error.y),
                innerThreshold: configuration.verticalInnerThreshold,
                minimum: minimumTiltSpeed,
                maximum: maximumTiltSpeed,
                multiplier: pressureMultiplier
            ) : 0
        let mapping = directionMapping
        let pan = signed(panMagnitude, like: error.x) * mapping.panSign
        let tilt = signed(tiltMagnitude, like: error.y) * mapping.tiltSign

        let changedEnough = abs(pan - lastPanSpeed) >= configuration.minimumSpeedChange
            || abs(tilt - lastTiltSpeed) >= configuration.minimumSpeedChange
            || pan == 0 && lastPanSpeed != 0
            || tilt == 0 && lastTiltSpeed != 0
        guard changedEnough else {
            // A reliable observation confirmed that the existing continuous
            // command is still appropriate, so extend its safety deadline.
            renewMotorCommandLease()
            state = .correcting
            return
        }
        guard now - lastCommandSentAt >= configuration.commandInterval else {
            // If rate limiting delays an update, only renew the existing command
            // when none of its active axes now needs to stop or reverse.
            if commandRemainsSafe(desiredPan: pan, desiredTilt: tilt) {
                renewMotorCommandLease()
            }
            return
        }
        guard bleManager?.send(.move(panSpeed: pan, tiltSpeed: tilt)) == true else {
            motorsEnabled = false
            suspend(.bleDisconnected, sendsStop: false)
            return
        }

        validationReference = error
        validationDirection = CGPoint(
            x: panCorrectionActive ? error.x.signValue : 0,
            y: tiltCorrectionActive ? error.y.signValue : 0
        )
        requiresFramesAfter = frameTimestamp
        waitingForFreshObservation = true
        lastFrameTimestamp = frameTimestamp
        lastPanSpeed = pan
        lastTiltSpeed = tilt
        lastCommandSentAt = now
        commandSequence += 1
        lastCommandKind = .move
        lastCommandPanSpeed = pan
        lastCommandTiltSpeed = tilt
        lastCommandTargetHorizontalOffset = normalizedTargetHorizontalOffset
        lastCommandTargetVerticalOffset = normalizedTargetVerticalOffset
        lastCommandHorizontalError = error.x
        lastCommandVerticalError = error.y
        state = .correcting
        renewMotorCommandLease()
    }

    private func zoomScaledSpeed(_ configuredSpeed: Int, zoomFactor: CGFloat) -> Int {
        guard configuredSpeed > 0 else { return 0 }
        let zoom = zoomFactor.isFinite ? max(1, zoomFactor) : 1
        return max(1, Int((CGFloat(configuredSpeed) / zoom).rounded()))
    }

    private func commandRemainsSafe(desiredPan: Int, desiredTilt: Int) -> Bool {
        axisCommandRemainsSafe(current: lastPanSpeed, desired: desiredPan)
            && axisCommandRemainsSafe(current: lastTiltSpeed, desired: desiredTilt)
    }

    private func axisCommandRemainsSafe(current: Int, desired: Int) -> Bool {
        current == 0 || (desired != 0 && current.signum() == desired.signum())
    }

    private func proportionalSpeed(
        error: CGFloat,
        innerThreshold: CGFloat,
        minimum: Int,
        maximum: Int,
        multiplier: CGFloat
    ) -> Int {
        let fraction = min(1, max(0, (error - innerThreshold) / (0.5 - innerThreshold)))
        var speed = CGFloat(minimum) + fraction * CGFloat(maximum - minimum)
        speed *= multiplier
        let activeMaximum = directionIsValidated ? maximum : min(maximum, configuration.conservativeMaximumSpeed)
        return min(activeMaximum, max(minimum, Int(speed.rounded())))
    }

    private func shouldRejectDirectionResponse(for error: CGPoint) -> Bool {
        guard let reference = validationReference else { return false }
        var failed = false
        var validated = false

        if validationDirection.x != 0 {
            let signedDisplacement = (error.x - reference.x) * validationDirection.x
            if signedDisplacement > configuration.directionValidationMinimumDisplacement {
                failed = true
            } else if signedDisplacement < -configuration.directionValidationMinimumDisplacement / 2 {
                validated = true
            }
        }
        if validationDirection.y != 0 {
            let signedDisplacement = (error.y - reference.y) * validationDirection.y
            if signedDisplacement > configuration.directionValidationMinimumDisplacement {
                failed = true
            } else if signedDisplacement < -configuration.directionValidationMinimumDisplacement / 2 {
                validated = true
            }
        }
        validationReference = nil
        waitingForFreshObservation = false

        if failed {
            directionValidationFailures += 1
        } else {
            directionValidationFailures = 0
            if validated { directionIsValidated = true }
        }
        return directionValidationFailures >= configuration.directionValidationFailureCount
    }

    private func boundaryPressure(for crop: CGRect, error: CGPoint) -> CropBoundaryPressure {
        let margin: CGFloat
        if abs(error.x) >= abs(error.y) {
            margin = error.x < 0 ? crop.minX : 1 - crop.maxX
        } else {
            margin = error.y < 0 ? crop.minY : 1 - crop.maxY
        }
        if margin <= configuration.cropBoundaryUrgentMargin { return .urgent }
        if margin <= configuration.cropBoundaryWarningMargin { return .warning }
        return .none
    }

    private func rejectObservation(_ reason: AutomaticPanTiltSuspensionReason) {
        clearObservations(requiresFreshFrame: false)
        directionIsValidated = false
        suspend(reason)
    }

    private func suspend(
        _ reason: AutomaticPanTiltSuspensionReason,
        sendsStop: Bool = true
    ) {
        if sendsStop {
            sendStopIfNeeded(force: false)
        } else {
            motorCommandLeaseTask?.cancel()
            motorCommandLeaseTask = nil
        }
        state = .suspended(reason)
    }

    private func sendStopIfNeeded(force: Bool) {
        motorCommandLeaseTask?.cancel()
        motorCommandLeaseTask = nil
        guard force || isMotorMoving else { return }
        let wasSent = bleManager?.send(.stop) == true
        if wasSent {
            commandSequence += 1
            lastCommandKind = .stop
            lastCommandPanSpeed = 0
            lastCommandTiltSpeed = 0
            lastCommandTargetHorizontalOffset = normalizedTargetHorizontalOffset
            lastCommandTargetVerticalOffset = normalizedTargetVerticalOffset
            lastCommandHorizontalError = normalizedHorizontalError
            lastCommandVerticalError = normalizedVerticalError
        }
        lastPanSpeed = 0
        lastTiltSpeed = 0
        panCorrectionActive = false
        tiltCorrectionActive = false
        validationReference = nil
    }

    /// MOVE is continuous in the firmware. Each reliable observation renews
    /// this phone-side lease; if analysis stalls, STOP bounds unintended travel.
    private func renewMotorCommandLease() {
        guard let activeSessionID = sessionID, isMotorMoving else { return }
        let duration = configuration.motorCommandLeaseDuration
        motorCommandLeaseTask?.cancel()
        motorCommandLeaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled,
                  let self,
                  self.sessionID == activeSessionID,
                  self.isMotorMoving else { return }
            self.motorCommandLeaseTask = nil
            self.clearObservations(requiresFreshFrame: true)
            self.sendStopIfNeeded(force: false)
            self.state = .suspended(.observationStale)
        }
    }

    private func scheduleDisable() {
        disableTask?.cancel()
        guard bleManager?.canSendCommands == true else { return }
        disableTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  let self,
                  self.ownership.owner != .manual else { return }
            _ = self.bleManager?.send(.disable)
        }
    }

    private func clearObservations(requiresFreshFrame: Bool) {
        stableObservationCount = 0
        previousStableError = nil
        panCorrectionActive = false
        tiltCorrectionActive = false
        validationReference = nil
        directionValidationFailures = 0
        if requiresFreshFrame {
            requiresFramesAfter = lastFrameTimestamp
            waitingForFreshObservation = true
        }
    }

    private func resetRuntimeState() {
        motorsEnabled = false
        normalizedHorizontalError = 0
        normalizedVerticalError = 0
        normalizedTargetHorizontalOffset = 0
        normalizedTargetVerticalOffset = 0
        stableObservationCount = 0
        targetConfidence = 0
        lastPanSpeed = 0
        lastTiltSpeed = 0
        correctionEpisode = 0
        cropBoundaryPressure = .none
        lastFrameTimestamp = 0
        lastFrameReceivedAt = 0
        lastCommandSentAt = 0
        requiresFramesAfter = 0
        previousStableError = nil
        panCorrectionActive = false
        tiltCorrectionActive = false
        directionIsValidated = false
        validationReference = nil
        validationDirection = .zero
        directionValidationFailures = 0
        commandSequence = 0
        lastCommandKind = .none
        lastCommandPanSpeed = 0
        lastCommandTiltSpeed = 0
        lastCommandTargetHorizontalOffset = 0
        lastCommandTargetVerticalOffset = 0
        lastCommandHorizontalError = 0
        lastCommandVerticalError = 0
        lastAcknowledgementStatus = "NONE"
        bleWriteDiagnosticText = "BLE WRITE · NONE"
        deviceAcknowledgementDiagnosticText = "MCU ACK · NONE"
        waitingForFreshObservation = false
    }

    private func startStaleFrameWatchdog(for sessionID: UUID) {
        staleFrameWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.sessionID == sessionID else { return }
                guard self.lastFrameReceivedAt > 0 else { continue }
                let silence = ProcessInfo.processInfo.systemUptime - self.lastFrameReceivedAt
                if silence > self.configuration.maximumFrameSilence {
                    self.clearObservations(requiresFreshFrame: true)
                    self.suspend(.observationStale)
                }
            }
        }
    }

    private func stopTasks() {
        enableTimeoutTask?.cancel()
        enableTimeoutTask = nil
        staleFrameWatchdog?.cancel()
        staleFrameWatchdog = nil
        motorCommandLeaseTask?.cancel()
        motorCommandLeaseTask = nil
        disableTask?.cancel()
        disableTask = nil
    }

    private func signed(_ magnitude: Int, like value: CGFloat) -> Int {
        value < 0 ? -magnitude : magnitude
    }
}

private extension CGFloat {
    var signValue: CGFloat { self < 0 ? -1 : 1 }
}
