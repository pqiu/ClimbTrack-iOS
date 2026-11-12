import Combine
import CoreGraphics
import Foundation

nonisolated enum ZoomControlMode: String, CaseIterable, Sendable {
    case hysteresis
    case continuous

    var displayName: String {
        switch self {
        case .hysteresis: "Hysteresis"
        case .continuous: "Continuous"
        }
    }
}

nonisolated enum RecordingOutputMode: String, CaseIterable, Sendable {
    case debugZoomedTracking
    case fullFramePeopleBoxes
    case fullFrameClean
    case smoothZoomedClean

    var displayName: String {
        switch self {
        case .debugZoomedTracking: "1 · Zoomed + Full Debug"
        case .fullFramePeopleBoxes: "2 · Full Frame + Person Boxes"
        case .fullFrameClean: "3 · Full Frame + Clean"
        case .smoothZoomedClean: "4 · Smooth Zoomed + Clean"
        }
    }

    var detail: String {
        switch self {
        case .debugZoomedTracking:
            "Current behavior: tracking crop and all diagnostics update with Vision results."
        case .fullFramePeopleBoxes:
            "Full camera view with red target and green detected-person boxes; boxes update with Vision results."
        case .fullFrameClean:
            "Full camera view at camera frame rate with no boxes or diagnostics."
        case .smoothZoomedClean:
            "Zoomed view with the crop interpolated on every camera frame and no overlays."
        }
    }

    var fileNameComponent: String {
        switch self {
        case .debugZoomedTracking: "Debug-Zoomed"
        case .fullFramePeopleBoxes: "Full-People"
        case .fullFrameClean: "Full-Clean"
        case .smoothZoomedClean: "Zoomed-Clean"
        }
    }

    var usesEightHertzFrames: Bool {
        switch self {
        case .debugZoomedTracking, .fullFramePeopleBoxes:
            true
        case .fullFrameClean, .smoothZoomedClean:
            false
        }
    }
}

nonisolated enum PersonDetectionBackend: String, CaseIterable, Sendable {
    case appleVision
    case appleVisionSkeleton
    case yoloxNano
    case yoloxTiny
    case yoloxSmall

    static let selectableCases: [PersonDetectionBackend] = [
        .yoloxNano,
        .yoloxTiny,
        .yoloxSmall,
        .appleVision,
        .appleVisionSkeleton
    ]

    var displayName: String {
        switch self {
        case .appleVision: "Apple Vision"
        case .appleVisionSkeleton: "Apple Vision + Skeleton"
        case .yoloxNano: "YOLOX-Nano"
        case .yoloxTiny: "YOLOX-Tiny"
        case .yoloxSmall: "YOLOX-S"
        }
    }
}

nonisolated enum IdentityMatchingBackend: String, CaseIterable, Sendable {
    case appleFeaturePrint

    var displayName: String {
        "Apple Feature Print"
    }
}

nonisolated struct ZoomTuningSnapshot: Equatable, Sendable {
    let mode: ZoomControlMode
    let hysteresisTargetFraction: CGFloat
    let zoomInTriggerFraction: CGFloat
    let zoomOutTriggerFraction: CGFloat
    let hysteresisViewportSmoothing: CGFloat
    let continuousFramingScale: CGFloat
    let continuousToleranceFraction: CGFloat
    let continuousViewportSmoothing: CGFloat
}

nonisolated struct PanTiltTuningSnapshot: Sendable {
    let horizontalInnerThreshold: CGFloat
    let verticalInnerThreshold: CGFloat
    let horizontalOuterThreshold: CGFloat
    let verticalOuterThreshold: CGFloat
    let horizontalTargetOffset: CGFloat
    let verticalTargetOffset: CGFloat
    let minimumPanSpeed: Int
    let maximumPanSpeed: Int
    let minimumTiltSpeed: Int
    let maximumTiltSpeed: Int
    let conservativeMaximumSpeed: Int
    let minimumSpeedChange: Int
    let commandInterval: TimeInterval
    let motorCommandLeaseDuration: TimeInterval
    let requiredStableObservationCount: Int
}

nonisolated struct TrackingTuningSnapshot: Equatable, Sendable {
    let detectionBackend: PersonDetectionBackend
    let identityBackend: IdentityMatchingBackend
    let trackingIdentityThreshold: CGFloat
    let trackingAppearanceTotalThreshold: CGFloat
    let trackingGeometryOnlyTotalThreshold: CGFloat
    let maximumCenterDisplacement: CGFloat
    let reacquisitionIdentityThreshold: CGFloat
    let reacquisitionIdentityMargin: CGFloat
    let reacquisitionConfirmationFrames: Int
    let poseMinimumJointConfidence: Float
    let torsoAnchorSmoothing: CGFloat
    let maximumTorsoAnchorStep: CGFloat
    let suspiciousScaleRatio: CGFloat
    let rejectionScaleRatio: CGFloat
}

/// Vision reads zoom tuning on its serial worker queue, while SwiftUI edits it
/// on the main actor. The lock provides a small immutable snapshot at each frame.
nonisolated final class ZoomTuningBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ZoomTuningSnapshot

    init(initialValue: ZoomTuningSnapshot) {
        value = initialValue
    }

    func update(_ newValue: ZoomTuningSnapshot) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func snapshot() -> ZoomTuningSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// TargetTracker runs on Vision's worker queue while SwiftUI edits these values.
