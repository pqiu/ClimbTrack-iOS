import Combine
import CoreGraphics
import Foundation

struct ManualMotorControlConfiguration: Sendable {
    let maximumPanSpeed: Int
    let maximumTiltSpeed: Int
    let deadZoneRadius: Double
    let commandInterval: TimeInterval
    let minimumSpeedChange: Int

    nonisolated init(
        maximumPanSpeed: Int = 2_000,
        maximumTiltSpeed: Int = 2_000,
        deadZoneRadius: Double = 0.12,
        commandInterval: TimeInterval = 0.08,
        minimumSpeedChange: Int = 10
    ) {
        self.maximumPanSpeed = maximumPanSpeed
        self.maximumTiltSpeed = maximumTiltSpeed
        self.deadZoneRadius = deadZoneRadius
        self.commandInterval = commandInterval
        self.minimumSpeedChange = minimumSpeedChange
    }
}

@MainActor
final class ManualMotorControlModel: ObservableObject {
    @Published private(set) var joystickPosition: CGSize = .zero
    @Published private(set) var panSpeed = 0
    @Published private(set) var tiltSpeed = 0

    let configuration: ManualMotorControlConfiguration

    private weak var bleManager: BLEManager?
    private let ownership: MotorControlOwnership
    private var commandLoop: Task<Void, Never>?
    private var delayedDisable: Task<Void, Never>?
    private var lastSentPan = 0
    private var lastSentTilt = 0
    private var stopWasLastCommand = true

    init(
        bleManager: BLEManager,
        ownership: MotorControlOwnership,
        configuration: ManualMotorControlConfiguration = .init()
    ) {
        self.bleManager = bleManager
        self.ownership = ownership
        self.configuration = configuration
    }

    func beginManualControl() {
        claimManualControl()
    }

    func endManualControl() {
        stopForSafety()
        ownership.endManualControl()
    }

    func updateJoystick(horizontal: Double, vertical: Double) {
        claimManualControl()
        cancelDelayedDisable()
        let limited = limitToUnitCircle(horizontal: horizontal, vertical: vertical)
        joystickPosition = CGSize(width: limited.x, height: limited.y)

        let distance = hypot(limited.x, limited.y)
        guard distance > configuration.deadZoneRadius else {
            panSpeed = 0
            tiltSpeed = 0
            stopCommandLoop()

            if !stopWasLastCommand {
                sendStopIfPossible()
            }
            return
        }

        // Remove the dead-zone portion, then remap the remaining radial travel
        // back onto 0...1 so full joystick deflection still reaches max speed.
        let adjustedMagnitude = min(
            1,
            (distance - configuration.deadZoneRadius) / (1 - configuration.deadZoneRadius)
        )
        let unitX = limited.x / distance
        let unitY = limited.y / distance

        panSpeed = Int(
            (unitX * adjustedMagnitude * Double(configuration.maximumPanSpeed)).rounded()
        )
        tiltSpeed = Int(
            (-unitY * adjustedMagnitude * Double(configuration.maximumTiltSpeed)).rounded()
        )

        if commandLoop == nil {
            sendLatestMoveIfNeeded(force: true)
            startCommandLoop()
        }
    }

    func releaseJoystick() {
        stopMotion(resetJoystick: true, forceStop: false)
    }

    func sendEnable() {
        claimManualControl()
        cancelDelayedDisable()
        bleManager?.send(.enable)
    }

    func sendDisable() {
        claimManualControl()
        delayedDisable?.cancel()
        stopMotion(resetJoystick: true, forceStop: true)

        // STOP must precede DISABLE. Both use write-with-response; a short
        // separation also mirrors the established command update interval.
        let delay = UInt64(configuration.commandInterval * 1_000_000_000)
        delayedDisable = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.bleManager?.send(.disable)
        }
    }

    func sendStop() {
        claimManualControl()
        cancelDelayedDisable()
        stopMotion(resetJoystick: true, forceStop: true)
    }

    func sendTestPan() {
        claimManualControl()
        cancelDelayedDisable()
        bleManager?.send(.testPan)
    }

    func sendTestTilt() {
        claimManualControl()
        cancelDelayedDisable()
        bleManager?.send(.testTilt)
    }

    func stopForSafety() {
        delayedDisable?.cancel()
        delayedDisable = nil
        stopMotion(resetJoystick: true, forceStop: true)
    }

    func connectionDidBecomeUnavailable() {
        delayedDisable?.cancel()
        delayedDisable = nil
        stopCommandLoop()
        resetDisplayedMovement()
        // The transport refuses this after loss, but making the attempt keeps
        // the safety behavior correct for transitions where writing is possible.
        sendStopIfPossible()
    }

    private func startCommandLoop() {
        guard commandLoop == nil else { return }

        let interval = UInt64(configuration.commandInterval * 1_000_000_000)
        commandLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                self?.sendLatestMoveIfNeeded(force: false)
            }
        }
    }

    private func stopCommandLoop() {
        commandLoop?.cancel()
        commandLoop = nil
    }

    private func sendLatestMoveIfNeeded(force: Bool) {
        guard ownership.owner == .manual,
              panSpeed != 0 || tiltSpeed != 0 else {
            stopCommandLoop()
            return
        }

        let changedEnough = abs(panSpeed - lastSentPan) >= configuration.minimumSpeedChange
            || abs(tiltSpeed - lastSentTilt) >= configuration.minimumSpeedChange
        guard force || changedEnough else { return }

        if bleManager?.send(.move(panSpeed: panSpeed, tiltSpeed: tiltSpeed)) == true {
            lastSentPan = panSpeed
            lastSentTilt = tiltSpeed
            stopWasLastCommand = false
        }
    }

    private func stopMotion(resetJoystick: Bool, forceStop: Bool) {
        stopCommandLoop()

        if resetJoystick {
            resetDisplayedMovement()
        } else {
            panSpeed = 0
            tiltSpeed = 0
        }

        if forceStop || !stopWasLastCommand {
            sendStopIfPossible()
        }
    }

    private func sendStopIfPossible() {
        if bleManager?.send(.stop) == true {
            stopWasLastCommand = true
            lastSentPan = 0
            lastSentTilt = 0
        }
    }

    private func resetDisplayedMovement() {
        joystickPosition = .zero
        panSpeed = 0
        tiltSpeed = 0
    }

    private func cancelDelayedDisable() {
        delayedDisable?.cancel()
        delayedDisable = nil
    }

    private func claimManualControl() {
        guard ownership.owner != .manual else { return }
        // Stop any automatic velocity before the first manual command. This is
        // synchronous with the user's action and does not rely on a SwiftUI
        // ownership-change callback arriving later.
        _ = bleManager?.send(.stop)
        stopWasLastCommand = true
        lastSentPan = 0
        lastSentTilt = 0
        ownership.beginManualControl()
    }

    private func limitToUnitCircle(horizontal: Double, vertical: Double) -> (x: Double, y: Double) {
        let distance = hypot(horizontal, vertical)
        guard distance > 1 else {
            return (horizontal, vertical)
        }

        return (horizontal / distance, vertical / distance)
    }
}
