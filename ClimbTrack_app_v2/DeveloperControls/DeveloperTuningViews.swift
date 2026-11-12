import Foundation
import SwiftUI

struct RecordingOutputTuningView: View {
    @ObservedObject var tuning: DeveloperTuningStore

    var body: some View {
        Form {
            Section("Saved Video Modes") {
                ForEach(RecordingOutputMode.allCases, id: \.self) { mode in
                    Button {
                        tuning.toggleRecordingOutputMode(mode)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.displayName)
                                    .foregroundStyle(.primary)
                                Text(mode.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if tuning.recordingOutputModes.contains(mode) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Timing Clarification") {
                Text("Every selected format is written while recording, so Stop only finalizes and saves the files. Modes 1 and 2 are written at approximately 8 Hz. Modes 3 and 4 retain camera-frequency frames, and Mode 4 interpolates its crop on every frame. At least one mode must remain selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Restore Default Recording Modes") {
                    tuning.resetRecordingOutputModes()
                }
            } footer: {
                Text("Mode 4 is the only default selection. Multiple outputs increase processing, battery use, heat, and temporary storage while recording.")
            }
        }
        .navigationTitle("Recording Output")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ZoomTuningView: View {
    @ObservedObject var tuning: DeveloperTuningStore

    var body: some View {
        Form {
            Section("Control Mode") {
                Picker("Zoom control", selection: $tuning.zoomMode) {
                    ForEach(ZoomControlMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("Changes apply live to the next processed tracking frame and persist between app launches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hysteresis Control") {
                tuningSlider(
                    "Zoom-in trigger",
                    value: Binding(
                        get: { tuning.zoomInTriggerPercent },
                        set: { tuning.zoomInTriggerPercent = min($0, tuning.hysteresisTargetPercent - 1) }
                    ),
                    range: 5...75,
                    step: 1,
                    format: percent
                )
                tuningSlider(
                    "Target size",
                    value: Binding(
                        get: { tuning.hysteresisTargetPercent },
                        set: { newValue in
                            tuning.hysteresisTargetPercent = newValue
                            tuning.zoomInTriggerPercent = min(tuning.zoomInTriggerPercent, newValue - 1)
                            tuning.zoomOutTriggerPercent = max(tuning.zoomOutTriggerPercent, newValue + 1)
                        }
                    ),
                    range: 20...80,
                    step: 1,
                    format: percent
                )
                tuningSlider(
                    "Zoom-out trigger",
                    value: Binding(
                        get: { tuning.zoomOutTriggerPercent },
                        set: { tuning.zoomOutTriggerPercent = max($0, tuning.hysteresisTargetPercent + 1) }
                    ),
                    range: 25...95,
                    step: 1,
                    format: percent
                )
                tuningSlider(
                    "Viewport smoothing",
                    value: $tuning.hysteresisViewportSmoothing,
                    range: 0.02...0.50,
                    step: 0.01,
                    format: decimal2
                )

                Text("Zoom starts outside the trigger range, aims for the target size, and then holds until a trigger is crossed again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Continuous Control") {
                tuningSlider(
                    "Framing scale",
                    value: $tuning.continuousFramingScale,
                    range: 1.10...3.00,
                    step: 0.05,
                    format: decimal2
                )
                LabeledContent(
                    "Implied target size",
                    value: percent(100 / max(tuning.continuousFramingScale, 0.01))
                )
                tuningSlider(
                    "Tolerance",
                    value: $tuning.continuousTolerancePercent,
                    range: 0...10,
                    step: 0.5,
                    format: percent1
                )
                tuningSlider(
                    "Viewport smoothing",
                    value: $tuning.continuousViewportSmoothing,
                    range: 0.02...0.50,
                    step: 0.01,
                    format: decimal2
                )

                Text("The desired crop is the target’s larger dimension multiplied by the framing scale. At 1.65, the target occupies about 60.6%. Smoothing has the same meaning as in hysteresis mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Restore Zoom Defaults") {
                    tuning.resetZoomDefaults()
                }
            } footer: {
                Text("This milestone keeps the existing Vision-driven crop cadence; it does not add camera-frame-rate interpolation.")
            }
        }
        .navigationTitle("Zoom Tuning")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private func percent1(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func decimal2(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct TrackingTuningView: View {
    @ObservedObject var tuning: DeveloperTuningStore

    var body: some View {
        Form {
            Section("Model Backends") {
                Picker("Person detection", selection: $tuning.detectionBackend) {
                    ForEach(PersonDetectionBackend.selectableCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }

                LabeledContent("Identity matching", value: "Apple Feature Print")

                Text("The three YOLOX models provide bounding boxes and use the same tracking pipeline as Apple Vision. YOLOX-Nano is smallest and fastest, YOLOX-Tiny balances speed and accuracy, and YOLOX-S is the largest and most accurate YOLOX option. Apple Vision + Skeleton keeps the Apple person boxes and adds pose-assisted aiming. Identity matching uses Apple Feature Print. If a bundled model cannot load, the app safely falls back to Apple Vision.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Skeleton-Assisted Aiming") {
                tuningSlider(
                    "Minimum joint confidence",
                    value: $tuning.poseMinimumJointConfidence,
                    range: 0.05...0.80,
                    step: 0.05,
                    format: decimal2
                )
                tuningSlider(
                    "Torso smoothing",
                    value: $tuning.torsoAnchorSmoothing,
                    range: 0.05...1.00,
                    step: 0.05,
                    format: decimal2
                )
                tuningSlider(
                    "Maximum aim-point step",
                    value: $tuning.maximumTorsoAnchorStepPercent,
                    range: 2...40,
                    step: 1,
                    format: percent
                )

                Text("Used only in Apple Vision + Skeleton mode. Smoothing is the fraction of each new torso position applied per Vision update. Maximum step is measured as a percentage of the displayed crop. If a reliable torso is unavailable, aiming falls back smoothly to the box center. Zoom still uses box size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Apparent-Scale Rejection") {
                tuningSlider(
                    "Suspicious size ratio",
                    value: $tuning.suspiciousScaleRatio,
                    range: 1.5...6.0,
                    step: 0.25,
                    format: ratio
                )
                tuningSlider(
                    "Reject size ratio",
                    value: $tuning.rejectionScaleRatio,
                    range: 2.0...8.0,
                    step: 0.25,
                    format: ratio
                )

                Text("Used only in Apple Vision + Skeleton mode. A candidate larger than the suspicious ratio must pass an immediate identity check. A candidate larger than the reject ratio cannot take the target lock. The scale estimate uses articulated torso/leg length when available, otherwise a verified full-body height. Similar size is neutral—not proof of identity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Continuous Tracking") {
                tuningSlider(
                    "Identity threshold",
                    value: $tuning.trackingIdentityThreshold,
                    range: 0.30...0.95,
                    step: 0.01,
                    format: decimal2
                )
                tuningSlider(
                    "Total threshold (with identity)",
                    value: $tuning.trackingAppearanceTotalThreshold,
                    range: 0.20...0.95,
                    step: 0.01,
                    format: decimal2
                )
                tuningSlider(
                    "Total threshold (geometry only)",
                    value: $tuning.trackingGeometryOnlyTotalThreshold,
                    range: 0.20...0.95,
                    step: 0.01,
                    format: decimal2
                )
                tuningSlider(
                    "Maximum center jump",
                    value: $tuning.maximumCenterDisplacementPercent,
                    range: 5...60,
                    step: 1,
                    format: percent
                )

                Text("The identity threshold applies to the gallery match. The two total thresholds apply to the combined association score, depending on whether an identity sample was available for that frame. Center jump is the Euclidean box-center movement as a percentage of the displayed crop. Candidates beyond this hard gate remain detected people but cannot become the red target. Box size and aspect ratio are not part of this gate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reacquisition") {
                tuningSlider(
                    "Identity threshold",
                    value: $tuning.reacquisitionIdentityThreshold,
                    range: 0.30...0.95,
                    step: 0.01,
                    format: decimal2
                )
                tuningSlider(
                    "Minimum identity margin",
                    value: $tuning.reacquisitionIdentityMargin,
                    range: 0...0.30,
                    step: 0.01,
                    format: decimal2
                )
                tuningSlider(
                    "Confirmation frames",
                    value: $tuning.reacquisitionConfirmationFrames,
                    range: 1...8,
                    step: 1,
                    format: wholeNumber
                )

                Text("The threshold is the required gallery identity match. The margin requires the best candidate to beat the runner-up. Confirmation frames are positive, mutually consistent observations before pan–tilt can resume.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Restore Tracking Defaults") {
                    tuning.resetTrackingDefaults()
                }
            } footer: {
                Text("Changes apply live to the next processed tracking frame and persist between app launches.")
            }
        }
        .navigationTitle("Tracking Tuning")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private func decimal2(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func wholeNumber(_ value: Double) -> String {
        "\(Int(value.rounded()))"
    }

    private func ratio(_ value: Double) -> String {
        String(format: "%.2f×", value)
    }
}

struct PanTiltTuningView: View {
    @ObservedObject var tuning: DeveloperTuningStore

    var body: some View {
        Form {
            Section("Horizontal Pan") {
                tuningSlider(
                    "Inner stopping zone",
                    value: constrainedInner(
                        $tuning.horizontalInnerPercent,
                        outer: { tuning.horizontalOuterPercent }
                    ),
                    range: 0.5...15,
                    step: 0.5,
                    format: percent1
                )
                tuningSlider(
                    "Outer activation zone",
                    value: constrainedOuter(
                        $tuning.horizontalOuterPercent,
                        inner: { tuning.horizontalInnerPercent }
                    ),
                    range: 2...30,
                    step: 0.5,
                    format: percent1
                )
                tuningSlider(
                    "Intended target offset",
                    value: $tuning.horizontalTargetOffsetPercent,
                    range: -20...20,
                    step: 1,
                    format: signedPercent
                )
                Text("A positive horizontal offset places the intended target position to the right of display center.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vertical Tilt") {
                tuningSlider(
                    "Inner stopping zone",
                    value: constrainedInner(
                        $tuning.verticalInnerPercent,
                        outer: { tuning.verticalOuterPercent }
                    ),
                    range: 0.5...15,
                    step: 0.5,
                    format: percent1
                )
                tuningSlider(
                    "Outer activation zone",
                    value: constrainedOuter(
                        $tuning.verticalOuterPercent,
                        inner: { tuning.verticalInnerPercent }
                    ),
                    range: 2...30,
                    step: 0.5,
                    format: percent1
                )
                tuningSlider(
                    "Intended target offset",
                    value: $tuning.verticalTargetOffsetPercent,
                    range: -20...20,
                    step: 1,
                    format: signedPercent
                )
                Text("A positive vertical offset places the intended target position above display center.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pan Speed") {
                tuningSlider(
                    "Minimum",
                    value: constrainedMinimumSpeed(
                        $tuning.minimumPanSpeed,
                        maximum: { tuning.maximumPanSpeed }
                    ),
                    range: 0...800,
                    step: 25,
                    format: speed
                )
                tuningSlider(
                    "Maximum",
                    value: constrainedMaximumSpeed(
                        $tuning.maximumPanSpeed,
                        minimum: { tuning.minimumPanSpeed }
                    ),
                    range: 100...2_000,
                    step: 50,
                    format: speed
                )
            }

            Section("Tilt Speed") {
                tuningSlider(
                    "Minimum",
                    value: constrainedMinimumSpeed(
                        $tuning.minimumTiltSpeed,
                        maximum: { tuning.maximumTiltSpeed }
                    ),
                    range: 0...800,
                    step: 25,
                    format: speed
                )
                tuningSlider(
                    "Maximum",
                    value: constrainedMaximumSpeed(
                        $tuning.maximumTiltSpeed,
                        minimum: { tuning.minimumTiltSpeed }
                    ),
                    range: 100...2_000,
                    step: 50,
                    format: speed
                )
            }

            Section("Shared Speed Behavior") {
                tuningSlider(
                    "Manual aiming speed",
                    value: $tuning.manualAimSpeed,
                    range: 25...800,
                    step: 25,
                    format: speed
                )
                tuningSlider(
                    "Conservative maximum",
                    value: $tuning.conservativeMaximumSpeed,
                    range: 100...1_200,
                    step: 25,
                    format: speed
                )
                tuningSlider(
                    "Minimum update change",
                    value: $tuning.minimumSpeedChange,
                    range: 5...150,
                    step: 5,
                    format: speed
                )
                tuningSlider(
                    "Command interval",
                    value: $tuning.commandInterval,
                    range: 0.05...0.30,
                    step: 0.01,
                    format: seconds
                )
                tuningSlider(
                    "Motor command lease",
                    value: $tuning.motorCommandLeaseDuration,
                    range: 0.10...1.00,
                    step: 0.01,
                    format: seconds
                )
                Text("Motor movement stops when this time passes without a reliable tracking observation that still requests movement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                tuningSlider(
                    "Stable observations",
                    value: $tuning.requiredStableObservationCount,
                    range: 1...6,
                    step: 1,
                    format: wholeNumber
                )
            }

            Section {
                Button("Restore Pan–Tilt Defaults") {
                    tuning.resetPanTiltDefaults()
                }
            } footer: {
                Text("Changes apply live. During automatic tracking, minimum and maximum motor speeds are divided by the current digital zoom. Manual aiming uses its separate fixed speed.")
            }
        }
        .navigationTitle("Pan–Tilt Tuning")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func constrainedInner(
        _ value: Binding<Double>,
        outer: @escaping () -> Double
    ) -> Binding<Double> {
        Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min($0, outer() - 0.5) }
        )
    }

    private func constrainedOuter(
        _ value: Binding<Double>,
        inner: @escaping () -> Double
    ) -> Binding<Double> {
        Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = max($0, inner() + 0.5) }
        )
    }

    private func constrainedMinimumSpeed(
        _ value: Binding<Double>,
        maximum: @escaping () -> Double
    ) -> Binding<Double> {
        Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min($0, maximum()) }
        )
    }

    private func constrainedMaximumSpeed(
        _ value: Binding<Double>,
        minimum: @escaping () -> Double
    ) -> Binding<Double> {
        Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = max($0, minimum()) }
        )
    }

    private func percent1(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func signedPercent(_ value: Double) -> String {
        String(format: "%+.0f%%", value)
    }

    private func speed(_ value: Double) -> String {
        "\(Int(value.rounded())) steps/s"
    }

    private func seconds(_ value: Double) -> String {
        String(format: "%.2f s", value)
    }

    private func wholeNumber(_ value: Double) -> String {
        "\(Int(value.rounded()))"
    }
}

@ViewBuilder
private func tuningSlider(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    format: @escaping (Double) -> String
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack {
            Text(title)
            Spacer()
            Text(format(value.wrappedValue))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        Slider(value: value, in: range, step: step)
    }
}
