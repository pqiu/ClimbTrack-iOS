import Combine
import Foundation

enum MotorControlOwner: Equatable {
    case none
    case automaticTracking
    case manual

    var displayName: String {
        switch self {
        case .none: "NONE"
        case .automaticTracking: "AUTOMATIC"
        case .manual: "MANUAL"
        }
    }
}

/// A single arbitration point prevents automatic and manual MOVE commands from
/// competing for the same two motors.
@MainActor
final class MotorControlOwnership: ObservableObject {
    @Published private(set) var owner: MotorControlOwner = .none

    @discardableResult
    func claimAutomaticControl() -> Bool {
        guard owner != .manual else { return false }
        owner = .automaticTracking
        return true
    }

    func beginManualControl() {
        owner = .manual
    }

    func endManualControl() {
        guard owner == .manual else { return }
        owner = .none
    }

    func releaseAutomaticControl() {
        guard owner == .automaticTracking else { return }
        owner = .none
    }

    func clear() {
        owner = .none
    }
}
