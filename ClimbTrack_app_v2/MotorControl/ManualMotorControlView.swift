import SwiftUI

struct ManualMotorControlView: View {
    @ObservedObject private var bleManager: BLEManager
    @StateObject private var model: ManualMotorControlModel
    @Environment(\.scenePhase) private var scenePhase

    init(bleManager: BLEManager, ownership: MotorControlOwnership) {
        self.bleManager = bleManager
        _model = StateObject(
            wrappedValue: ManualMotorControlModel(
                bleManager: bleManager,
                ownership: ownership
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                manualControlNotice
                connectionStatus
                commandValues
                joystick
                primaryControls
                axisTestControls
            }
            .padding()
        }
        .navigationTitle("Manual Motor Control")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.beginManualControl()
        }
        .onDisappear {
            model.endManualControl()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                model.stopForSafety()
            }
        }
        .onChange(of: bleManager.state) { oldState, newState in
            if oldState == .connected, newState != .connected {
                model.connectionDidBecomeUnavailable()
            }
        }
    }

    private var manualControlNotice: some View {
        Label("Manual control overrides automatic tracking", systemImage: "wrench.and.screwdriver.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionStatus: some View {
        HStack {
            Circle()
                .fill(bleManager.canSendCommands ? .green : .red)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(bleManager.canSendCommands ? "Controller connected" : "Controls unavailable")
                    .font(.subheadline.weight(.semibold))

                if !bleManager.canSendCommands {
                    Text(unavailableReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(12)
        .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var commandValues: some View {
        HStack(spacing: 12) {
            speedValue(title: "Pan", value: model.panSpeed)
            speedValue(title: "Tilt", value: model.tiltSpeed)
        }
    }

    private func speedValue(title: String, value: Int) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.monospacedDigit().weight(.semibold))
            Text("steps/s")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private var joystick: some View {
        ManualJoystickView(model: model)
            .disabled(!bleManager.canSendCommands)
            .opacity(bleManager.canSendCommands ? 1 : 0.4)
            .accessibilityLabel("Pan and tilt joystick")
    }

    private var primaryControls: some View {
        HStack(spacing: 12) {
            Button("Enable") {
                model.sendEnable()
            }
            .buttonStyle(.borderedProminent)

            Button("Stop", role: .destructive) {
                model.sendStop()
            }
            .buttonStyle(.borderedProminent)

            Button("Disable") {
                model.sendDisable()
            }
            .buttonStyle(.bordered)
        }
        .disabled(!bleManager.canSendCommands)
    }

    private var axisTestControls: some View {
        HStack(spacing: 12) {
            Button("Test Pan") {
                model.sendTestPan()
            }
            .buttonStyle(.bordered)

            Button("Test Tilt") {
                model.sendTestTilt()
            }
            .buttonStyle(.bordered)
        }
        .disabled(!bleManager.canSendCommands)
    }

    private var unavailableReason: String {
        switch bleManager.state {
        case .neverSelected:
            return "Select and connect to a ClimbTrack device first."
        case .idle:
            return "The preferred device is disconnected."
        case .scanning:
            return "Scanning for a ClimbTrack device."
        case .connecting:
            return "Waiting for the command characteristic."
        case .connected:
            return "The command characteristic is unavailable."
        case .reconnecting:
            return "Waiting to reconnect to the preferred device."
        case .disconnecting:
            return "The device is disconnecting."
        case .unavailable(let message), .failed(let message):
            return message
        }
    }
}

private struct ManualJoystickView: View {
    @ObservedObject var model: ManualMotorControlModel

    private let size: CGFloat = 240
    private let knobSize: CGFloat = 70

    var body: some View {
        let travel = (size - knobSize) / 2

        ZStack {
            Circle()
                .fill(.secondary.opacity(0.16))

            Circle()
                .stroke(.secondary.opacity(0.45), lineWidth: 2)

            Circle()
                .stroke(.orange.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5]))
                .frame(
                    width: size * model.configuration.deadZoneRadius,
                    height: size * model.configuration.deadZoneRadius
                )

            Circle()
                .fill(.blue)
                .frame(width: knobSize, height: knobSize)
                .shadow(radius: 3)
                .offset(
                    x: model.joystickPosition.width * travel,
                    y: model.joystickPosition.height * travel
                )
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    model.updateJoystick(
                        horizontal: value.translation.width / travel,
                        vertical: value.translation.height / travel
                    )
                }
                .onEnded { _ in
                    model.releaseJoystick()
                }
        )
    }
}
