import SwiftUI

struct IdleAimControls: View {
    @ObservedObject var controller: IdleAimController
    let canMoveMotors: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 10) {
            Button {
                isExpanded.toggle()
            } label: {
                Label(
                    isExpanded ? "Close Aim" : String(format: "Aim · %.1f×", controller.zoomFactor),
                    systemImage: "scope"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.68), in: Capsule())
            }
            .buttonStyle(.plain)

            if isExpanded {
                HStack(spacing: 18) {
                    directionPad
                    zoomControl
                }
                .padding(12)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    private var directionPad: some View {
        Grid(horizontalSpacing: 5, verticalSpacing: 5) {
            GridRow {
                Color.clear.frame(width: 42, height: 42)
                directionButton(.up, systemImage: "chevron.up", label: "Tilt up")
                Color.clear.frame(width: 42, height: 42)
            }
            GridRow {
                directionButton(.left, systemImage: "chevron.left", label: "Pan left")
                Circle()
                    .fill(canMoveMotors ? .green.opacity(0.65) : .red.opacity(0.65))
                    .frame(width: 12, height: 12)
                    .frame(width: 42, height: 42)
                    .accessibilityHidden(true)
                directionButton(.right, systemImage: "chevron.right", label: "Pan right")
            }
            GridRow {
                Color.clear.frame(width: 42, height: 42)
                directionButton(.down, systemImage: "chevron.down", label: "Tilt down")
                Color.clear.frame(width: 42, height: 42)
            }
        }
    }

    private func directionButton(
        _ direction: IdleAimDirection,
        systemImage: String,
        label: String
    ) -> some View {
        MomentaryDirectionButton(
            systemImage: systemImage,
            accessibilityLabel: label,
            isEnabled: canMoveMotors,
            onPress: { controller.press(direction) },
            onRelease: { controller.release(direction) }
        )
    }

    private var zoomControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Zoom", systemImage: "magnifyingglass")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(String(format: "%.1f×", controller.zoomFactor))
                    .font(.callout.monospacedDigit().weight(.bold))
            }
            .foregroundStyle(.white)

            Slider(value: zoomSliderPosition, in: 0...1)
                .tint(.yellow)
                .accessibilityLabel("Idle zoom")
                .accessibilityValue(String(format: "%.1f times", controller.zoomFactor))

            HStack {
                Text("1×")
                Spacer()
                Text("4×")
                Spacer()
                Text("15×")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.72))

            Button("Reset to 1×") {
                controller.resetZoom()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(.white)

            if !canMoveMotors {
                Text("Connect the controller to use pan and tilt.")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            } else if controller.isEnablingMotors {
                Text("Enabling motors…")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
        }
        .frame(maxWidth: 175)
    }

    /// Logarithmic mapping gives most of the travel to useful low zoom while
    /// retaining the existing 15× ceiling.
    private var zoomSliderPosition: Binding<Double> {
        Binding(
            get: {
                log(Double(controller.zoomFactor))
                    / log(Double(IdleFramingBridge.maximumZoom))
            },
            set: { position in
                controller.setZoomFactor(CGFloat(pow(
                    Double(IdleFramingBridge.maximumZoom),
                    position
                )))
            }
        )
    }
}

private struct MomentaryDirectionButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let isEnabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(
                isPressed ? Color.blue : Color.white.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.38)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, !isPressed else { return }
                        isPressed = true
                        onPress()
                    }
                    .onEnded { _ in
                        releaseIfNeeded()
                    }
            )
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { releaseIfNeeded() }
            }
            .onDisappear {
                releaseIfNeeded()
            }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }

    private func releaseIfNeeded() {
        guard isPressed else { return }
        isPressed = false
        onRelease()
    }
}
