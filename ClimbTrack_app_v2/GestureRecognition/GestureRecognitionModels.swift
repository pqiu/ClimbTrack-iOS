import CoreGraphics
import Foundation

enum GestureCommand: Equatable, Sendable {
    case trackMe(detectionID: UUID)
    case stop
}

struct GestureCommandEvent: Equatable, Sendable {
    let id = UUID()
    let command: GestureCommand
}

enum GestureKind: String, Sendable {
    case trackMe = "TRACK ME"
    case stop = "STOP"
}

struct GestureStatus: Equatable, Sendable {
    let kind: GestureKind
    let detectionID: UUID?
    let confidence: Float
    let bodyConfidence: Float
    let leftHandConfidence: Float?
    let rightHandConfidence: Float?
    let holdProgress: CGFloat

    nonisolated var displayText: String {
        let overall = Int(confidence * 100)
        let body = Int(bodyConfidence * 100)
        let progress = Int(holdProgress * 100)
        guard kind == .trackMe else {
            return "STOP CANDIDATE · \(overall)% · HOLD \(progress)%"
        }
        let left = leftHandConfidence.map { "\(Int($0 * 100))" } ?? "—"
        let right = rightHandConfidence.map { "\(Int($0 * 100))" } ?? "—"
        return "TRACK ME · \(overall)% · B \(body) L \(left) R \(right) · HOLD \(progress)%"
    }
}

nonisolated enum GestureEvaluationMode: Equatable, Sendable {
    case unlocked
    case lockedVisible(detectionID: UUID, matchConfidence: Float)
    case lockedUnavailable
}

nonisolated struct GestureAnalysisResult: Sendable {
    let status: GestureStatus?
    let command: GestureCommand?
}
