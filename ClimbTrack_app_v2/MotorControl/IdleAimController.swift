import AVFoundation
import Combine
import CoreGraphics
import Foundation

enum IdleAimDirection: Hashable {
    case left
    case right
    case up
    case down
}

/// Owns low-speed manual aiming before a target is selected. Commands are
/// event-driven because the firmware continues MOVE until another command.
@MainActor
final class IdleAimController: ObservableObject {
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var isEnablingMotors = false
    @Published private(set) var motorsEnabled = false
    @Published private(set) var pressedDirections: Set<IdleAimDirection> = []

    let framingBridge: IdleFramingBridge

    private weak var bleManager: BLEManager?
    private let ownership: MotorControlOwnership
    private let tuningStore: DeveloperTuningStore
    private var cameraPosition: AVCaptureDevice.Position = .back
    private var disableTask: Task<Void, Never>?

    init(
        bleManager: BLEManager,
        ownership: MotorControlOwnership,
        tuningStore: DeveloperTuningStore,
        framingBridge: IdleFramingBridge
    ) {
        self.bleManager = bleManager
        self.ownership = ownership
        self.tuningStore = tuningStore
        self.framingBridge = framingBridge
    }

    var isMotorMoving: Bool {
        motorsEnabled && !pressedDirections.isEmpty
    }

    func setZoomFactor(_ value: CGFloat) {
        zoomFactor = min(IdleFramingBridge.maximumZoom, max(1, value))
        framingBridge.updateZoomFactor(zoomFactor)
    }

    func resetZoom() {
        setZoomFactor(1)
    }

    func updateCameraPosition(_ position: AVCaptureDevice.Position) {
        cameraPosition = position
    }

    func press(_ direction: IdleAimDirection) {
        guard bleManager?.canSendCommands == true else { return }
        disableTask?.cancel()
        disableTask = nil
        pressedDirections.insert(direction)

        if ownership.owner != .manual {
            _ = bleManager?.send(.stop)
            ownership.beginManualControl()
            motorsEnabled = false
            isEnablingMotors = bleManager?.send(.enable) == true
        }

        if motorsEnabled {
            sendCurrentVelocity()
        }
    }

    func release(_ direction: IdleAimDirection) {
        guard pressedDirections.remove(direction) != nil else { return }
        guard ownership.owner == .manual else { return }
        sendCurrentVelocity()
    }

    /// Target selection stops manual movement but leaves the controller enabled
    /// for the immediate automatic-ownership handoff.
    func prepareForAutomaticHandoff() {
        disableTask?.cancel()
        disableTask = nil
        stopMotion()
        ownership.endManualControl()
    }

    func deactivate(disableMotors: Bool) {
        disableTask?.cancel()
        disableTask = nil
        stopMotion()
        ownership.endManualControl()
        guard disableMotors, bleManager?.canSendCommands == true else { return }

        disableTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  let self,
                  self.ownership.owner == .none else { return }
            _ = self.bleManager?.send(.disable)
        }
    }

    func handleDeviceStatus(_ status: String?) {
        guard let status else { return }
        let normalized = status.uppercased()
        if normalized.contains("OK ENABLE") {
            guard ownership.owner == .manual else { return }
            isEnablingMotors = false
            motorsEnabled = true
            sendCurrentVelocity()
        } else if normalized.contains("OK DISABLE") {
            isEnablingMotors = false
            motorsEnabled = false
        } else if normalized.hasPrefix("ERR") || normalized.contains("ERROR") {
            isEnablingMotors = false
            motorsEnabled = false
            pressedDirections.removeAll()
        }
    }

    func handleBLEStateChange(_ state: BLEConnectionState) {
        guard state != .connected else { return }
        disableTask?.cancel()
        disableTask = nil
        pressedDirections.removeAll()
        isEnablingMotors = false
        motorsEnabled = false
        ownership.endManualControl()
    }

    func tuningDidChange() {
        guard ownership.owner == .manual, motorsEnabled, !pressedDirections.isEmpty else {
            return
        }
        sendCurrentVelocity()
    }

    private func sendCurrentVelocity() {
        guard ownership.owner == .manual, motorsEnabled else { return }
        let mapping = CameraMotorDirectionMapping.mapping(for: cameraPosition)
        let speed = tuningStore.manualAimSpeedValue
        let horizontal = (pressedDirections.contains(.right) ? 1 : 0)
            - (pressedDirections.contains(.left) ? 1 : 0)
        let vertical = (pressedDirections.contains(.up) ? 1 : 0)
            - (pressedDirections.contains(.down) ? 1 : 0)
        let pan = horizontal * speed * mapping.panSign
        let tilt = vertical * speed * mapping.tiltSign

        if pan == 0, tilt == 0 {
            _ = bleManager?.send(.stop)
        } else {
            _ = bleManager?.send(.move(panSpeed: pan, tiltSpeed: tilt))
        }
    }

    private func stopMotion() {
        pressedDirections.removeAll()
        isEnablingMotors = false
        motorsEnabled = false
        if ownership.owner == .manual {
            _ = bleManager?.send(.stop)
        }
    }
}