nonisolated final class TrackingTuningBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TrackingTuningSnapshot

    init(initialValue: TrackingTuningSnapshot) {
        value = initialValue
    }

    func update(_ newValue: TrackingTuningSnapshot) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func snapshot() -> TrackingTuningSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class DeveloperTuningStore: ObservableObject {
    private enum Key {
        static let prefix = "ClimbTrack.developerTuning."
        static let defaultsRevision = prefix + "defaultsRevision"
        static let zoomMode = prefix + "zoomMode"
        static let recordingOutputMode = prefix + "recordingOutputMode"
        static let recordingOutputModes = prefix + "recordingOutputModes"
        static let hysteresisTarget = prefix + "hysteresisTarget"
        static let zoomInTrigger = prefix + "zoomInTrigger"
        static let zoomOutTrigger = prefix + "zoomOutTrigger"
        static let hysteresisSmoothing = prefix + "hysteresisSmoothing"
        static let continuousScale = prefix + "continuousScale"
        static let continuousTolerance = prefix + "continuousTolerance"
        static let continuousSmoothing = prefix + "continuousSmoothing"
        static let horizontalInner = prefix + "horizontalInner"
        static let verticalInner = prefix + "verticalInner"
        static let horizontalOuter = prefix + "horizontalOuter"
        static let verticalOuter = prefix + "verticalOuter"
        static let horizontalTargetOffset = prefix + "horizontalTargetOffset"
        static let verticalTargetOffset = prefix + "verticalTargetOffset"
        static let minimumPanSpeed = prefix + "minimumPanSpeed"
        static let maximumPanSpeed = prefix + "maximumPanSpeed"
        static let minimumTiltSpeed = prefix + "minimumTiltSpeed"
        static let maximumTiltSpeed = prefix + "maximumTiltSpeed"
        static let conservativeMaximumSpeed = prefix + "conservativeMaximumSpeed"
        static let minimumSpeedChange = prefix + "minimumSpeedChange"
        static let commandInterval = prefix + "commandInterval"
        static let motorCommandLeaseDuration = prefix + "motorCommandLeaseDuration"
        static let stableObservations = prefix + "stableObservations"
        static let manualAimSpeed = prefix + "manualAimSpeed"
        static let detectionBackend = prefix + "detectionBackend"
        static let identityBackend = prefix + "identityBackend"
        static let trackingIdentityThreshold = prefix + "trackingIdentityThreshold"
        static let trackingAppearanceTotalThreshold = prefix + "trackingAppearanceTotalThreshold"
        static let trackingGeometryOnlyTotalThreshold = prefix + "trackingGeometryOnlyTotalThreshold"
        static let maximumCenterDisplacement = prefix + "maximumCenterDisplacement"
        static let reacquisitionIdentityThreshold = prefix + "reacquisitionIdentityThreshold"
        static let reacquisitionIdentityMargin = prefix + "reacquisitionIdentityMargin"
        static let reacquisitionConfirmationFrames = prefix + "reacquisitionConfirmationFrames"
        static let poseMinimumJointConfidence = prefix + "poseMinimumJointConfidence"
        static let torsoAnchorSmoothing = prefix + "torsoAnchorSmoothing"
        static let maximumTorsoAnchorStep = prefix + "maximumTorsoAnchorStep"
        static let suspiciousScaleRatio = prefix + "suspiciousScaleRatio"
        static let rejectionScaleRatio = prefix + "rejectionScaleRatio"
    }

    private enum Defaults {
        static let revision = 3
        static let zoomMode = ZoomControlMode.hysteresis
        static let recordingOutputMode = RecordingOutputMode.smoothZoomedClean
        static let hysteresisTarget = 50.0
        static let zoomInTrigger = 40.0
        static let zoomOutTrigger = 60.0
        static let hysteresisSmoothing = 0.04
        static let continuousScale = 2.0
        static let continuousTolerance = 3.0
        static let continuousSmoothing = 0.20
        static let horizontalInner = 3.0
        static let verticalInner = 3.0
        static let horizontalOuter = 10.0
        static let verticalOuter = 10.0
        static let horizontalTargetOffset = 0.0
        static let verticalTargetOffset = 0.0
        static let minimumPanSpeed = 50.0
        static let maximumPanSpeed = 1_000.0
        static let minimumTiltSpeed = 50.0
        static let maximumTiltSpeed = 1_150.0
        static let conservativeMaximumSpeed = 625.0
        static let minimumSpeedChange = 25.0
        static let commandInterval = 0.10
        static let motorCommandLeaseDuration = 0.36
        static let stableObservations = 3.0
        static let manualAimSpeed = 100.0
        static let detectionBackend = PersonDetectionBackend.yoloxSmall
        static let identityBackend = IdentityMatchingBackend.appleFeaturePrint
        static let trackingIdentityThreshold = 0.40
        static let trackingAppearanceTotalThreshold = 0.45
        static let trackingGeometryOnlyTotalThreshold = 0.50
        static let maximumCenterDisplacementPercent = 35.0
        static let reacquisitionIdentityThreshold = 0.50
        static let reacquisitionIdentityMargin = 0.10
        static let reacquisitionConfirmationFrames = 3.0
        static let poseMinimumJointConfidence = 0.25
        static let torsoAnchorSmoothing = 0.35
        static let maximumTorsoAnchorStepPercent = 12.0
        static let suspiciousScaleRatio = 6.0
        static let rejectionScaleRatio = 8.0
    }

    @Published var zoomMode: ZoomControlMode { didSet { synchronizeZoom() } }
    @Published private(set) var recordingOutputModes: Set<RecordingOutputMode>
    @Published var hysteresisTargetPercent: Double { didSet { synchronizeZoom() } }
    @Published var zoomInTriggerPercent: Double { didSet { synchronizeZoom() } }
    @Published var zoomOutTriggerPercent: Double { didSet { synchronizeZoom() } }
    @Published var hysteresisViewportSmoothing: Double { didSet { synchronizeZoom() } }
    @Published var continuousFramingScale: Double { didSet { synchronizeZoom() } }
    @Published var continuousTolerancePercent: Double { didSet { synchronizeZoom() } }
    @Published var continuousViewportSmoothing: Double { didSet { synchronizeZoom() } }

    @Published var horizontalInnerPercent: Double { didSet { persistPanTilt() } }
    @Published var verticalInnerPercent: Double { didSet { persistPanTilt() } }
    @Published var horizontalOuterPercent: Double { didSet { persistPanTilt() } }
    @Published var verticalOuterPercent: Double { didSet { persistPanTilt() } }
    @Published var horizontalTargetOffsetPercent: Double { didSet { persistPanTilt() } }
    @Published var verticalTargetOffsetPercent: Double { didSet { persistPanTilt() } }
    @Published var minimumPanSpeed: Double { didSet { persistPanTilt() } }
    @Published var maximumPanSpeed: Double { didSet { persistPanTilt() } }
    @Published var minimumTiltSpeed: Double { didSet { persistPanTilt() } }
    @Published var maximumTiltSpeed: Double { didSet { persistPanTilt() } }
    @Published var conservativeMaximumSpeed: Double { didSet { persistPanTilt() } }
    @Published var minimumSpeedChange: Double { didSet { persistPanTilt() } }
    @Published var commandInterval: Double { didSet { persistPanTilt() } }
    @Published var motorCommandLeaseDuration: Double { didSet { persistPanTilt() } }
    @Published var requiredStableObservationCount: Double { didSet { persistPanTilt() } }
    @Published var manualAimSpeed: Double { didSet { persistPanTilt() } }
    @Published private(set) var panTiltRevision = 0

    @Published var detectionBackend: PersonDetectionBackend {
        didSet { synchronizeTracking() }
    }
    @Published var identityBackend: IdentityMatchingBackend {
        didSet { synchronizeTracking() }
    }
    @Published var trackingIdentityThreshold: Double { didSet { synchronizeTracking() } }
    @Published var trackingAppearanceTotalThreshold: Double {
        didSet { synchronizeTracking() }
    }
    @Published var trackingGeometryOnlyTotalThreshold: Double {
        didSet { synchronizeTracking() }
    }
    @Published var maximumCenterDisplacementPercent: Double {
        didSet { synchronizeTracking() }
    }
    @Published var reacquisitionIdentityThreshold: Double {
        didSet { synchronizeTracking() }
    }
    @Published var reacquisitionIdentityMargin: Double { didSet { synchronizeTracking() } }
    @Published var reacquisitionConfirmationFrames: Double {
        didSet { synchronizeTracking() }
    }
    @Published var poseMinimumJointConfidence: Double { didSet { synchronizeTracking() } }
    @Published var torsoAnchorSmoothing: Double { didSet { synchronizeTracking() } }
    @Published var maximumTorsoAnchorStepPercent: Double { didSet { synchronizeTracking() } }
    @Published var suspiciousScaleRatio: Double { didSet { synchronizeTracking() } }
    @Published var rejectionScaleRatio: Double { didSet { synchronizeTracking() } }

    let zoomBridge: ZoomTuningBridge
    let trackingBridge: TrackingTuningBridge
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        // Apply product-default revisions once so an installed development
        // build receives them without overwriting later field-test tuning.
        Self.applyCurrentDefaultsIfNeeded(to: userDefaults)
        self.userDefaults = userDefaults
        zoomBridge = ZoomTuningBridge(initialValue: Self.makeZoomSnapshot(
            mode: Defaults.zoomMode,
            target: Defaults.hysteresisTarget,
            lower: Defaults.zoomInTrigger,
            upper: Defaults.zoomOutTrigger,
            hysteresisSmoothing: Defaults.hysteresisSmoothing,
            continuousScale: Defaults.continuousScale,
            continuousTolerance: Defaults.continuousTolerance,
            continuousSmoothing: Defaults.continuousSmoothing
        ))
        trackingBridge = TrackingTuningBridge(initialValue: Self.makeTrackingSnapshot(
            detectionBackend: Defaults.detectionBackend,
            identityBackend: Defaults.identityBackend,
            trackingIdentityThreshold: Defaults.trackingIdentityThreshold,
            trackingAppearanceTotalThreshold: Defaults.trackingAppearanceTotalThreshold,
            trackingGeometryOnlyTotalThreshold: Defaults.trackingGeometryOnlyTotalThreshold,
            maximumCenterDisplacementPercent: Defaults.maximumCenterDisplacementPercent,
            reacquisitionIdentityThreshold: Defaults.reacquisitionIdentityThreshold,
            reacquisitionIdentityMargin: Defaults.reacquisitionIdentityMargin,
            reacquisitionConfirmationFrames: Defaults.reacquisitionConfirmationFrames,
            poseMinimumJointConfidence: Defaults.poseMinimumJointConfidence,
            torsoAnchorSmoothing: Defaults.torsoAnchorSmoothing,
            maximumTorsoAnchorStepPercent: Defaults.maximumTorsoAnchorStepPercent,
            suspiciousScaleRatio: Defaults.suspiciousScaleRatio,
            rejectionScaleRatio: Defaults.rejectionScaleRatio
        ))
        zoomMode = userDefaults.string(forKey: Key.zoomMode)
            .flatMap(ZoomControlMode.init(rawValue:)) ?? Defaults.zoomMode
        let savedModes = userDefaults.stringArray(forKey: Key.recordingOutputModes)?
            .compactMap(RecordingOutputMode.init(rawValue:)) ?? []
        let migratedMode = userDefaults.string(forKey: Key.recordingOutputMode)
            .flatMap(RecordingOutputMode.init(rawValue:)) ?? Defaults.recordingOutputMode
        recordingOutputModes = savedModes.isEmpty ? [migratedMode] : Set(savedModes)
        hysteresisTargetPercent = Self.double(userDefaults, Key.hysteresisTarget, Defaults.hysteresisTarget)
        zoomInTriggerPercent = Self.double(userDefaults, Key.zoomInTrigger, Defaults.zoomInTrigger)
        zoomOutTriggerPercent = Self.double(userDefaults, Key.zoomOutTrigger, Defaults.zoomOutTrigger)
        hysteresisViewportSmoothing = Self.double(userDefaults, Key.hysteresisSmoothing, Defaults.hysteresisSmoothing)
        continuousFramingScale = Self.double(userDefaults, Key.continuousScale, Defaults.continuousScale)
        continuousTolerancePercent = Self.double(userDefaults, Key.continuousTolerance, Defaults.continuousTolerance)
        continuousViewportSmoothing = Self.double(userDefaults, Key.continuousSmoothing, Defaults.continuousSmoothing)
        horizontalInnerPercent = Self.double(userDefaults, Key.horizontalInner, Defaults.horizontalInner)
        verticalInnerPercent = Self.double(userDefaults, Key.verticalInner, Defaults.verticalInner)
        horizontalOuterPercent = Self.double(userDefaults, Key.horizontalOuter, Defaults.horizontalOuter)
        verticalOuterPercent = Self.double(userDefaults, Key.verticalOuter, Defaults.verticalOuter)
        horizontalTargetOffsetPercent = Self.double(userDefaults, Key.horizontalTargetOffset, Defaults.horizontalTargetOffset)
        verticalTargetOffsetPercent = Self.double(userDefaults, Key.verticalTargetOffset, Defaults.verticalTargetOffset)
        minimumPanSpeed = Self.double(userDefaults, Key.minimumPanSpeed, Defaults.minimumPanSpeed)
        maximumPanSpeed = Self.double(userDefaults, Key.maximumPanSpeed, Defaults.maximumPanSpeed)
        minimumTiltSpeed = Self.double(userDefaults, Key.minimumTiltSpeed, Defaults.minimumTiltSpeed)
        maximumTiltSpeed = Self.double(userDefaults, Key.maximumTiltSpeed, Defaults.maximumTiltSpeed)
        conservativeMaximumSpeed = Self.double(userDefaults, Key.conservativeMaximumSpeed, Defaults.conservativeMaximumSpeed)
        minimumSpeedChange = Self.double(userDefaults, Key.minimumSpeedChange, Defaults.minimumSpeedChange)
        commandInterval = Self.double(userDefaults, Key.commandInterval, Defaults.commandInterval)
        motorCommandLeaseDuration = Self.double(
            userDefaults,
            Key.motorCommandLeaseDuration,
            Defaults.motorCommandLeaseDuration
        )
        requiredStableObservationCount = Self.double(userDefaults, Key.stableObservations, Defaults.stableObservations)
        manualAimSpeed = Self.double(userDefaults, Key.manualAimSpeed, Defaults.manualAimSpeed)
        detectionBackend = userDefaults.string(forKey: Key.detectionBackend)
            .flatMap(PersonDetectionBackend.init(rawValue:)) ?? Defaults.detectionBackend
        identityBackend = userDefaults.string(forKey: Key.identityBackend)
            .flatMap(IdentityMatchingBackend.init(rawValue:)) ?? Defaults.identityBackend
        trackingIdentityThreshold = Self.double(
            userDefaults,
            Key.trackingIdentityThreshold,
            Defaults.trackingIdentityThreshold
        )
        trackingAppearanceTotalThreshold = Self.double(
            userDefaults,
            Key.trackingAppearanceTotalThreshold,
            Defaults.trackingAppearanceTotalThreshold
        )
        trackingGeometryOnlyTotalThreshold = Self.double(
            userDefaults,
            Key.trackingGeometryOnlyTotalThreshold,
            Defaults.trackingGeometryOnlyTotalThreshold
        )
        maximumCenterDisplacementPercent = Self.double(
            userDefaults,
            Key.maximumCenterDisplacement,
            Defaults.maximumCenterDisplacementPercent
        )
        reacquisitionIdentityThreshold = Self.double(
            userDefaults,
            Key.reacquisitionIdentityThreshold,
            Defaults.reacquisitionIdentityThreshold
        )
        reacquisitionIdentityMargin = Self.double(
            userDefaults,
            Key.reacquisitionIdentityMargin,
            Defaults.reacquisitionIdentityMargin
        )
        reacquisitionConfirmationFrames = Self.double(
            userDefaults,
            Key.reacquisitionConfirmationFrames,
            Defaults.reacquisitionConfirmationFrames
        )
        poseMinimumJointConfidence = Self.double(userDefaults, Key.poseMinimumJointConfidence, Defaults.poseMinimumJointConfidence)
        torsoAnchorSmoothing = Self.double(userDefaults, Key.torsoAnchorSmoothing, Defaults.torsoAnchorSmoothing)
        maximumTorsoAnchorStepPercent = Self.double(userDefaults, Key.maximumTorsoAnchorStep, Defaults.maximumTorsoAnchorStepPercent)
        suspiciousScaleRatio = Self.double(userDefaults, Key.suspiciousScaleRatio, Defaults.suspiciousScaleRatio)
        rejectionScaleRatio = Self.double(userDefaults, Key.rejectionScaleRatio, Defaults.rejectionScaleRatio)

        zoomBridge.update(Self.makeZoomSnapshot(
            mode: zoomMode,
            target: hysteresisTargetPercent,
            lower: zoomInTriggerPercent,
            upper: zoomOutTriggerPercent,
            hysteresisSmoothing: hysteresisViewportSmoothing,
            continuousScale: continuousFramingScale,
            continuousTolerance: continuousTolerancePercent,
            continuousSmoothing: continuousViewportSmoothing
        ))
        trackingBridge.update(Self.makeTrackingSnapshot(
            detectionBackend: detectionBackend,
            identityBackend: identityBackend,
            trackingIdentityThreshold: trackingIdentityThreshold,
            trackingAppearanceTotalThreshold: trackingAppearanceTotalThreshold,
            trackingGeometryOnlyTotalThreshold: trackingGeometryOnlyTotalThreshold,
            maximumCenterDisplacementPercent: maximumCenterDisplacementPercent,
            reacquisitionIdentityThreshold: reacquisitionIdentityThreshold,
            reacquisitionIdentityMargin: reacquisitionIdentityMargin,
            reacquisitionConfirmationFrames: reacquisitionConfirmationFrames,
            poseMinimumJointConfidence: poseMinimumJointConfidence,
            torsoAnchorSmoothing: torsoAnchorSmoothing,
            maximumTorsoAnchorStepPercent: maximumTorsoAnchorStepPercent,
            suspiciousScaleRatio: suspiciousScaleRatio,
            rejectionScaleRatio: rejectionScaleRatio
        ))
    }

    var panTiltSnapshot: PanTiltTuningSnapshot {
        let horizontalOuter = max(0.02, min(0.40, horizontalOuterPercent / 100))
        let verticalOuter = max(0.02, min(0.40, verticalOuterPercent / 100))
        return PanTiltTuningSnapshot(
            horizontalInnerThreshold: max(0.005, min(horizontalOuter - 0.005, horizontalInnerPercent / 100)),
            verticalInnerThreshold: max(0.005, min(verticalOuter - 0.005, verticalInnerPercent / 100)),
            horizontalOuterThreshold: horizontalOuter,
            verticalOuterThreshold: verticalOuter,
            horizontalTargetOffset: max(-0.25, min(0.25, horizontalTargetOffsetPercent / 100)),
            verticalTargetOffset: max(-0.25, min(0.25, verticalTargetOffsetPercent / 100)),
            minimumPanSpeed: max(0, min(2_000, Int(minimumPanSpeed.rounded()))),
            maximumPanSpeed: max(1, min(2_000, Int(maximumPanSpeed.rounded()))),
            minimumTiltSpeed: max(0, min(2_000, Int(minimumTiltSpeed.rounded()))),
            maximumTiltSpeed: max(1, min(2_000, Int(maximumTiltSpeed.rounded()))),
            conservativeMaximumSpeed: max(1, min(2_000, Int(conservativeMaximumSpeed.rounded()))),
            minimumSpeedChange: max(1, min(500, Int(minimumSpeedChange.rounded()))),
            commandInterval: max(0.05, min(0.50, commandInterval)),
            motorCommandLeaseDuration: max(0.10, min(1.00, motorCommandLeaseDuration)),
            requiredStableObservationCount: max(1, min(8, Int(requiredStableObservationCount.rounded())))
        )
    }

    var manualAimSpeedValue: Int {
        max(25, min(800, Int(manualAimSpeed.rounded())))
    }

    func resetZoomDefaults() {
        zoomMode = Defaults.zoomMode
        hysteresisTargetPercent = Defaults.hysteresisTarget
        zoomInTriggerPercent = Defaults.zoomInTrigger
        zoomOutTriggerPercent = Defaults.zoomOutTrigger
        hysteresisViewportSmoothing = Defaults.hysteresisSmoothing
        continuousFramingScale = Defaults.continuousScale
        continuousTolerancePercent = Defaults.continuousTolerance
        continuousViewportSmoothing = Defaults.continuousSmoothing
    }

    func toggleRecordingOutputMode(_ mode: RecordingOutputMode) {
        if recordingOutputModes.contains(mode) {
            guard recordingOutputModes.count > 1 else { return }
            recordingOutputModes.remove(mode)
        } else {
            recordingOutputModes.insert(mode)
        }
        persistRecordingOutputModes()
    }

    func resetRecordingOutputModes() {
        recordingOutputModes = [Defaults.recordingOutputMode]
        persistRecordingOutputModes()
    }

    func resetPanTiltDefaults() {
        horizontalInnerPercent = Defaults.horizontalInner
        verticalInnerPercent = Defaults.verticalInner
        horizontalOuterPercent = Defaults.horizontalOuter
        verticalOuterPercent = Defaults.verticalOuter
        horizontalTargetOffsetPercent = Defaults.horizontalTargetOffset
        verticalTargetOffsetPercent = Defaults.verticalTargetOffset
        minimumPanSpeed = Defaults.minimumPanSpeed
        maximumPanSpeed = Defaults.maximumPanSpeed
        minimumTiltSpeed = Defaults.minimumTiltSpeed
        maximumTiltSpeed = Defaults.maximumTiltSpeed
        conservativeMaximumSpeed = Defaults.conservativeMaximumSpeed
        minimumSpeedChange = Defaults.minimumSpeedChange
        commandInterval = Defaults.commandInterval
        motorCommandLeaseDuration = Defaults.motorCommandLeaseDuration
        requiredStableObservationCount = Defaults.stableObservations
        manualAimSpeed = Defaults.manualAimSpeed
    }

    func resetTrackingDefaults() {
        detectionBackend = Defaults.detectionBackend
        identityBackend = Defaults.identityBackend
        trackingIdentityThreshold = Defaults.trackingIdentityThreshold
        trackingAppearanceTotalThreshold = Defaults.trackingAppearanceTotalThreshold
        trackingGeometryOnlyTotalThreshold = Defaults.trackingGeometryOnlyTotalThreshold
        maximumCenterDisplacementPercent = Defaults.maximumCenterDisplacementPercent
        reacquisitionIdentityThreshold = Defaults.reacquisitionIdentityThreshold
        reacquisitionIdentityMargin = Defaults.reacquisitionIdentityMargin
        reacquisitionConfirmationFrames = Defaults.reacquisitionConfirmationFrames
        poseMinimumJointConfidence = Defaults.poseMinimumJointConfidence
        torsoAnchorSmoothing = Defaults.torsoAnchorSmoothing
        maximumTorsoAnchorStepPercent = Defaults.maximumTorsoAnchorStepPercent
        suspiciousScaleRatio = Defaults.suspiciousScaleRatio
        rejectionScaleRatio = Defaults.rejectionScaleRatio
    }

    private func synchronizeZoom() {
        let snapshot = Self.makeZoomSnapshot(
            mode: zoomMode,
            target: hysteresisTargetPercent,
            lower: zoomInTriggerPercent,
            upper: zoomOutTriggerPercent,
            hysteresisSmoothing: hysteresisViewportSmoothing,
            continuousScale: continuousFramingScale,
            continuousTolerance: continuousTolerancePercent,
            continuousSmoothing: continuousViewportSmoothing
        )
        zoomBridge.update(snapshot)
        userDefaults.set(zoomMode.rawValue, forKey: Key.zoomMode)
        userDefaults.set(hysteresisTargetPercent, forKey: Key.hysteresisTarget)
        userDefaults.set(zoomInTriggerPercent, forKey: Key.zoomInTrigger)
        userDefaults.set(zoomOutTriggerPercent, forKey: Key.zoomOutTrigger)
        userDefaults.set(hysteresisViewportSmoothing, forKey: Key.hysteresisSmoothing)
        userDefaults.set(continuousFramingScale, forKey: Key.continuousScale)
        userDefaults.set(continuousTolerancePercent, forKey: Key.continuousTolerance)
        userDefaults.set(continuousViewportSmoothing, forKey: Key.continuousSmoothing)
    }

    private func persistRecordingOutputModes() {
        let ordered = RecordingOutputMode.allCases
            .filter(recordingOutputModes.contains)
            .map(\.rawValue)
        userDefaults.set(ordered, forKey: Key.recordingOutputModes)
    }

    private func persistPanTilt() {
        panTiltRevision &+= 1
        userDefaults.set(horizontalInnerPercent, forKey: Key.horizontalInner)
        userDefaults.set(verticalInnerPercent, forKey: Key.verticalInner)
        userDefaults.set(horizontalOuterPercent, forKey: Key.horizontalOuter)
        userDefaults.set(verticalOuterPercent, forKey: Key.verticalOuter)
        userDefaults.set(horizontalTargetOffsetPercent, forKey: Key.horizontalTargetOffset)
        userDefaults.set(verticalTargetOffsetPercent, forKey: Key.verticalTargetOffset)
        userDefaults.set(minimumPanSpeed, forKey: Key.minimumPanSpeed)
        userDefaults.set(maximumPanSpeed, forKey: Key.maximumPanSpeed)
        userDefaults.set(minimumTiltSpeed, forKey: Key.minimumTiltSpeed)
        userDefaults.set(maximumTiltSpeed, forKey: Key.maximumTiltSpeed)
        userDefaults.set(conservativeMaximumSpeed, forKey: Key.conservativeMaximumSpeed)
        userDefaults.set(minimumSpeedChange, forKey: Key.minimumSpeedChange)
        userDefaults.set(commandInterval, forKey: Key.commandInterval)
        userDefaults.set(motorCommandLeaseDuration, forKey: Key.motorCommandLeaseDuration)
        userDefaults.set(requiredStableObservationCount, forKey: Key.stableObservations)
        userDefaults.set(manualAimSpeed, forKey: Key.manualAimSpeed)
    }

    private func synchronizeTracking() {
        trackingBridge.update(Self.makeTrackingSnapshot(
            detectionBackend: detectionBackend,
            identityBackend: identityBackend,
            trackingIdentityThreshold: trackingIdentityThreshold,
            trackingAppearanceTotalThreshold: trackingAppearanceTotalThreshold,
            trackingGeometryOnlyTotalThreshold: trackingGeometryOnlyTotalThreshold,
            maximumCenterDisplacementPercent: maximumCenterDisplacementPercent,
            reacquisitionIdentityThreshold: reacquisitionIdentityThreshold,
            reacquisitionIdentityMargin: reacquisitionIdentityMargin,
            reacquisitionConfirmationFrames: reacquisitionConfirmationFrames,
            poseMinimumJointConfidence: poseMinimumJointConfidence,
            torsoAnchorSmoothing: torsoAnchorSmoothing,
            maximumTorsoAnchorStepPercent: maximumTorsoAnchorStepPercent,
            suspiciousScaleRatio: suspiciousScaleRatio,
            rejectionScaleRatio: rejectionScaleRatio
        ))
        userDefaults.set(detectionBackend.rawValue, forKey: Key.detectionBackend)
        userDefaults.set(identityBackend.rawValue, forKey: Key.identityBackend)
        userDefaults.set(trackingIdentityThreshold, forKey: Key.trackingIdentityThreshold)
        userDefaults.set(
            trackingAppearanceTotalThreshold,
            forKey: Key.trackingAppearanceTotalThreshold
        )
        userDefaults.set(
            trackingGeometryOnlyTotalThreshold,
            forKey: Key.trackingGeometryOnlyTotalThreshold
        )
        userDefaults.set(
            maximumCenterDisplacementPercent,
            forKey: Key.maximumCenterDisplacement
        )
        userDefaults.set(
            reacquisitionIdentityThreshold,
            forKey: Key.reacquisitionIdentityThreshold
        )
        userDefaults.set(reacquisitionIdentityMargin, forKey: Key.reacquisitionIdentityMargin)
        userDefaults.set(
            reacquisitionConfirmationFrames,
            forKey: Key.reacquisitionConfirmationFrames
        )
        userDefaults.set(poseMinimumJointConfidence, forKey: Key.poseMinimumJointConfidence)
        userDefaults.set(torsoAnchorSmoothing, forKey: Key.torsoAnchorSmoothing)
        userDefaults.set(maximumTorsoAnchorStepPercent, forKey: Key.maximumTorsoAnchorStep)
        userDefaults.set(suspiciousScaleRatio, forKey: Key.suspiciousScaleRatio)
        userDefaults.set(rejectionScaleRatio, forKey: Key.rejectionScaleRatio)
    }

    private nonisolated static func makeZoomSnapshot(
        mode: ZoomControlMode,
        target: Double,
        lower: Double,
        upper: Double,
        hysteresisSmoothing: Double,
        continuousScale: Double,
        continuousTolerance: Double,
        continuousSmoothing: Double
    ) -> ZoomTuningSnapshot {
        let targetFraction = max(0.10, min(0.90, target / 100))
        return ZoomTuningSnapshot(
            mode: mode,
            hysteresisTargetFraction: targetFraction,
            zoomInTriggerFraction: max(0.05, min(targetFraction - 0.01, lower / 100)),
            zoomOutTriggerFraction: min(0.95, max(targetFraction + 0.01, upper / 100)),
            hysteresisViewportSmoothing: max(0.01, min(1, hysteresisSmoothing)),
            continuousFramingScale: max(1.05, min(5, continuousScale)),
            continuousToleranceFraction: max(0, min(0.20, continuousTolerance / 100)),
            continuousViewportSmoothing: max(0.01, min(1, continuousSmoothing))
        )
    }

    private nonisolated static func makeTrackingSnapshot(
        detectionBackend: PersonDetectionBackend,
        identityBackend: IdentityMatchingBackend,
        trackingIdentityThreshold: Double,
        trackingAppearanceTotalThreshold: Double,
        trackingGeometryOnlyTotalThreshold: Double,
        maximumCenterDisplacementPercent: Double,
        reacquisitionIdentityThreshold: Double,
        reacquisitionIdentityMargin: Double,
        reacquisitionConfirmationFrames: Double,
        poseMinimumJointConfidence: Double,
        torsoAnchorSmoothing: Double,
        maximumTorsoAnchorStepPercent: Double,
        suspiciousScaleRatio: Double,
        rejectionScaleRatio: Double
    ) -> TrackingTuningSnapshot {
        TrackingTuningSnapshot(
            detectionBackend: detectionBackend,
            identityBackend: identityBackend,
            trackingIdentityThreshold: max(0, min(1, trackingIdentityThreshold)),
            trackingAppearanceTotalThreshold: max(
                0,
                min(1, trackingAppearanceTotalThreshold)
            ),
            trackingGeometryOnlyTotalThreshold: max(
                0,
                min(1, trackingGeometryOnlyTotalThreshold)
            ),
            maximumCenterDisplacement: max(
                0.01,
                min(1, maximumCenterDisplacementPercent / 100)
            ),
            reacquisitionIdentityThreshold: max(
                0,
                min(1, reacquisitionIdentityThreshold)
            ),
            reacquisitionIdentityMargin: max(0, min(1, reacquisitionIdentityMargin)),
            reacquisitionConfirmationFrames: max(
                1,
                min(10, Int(reacquisitionConfirmationFrames.rounded()))
            ),
            poseMinimumJointConfidence: Float(max(0.05, min(0.90, poseMinimumJointConfidence))),
            torsoAnchorSmoothing: max(0.01, min(1, torsoAnchorSmoothing)),
            maximumTorsoAnchorStep: max(0.01, min(0.50, maximumTorsoAnchorStepPercent / 100)),
            suspiciousScaleRatio: max(1.25, min(8, suspiciousScaleRatio)),
            rejectionScaleRatio: max(
                max(1.5, suspiciousScaleRatio + 0.1),
                min(10, rejectionScaleRatio)
            )
        )
    }

    private nonisolated static func double(
        _ defaults: UserDefaults,
        _ key: String,
        _ fallback: Double
    ) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    private static func applyCurrentDefaultsIfNeeded(to userDefaults: UserDefaults) {
        let appliedRevision = userDefaults.integer(forKey: Key.defaultsRevision)

        if appliedRevision < 1 {
            userDefaults.set(Defaults.recordingOutputMode.rawValue, forKey: Key.recordingOutputMode)
            userDefaults.set(Defaults.horizontalInner, forKey: Key.horizontalInner)
            userDefaults.set(Defaults.verticalInner, forKey: Key.verticalInner)
            userDefaults.set(Defaults.horizontalOuter, forKey: Key.horizontalOuter)
            userDefaults.set(Defaults.verticalOuter, forKey: Key.verticalOuter)
            userDefaults.set(Defaults.verticalTargetOffset, forKey: Key.verticalTargetOffset)
        }

        if appliedRevision < 2 {
            userDefaults.set(Defaults.minimumPanSpeed, forKey: Key.minimumPanSpeed)
            userDefaults.set(Defaults.maximumPanSpeed, forKey: Key.maximumPanSpeed)
            userDefaults.set(Defaults.minimumTiltSpeed, forKey: Key.minimumTiltSpeed)
            userDefaults.set(Defaults.maximumTiltSpeed, forKey: Key.maximumTiltSpeed)
        }

        if appliedRevision < 3 {
            // Install the field-tested profile once. This intentionally updates
            // existing development installs; later user adjustments persist.
            userDefaults.set(Defaults.zoomMode.rawValue, forKey: Key.zoomMode)
            userDefaults.set(
                [Defaults.recordingOutputMode.rawValue],
                forKey: Key.recordingOutputModes
            )
            userDefaults.set(
                Defaults.recordingOutputMode.rawValue,
                forKey: Key.recordingOutputMode
            )
            userDefaults.set(Defaults.hysteresisTarget, forKey: Key.hysteresisTarget)
            userDefaults.set(Defaults.zoomInTrigger, forKey: Key.zoomInTrigger)
            userDefaults.set(Defaults.zoomOutTrigger, forKey: Key.zoomOutTrigger)
            userDefaults.set(Defaults.hysteresisSmoothing, forKey: Key.hysteresisSmoothing)
            userDefaults.set(Defaults.continuousScale, forKey: Key.continuousScale)
            userDefaults.set(Defaults.continuousTolerance, forKey: Key.continuousTolerance)
            userDefaults.set(Defaults.continuousSmoothing, forKey: Key.continuousSmoothing)

            userDefaults.set(Defaults.horizontalInner, forKey: Key.horizontalInner)
            userDefaults.set(Defaults.verticalInner, forKey: Key.verticalInner)
            userDefaults.set(Defaults.horizontalOuter, forKey: Key.horizontalOuter)
            userDefaults.set(Defaults.verticalOuter, forKey: Key.verticalOuter)
            userDefaults.set(Defaults.horizontalTargetOffset, forKey: Key.horizontalTargetOffset)
            userDefaults.set(Defaults.verticalTargetOffset, forKey: Key.verticalTargetOffset)
            userDefaults.set(Defaults.minimumPanSpeed, forKey: Key.minimumPanSpeed)
            userDefaults.set(Defaults.maximumPanSpeed, forKey: Key.maximumPanSpeed)
            userDefaults.set(Defaults.minimumTiltSpeed, forKey: Key.minimumTiltSpeed)
            userDefaults.set(Defaults.maximumTiltSpeed, forKey: Key.maximumTiltSpeed)
            userDefaults.set(Defaults.conservativeMaximumSpeed, forKey: Key.conservativeMaximumSpeed)
            userDefaults.set(Defaults.minimumSpeedChange, forKey: Key.minimumSpeedChange)
            userDefaults.set(Defaults.commandInterval, forKey: Key.commandInterval)
            userDefaults.set(Defaults.motorCommandLeaseDuration, forKey: Key.motorCommandLeaseDuration)
            userDefaults.set(Defaults.stableObservations, forKey: Key.stableObservations)
            userDefaults.set(Defaults.manualAimSpeed, forKey: Key.manualAimSpeed)

            userDefaults.set(Defaults.detectionBackend.rawValue, forKey: Key.detectionBackend)
            userDefaults.set(Defaults.identityBackend.rawValue, forKey: Key.identityBackend)
            userDefaults.set(Defaults.trackingIdentityThreshold, forKey: Key.trackingIdentityThreshold)
            userDefaults.set(
                Defaults.trackingAppearanceTotalThreshold,
                forKey: Key.trackingAppearanceTotalThreshold
            )
            userDefaults.set(
                Defaults.trackingGeometryOnlyTotalThreshold,
                forKey: Key.trackingGeometryOnlyTotalThreshold
            )
            userDefaults.set(
                Defaults.maximumCenterDisplacementPercent,
                forKey: Key.maximumCenterDisplacement
            )
            userDefaults.set(
                Defaults.reacquisitionIdentityThreshold,
                forKey: Key.reacquisitionIdentityThreshold
            )
            userDefaults.set(
                Defaults.reacquisitionIdentityMargin,
                forKey: Key.reacquisitionIdentityMargin
            )
            userDefaults.set(
                Defaults.reacquisitionConfirmationFrames,
                forKey: Key.reacquisitionConfirmationFrames
            )
            userDefaults.set(Defaults.poseMinimumJointConfidence, forKey: Key.poseMinimumJointConfidence)
            userDefaults.set(Defaults.torsoAnchorSmoothing, forKey: Key.torsoAnchorSmoothing)
            userDefaults.set(Defaults.maximumTorsoAnchorStepPercent, forKey: Key.maximumTorsoAnchorStep)
            userDefaults.set(Defaults.suspiciousScaleRatio, forKey: Key.suspiciousScaleRatio)
            userDefaults.set(Defaults.rejectionScaleRatio, forKey: Key.rejectionScaleRatio)
        }

        if appliedRevision < Defaults.revision {
            userDefaults.set(Defaults.revision, forKey: Key.defaultsRevision)
        }
    }
}
