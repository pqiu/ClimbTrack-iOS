import SwiftUI

struct BLEStatusControl: View {
    @ObservedObject var manager: BLEManager

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)

            Text(compactStatus)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .accessibilityLabel("ClimbTrack Bluetooth: \(compactStatus)")
    }

    private var compactStatus: String {
        switch manager.state {
        case .neverSelected, .idle, .failed:
            return "Disconnected"
        case .scanning:
            return "Scanning…"
        case .connecting:
            return "Connecting…"
        case .connected:
            return "Connected"
        case .reconnecting:
            return "Reconnecting…"
        case .disconnecting:
            return "Disconnecting…"
        case .unavailable:
            return "Bluetooth unavailable"
        }
    }

    private var statusColor: Color {
        switch manager.state {
        case .connected:
            return .green
        case .scanning, .connecting, .reconnecting, .disconnecting:
            return .yellow
        case .neverSelected, .idle, .failed, .unavailable:
            return .red
        }
    }
}

struct BLEDeviceManagementView: View {
    @ObservedObject var manager: BLEManager
    @ObservedObject var motorOwnership: MotorControlOwnership
    @ObservedObject var developerTuning: DeveloperTuningStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                actionsSection
                devicesSection

                developerControlsSection
                openSourceSection

                if manager.preferredPeripheralIdentifier != nil {
                    preferredDeviceSection
                }
            }
            .navigationTitle("ClimbTrack Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var statusSection: some View {
        Section("Connection") {
            LabeledContent("Status", value: detailedStatus)

            if let name = manager.connectedDeviceName {
                LabeledContent("Device", value: name)
            }

            if let deviceStatus = manager.latestDeviceStatus {
                LabeledContent("Controller", value: deviceStatus)
            }

            if case .unavailable(let message) = manager.state {
                Text(message)
                    .foregroundStyle(.secondary)
            }

            if case .failed(let message) = manager.state {
                Text(message)
                    .foregroundStyle(.red)
            }
        }
    }

    private var actionsSection: some View {
        Section {
            if manager.isConnected {
                Button("Disconnect") {
                    manager.disconnect()
                }

                Button("Choose Another Device") {
                    manager.chooseAnotherDevice()
                }
            } else if manager.state == .reconnecting {
                Button("Stop Reconnecting") {
                    manager.disconnect()
                }
            } else {
                Button(manager.isScanning ? "Stop Scanning" : "Scan for Devices") {
                    if manager.isScanning {
                        manager.stopScan()
                    } else {
                        manager.startScan()
                    }
                }
                .disabled(isBluetoothUnavailable)

                if manager.preferredPeripheralIdentifier != nil,
                   manager.state != .reconnecting {
                    Button("Reconnect Preferred Device") {
                        manager.reconnectPreferredDevice()
                    }
                    .disabled(isBluetoothUnavailable)
                }
            }
        }
    }

    private var devicesSection: some View {
        Section("Nearby Compatible Devices") {
            if manager.discoveredDevices.isEmpty {
                HStack(spacing: 10) {
                    if manager.isScanning {
                        ProgressView()
                    }
                    Text(manager.isScanning ? "Looking for ClimbTrack devices…" : "No devices found")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(manager.discoveredDevices) { device in
                    Button {
                        manager.connect(to: device.id)
                    } label: {
                        deviceRow(device)
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        manager.state == .connecting ||
                        manager.state == .disconnecting ||
                        manager.connectedPeripheralIdentifier == device.id
                    )
                }
            }
        }
    }

    private func deviceRow(_ device: DiscoveredBLEDevice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .foregroundStyle(.primary)

                Text("\(device.signalDescription) · \(device.rssi) dBm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if manager.connectedPeripheralIdentifier == device.id {
                Text("Connected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else if manager.preferredPeripheralIdentifier == device.id {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Preferred device")
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var developerControlsSection: some View {
        Section("Advanced Settings") {
            NavigationLink {
                ManualMotorControlView(
                    bleManager: manager,
                    ownership: motorOwnership
                )
            } label: {
                Label("Manual Motor Controls", systemImage: "wrench.and.screwdriver")
            }

            NavigationLink {
                ZoomTuningView(tuning: developerTuning)
            } label: {
                Label("Zoom Tuning", systemImage: "magnifyingglass")
            }

            NavigationLink {
                PanTiltTuningView(tuning: developerTuning)
            } label: {
                Label("Pan–Tilt Tuning", systemImage: "move.3d")
            }

            NavigationLink {
                TrackingTuningView(tuning: developerTuning)
            } label: {
                Label("Tracking Tuning", systemImage: "viewfinder")
            }

            NavigationLink {
                RecordingOutputTuningView(tuning: developerTuning)
            } label: {
                Label("Recording Output", systemImage: "video.badge.ellipsis")
            }
        }
    }

    private var preferredDeviceSection: some View {
        Section("Preferred Device") {
            LabeledContent("Name", value: manager.preferredDeviceName ?? "ClimbTrack")

            Button("Forget Preferred Device", role: .destructive) {
                manager.forgetPreferredDevice()
            }
        }
    }

    private var openSourceSection: some View {
        Section("Open Source") {
            Link(
                destination: URL(string: "https://github.com/pqiu/ClimbTrack-iOS")!
            ) {
                Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
            }

            Link(
                destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!
            ) {
                Label("GNU AGPL v3 License", systemImage: "doc.text")
            }

            Link(
                destination: URL(
                    string: "https://github.com/pqiu/ClimbTrack-iOS/blob/main/ClimbTrack_app_v2/Models/THIRD_PARTY_NOTICES.md"
                )!
            ) {
                Label("Third-Party Notices", systemImage: "doc.text.magnifyingglass")
            }

            Text("ClimbTrack is free software licensed under the GNU Affero General Public License v3.0. It is provided without warranty.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var detailedStatus: String {
        switch manager.state {
        case .neverSelected:
            return "No device selected"
        case .idle:
            return "Disconnected"
        case .scanning:
            return "Scanning"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .reconnecting:
            return "Reconnecting"
        case .disconnecting:
            return "Disconnecting"
        case .unavailable:
            return "Unavailable"
        case .failed:
            return "Connection failed"
        }
    }

    private var isBluetoothUnavailable: Bool {
        if case .unavailable = manager.state {
            return true
        }
        return false
    }
}
