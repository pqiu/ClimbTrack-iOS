import Combine
import CoreBluetooth
import Foundation

enum BLEConnectionState: Equatable {
    case neverSelected
    case idle
    case scanning
    case connecting
    case connected
    case reconnecting
    case disconnecting
    case unavailable(String)
    case failed(String)
}

struct DiscoveredBLEDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int

    var signalDescription: String {
        if rssi >= -50 {
            return "Very close"
        }
        if rssi >= -70 {
            return "Nearby"
        }
        return "Weak"
    }
}

struct BLEWriteCompletionDiagnostic: Equatable {
    let command: String
    let queueDelay: TimeInterval
    let latency: TimeInterval
    let errorDescription: String?
}

struct BLEDeviceAcknowledgementDiagnostic: Equatable {
    let status: String
    let matchingCommandLatency: TimeInterval?
}

enum BLECommand: Equatable {
    case enable
    case disable
    case move(panSpeed: Int, tiltSpeed: Int)
    case stop
    case testPan
    case testTilt

    var encodedString: String {
        switch self {
        case .enable:
            return "ENABLE"
        case .disable:
            return "DISABLE"
        case .move(let panSpeed, let tiltSpeed):
            return "MOVE \(panSpeed) \(tiltSpeed)"
        case .stop:
            return "STOP"
        case .testPan:
            return "TESTPAN"
        case .testTilt:
            return "TESTTILT"
        }
    }
}

@MainActor
final class BLEManager: NSObject, ObservableObject {
    static let advertisedName = "ClimbTrack"
    static let serviceUUID = CBUUID(string: "7b9e0001-7c6b-4b6f-9f4f-2c9f4c000001")
    static let commandCharacteristicUUID = CBUUID(
        string: "7b9e0002-7c6b-4b6f-9f4f-2c9f4c000002"
    )
    static let statusCharacteristicUUID = CBUUID(
        string: "7b9e0003-7c6b-4b6f-9f4f-2c9f4c000003"
    )

    @Published private(set) var state: BLEConnectionState = .neverSelected
    @Published private(set) var discoveredDevices: [DiscoveredBLEDevice] = []
    @Published private(set) var preferredPeripheralIdentifier: UUID?
    @Published private(set) var preferredDeviceName: String?
    @Published private(set) var connectedPeripheralIdentifier: UUID?
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var latestDeviceStatus: String?
    @Published private(set) var latestWriteCompletionDiagnostic: BLEWriteCompletionDiagnostic?
    @Published private(set) var latestDeviceAcknowledgementDiagnostic: BLEDeviceAcknowledgementDiagnostic?

    private enum ScanPurpose: Equatable {
        case manualSelection
        case preferredReconnect
    }

    private enum PreferenceKey {
        static let identifier = "ClimbTrack.preferredPeripheralIdentifier"
        static let name = "ClimbTrack.preferredPeripheralName"
    }

    private var centralManager: CBCentralManager!
    private var peripheralsByIdentifier: [UUID: CBPeripheral] = [:]
    private var devicesByIdentifier: [UUID: DiscoveredBLEDevice] = [:]
    private var targetPeripheral: CBPeripheral?
    private var connectedPeripheral: CBPeripheral?
    private var pendingPeripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var scanPurpose: ScanPurpose?
    private var intentionalDisconnect = false
    private var scanAfterIntentionalDisconnect = false
    // An intentional disconnect suppresses reconnects for this manager's
    // lifetime. A later app launch creates a new manager and tries again.
    private var automaticReconnectEnabled = true
    private struct ScheduledCommand {
        let command: BLECommand
        let requestedAt: TimeInterval
    }

    private struct InFlightWrite {
        let command: String
        let requestedAt: TimeInterval
        let submittedAt: TimeInterval
    }

    private var inFlightWrite: InFlightWrite?
    private var pendingCommands: [ScheduledCommand] = []
    private var recentSubmissions: [(command: String, submittedAt: TimeInterval)] = []

    override init() {
        let defaults = UserDefaults.standard
        preferredPeripheralIdentifier = defaults
            .string(forKey: PreferenceKey.identifier)
            .flatMap(UUID.init(uuidString:))
        preferredDeviceName = defaults.string(forKey: PreferenceKey.name)

        super.init()
        // A single main-queue central manager keeps delegate and SwiftUI state
        // transitions serialized without creating independent reconnect loops.
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    var isConnected: Bool {
        state == .connected
    }

    var canSendCommands: Bool {
        state == .connected
            && connectedPeripheral?.state == .connected
            && commandCharacteristic != nil
    }

    var isScanning: Bool {
        state == .scanning || (state == .reconnecting && centralManager?.isScanning == true)
    }

    func startScan() {
        guard centralManager.state == .poweredOn else {
            updateUnavailableState()
            return
        }
        guard connectedPeripheral == nil, targetPeripheral == nil else { return }

        devicesByIdentifier.removeAll()
        discoveredDevices.removeAll()
        scanPurpose = .manualSelection
        state = .scanning
        beginServiceScan()
    }

    func stopScan() {
        centralManager.stopScan()
        scanPurpose = nil

        if preferredPeripheralIdentifier == nil {
            state = .neverSelected
        } else {
            state = .idle
        }
    }

    func connect(to identifier: UUID) {
        guard centralManager.state == .poweredOn,
              let peripheral = peripheralsByIdentifier[identifier] else { return }

        if connectedPeripheral?.identifier == identifier, isConnected {
            return
        }

        centralManager.stopScan()
        scanPurpose = nil
        latestDeviceStatus = nil
        automaticReconnectEnabled = true

        if let connectedPeripheral {
            pendingPeripheral = peripheral
            intentionalDisconnect = true
            disconnectCurrentPeripheral(connectedPeripheral)
        } else {
            beginConnection(to: peripheral, reconnecting: false)
        }
    }

    func disconnect() {
        automaticReconnectEnabled = false
        pendingPeripheral = nil
        scanAfterIntentionalDisconnect = false
        centralManager.stopScan()
        scanPurpose = nil

        guard let peripheral = connectedPeripheral ?? targetPeripheral else {
            state = preferredPeripheralIdentifier == nil ? .neverSelected : .idle
            return
        }

        intentionalDisconnect = true
        disconnectCurrentPeripheral(peripheral)
    }

    func chooseAnotherDevice() {
        automaticReconnectEnabled = false
        pendingPeripheral = nil

        if let peripheral = connectedPeripheral ?? targetPeripheral {
            intentionalDisconnect = true
            scanAfterIntentionalDisconnect = true
            disconnectCurrentPeripheral(peripheral)
        } else {
            startScan()
        }
    }

    func reconnectPreferredDevice() {
        guard preferredPeripheralIdentifier != nil else {
            startScan()
            return
        }
        guard connectedPeripheral == nil, targetPeripheral == nil else { return }

        automaticReconnectEnabled = true
        beginPreferredReconnect()
    }

    func forgetPreferredDevice() {
        automaticReconnectEnabled = false
        centralManager.stopScan()
        scanPurpose = nil
        preferredPeripheralIdentifier = nil
        preferredDeviceName = nil
        UserDefaults.standard.removeObject(forKey: PreferenceKey.identifier)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.name)

        pendingPeripheral = nil
        scanAfterIntentionalDisconnect = false

        if let peripheral = connectedPeripheral ?? targetPeripheral {
            intentionalDisconnect = true
            disconnectCurrentPeripheral(peripheral)
        } else {
            state = .neverSelected
        }
    }

    @discardableResult
    func send(_ command: BLECommand) -> Bool {
        guard state == .connected,
              let connectedPeripheral,
              connectedPeripheral.state == .connected,
              commandCharacteristic != nil else {
            return false
        }

        enqueue(command)
        transmitNextCommandIfPossible()
        return true
    }

    /// Keep the command backlog bounded and meaningful. MOVE represents desired
    /// velocity, so only its newest pending value matters. STOP invalidates all
    /// unsent movement and is placed ahead of other pending work.
    private func enqueue(_ command: BLECommand) {
        let scheduled = ScheduledCommand(
            command: command,
            requestedAt: ProcessInfo.processInfo.systemUptime
        )
        switch command {
        case .move:
            if let index = pendingCommands.lastIndex(where: {
                if case .move = $0.command { return true }
                return false
            }) {
                pendingCommands[index] = scheduled
            } else {
                pendingCommands.append(scheduled)
            }

        case .stop:
            pendingCommands.removeAll {
                switch $0.command {
                case .move, .stop: true
                default: false
                }
            }
            pendingCommands.insert(scheduled, at: 0)

        case .disable:
            // No queued motion should run immediately before or after DISABLE.
            pendingCommands.removeAll {
                if case .move = $0.command { return true }
                return false
            }
            pendingCommands.append(scheduled)

        default:
            pendingCommands.append(scheduled)
        }
    }

    private func transmitNextCommandIfPossible() {
        guard inFlightWrite == nil,
              !pendingCommands.isEmpty,
              state == .connected,
              let connectedPeripheral,
              connectedPeripheral.state == .connected,
              let commandCharacteristic else { return }

        let scheduled = pendingCommands.removeFirst()
        let encodedCommand = scheduled.command.encodedString
        guard let data = encodedCommand.data(using: .utf8) else { return }
        let submittedAt = ProcessInfo.processInfo.systemUptime
        inFlightWrite = InFlightWrite(
            command: encodedCommand,
            requestedAt: scheduled.requestedAt,
            submittedAt: submittedAt
        )
        recentSubmissions.append((encodedCommand, submittedAt))
        if recentSubmissions.count > 64 {
            recentSubmissions.removeFirst(recentSubmissions.count - 64)
        }

        connectedPeripheral.writeValue(
            data,
            for: commandCharacteristic,
            type: .withResponse
        )
    }

    private func beginServiceScan() {
        guard !centralManager.isScanning else { return }

        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func beginPreferredReconnect() {
        guard centralManager.state == .poweredOn,
              let preferredPeripheralIdentifier else {
            updateUnavailableState()
            return
        }

        intentionalDisconnect = false
        state = .reconnecting

        if let alreadyConnected = centralManager
            .retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
            .first(where: { $0.identifier == preferredPeripheralIdentifier }) {
            beginConnection(to: alreadyConnected, reconnecting: true)
            return
        }

        scanPurpose = .preferredReconnect
        beginServiceScan()
    }

    private func beginConnection(to peripheral: CBPeripheral, reconnecting: Bool) {
        guard targetPeripheral == nil, connectedPeripheral == nil else { return }

        centralManager.stopScan()
        scanPurpose = nil
        targetPeripheral = peripheral
        peripheralsByIdentifier[peripheral.identifier] = peripheral
        peripheral.delegate = self
        state = reconnecting ? .reconnecting : .connecting
        centralManager.connect(peripheral, options: nil)
    }

    private func disconnectCurrentPeripheral(_ peripheral: CBPeripheral) {
        // Attempt a safety stop before cancelling. The short delay gives a
        // write-with-response packet time to leave without maintaining a queue.
        _ = send(.stop)
        state = .disconnecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            self.centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func completeConnection(to peripheral: CBPeripheral) {
        centralManager.stopScan()
        scanPurpose = nil
        targetPeripheral = nil
        connectedPeripheral = peripheral
        connectedPeripheralIdentifier = peripheral.identifier
        connectedDeviceName = displayName(for: peripheral, advertisementName: nil)
        intentionalDisconnect = false
        state = .connected

        preferredPeripheralIdentifier = peripheral.identifier
        preferredDeviceName = connectedDeviceName
        UserDefaults.standard.set(
            peripheral.identifier.uuidString,
            forKey: PreferenceKey.identifier
        )
        UserDefaults.standard.set(connectedDeviceName, forKey: PreferenceKey.name)
    }

    private func clearActiveConnection() {
        targetPeripheral = nil
        connectedPeripheral = nil
        connectedPeripheralIdentifier = nil
        connectedDeviceName = nil
        commandCharacteristic = nil
        statusCharacteristic = nil
        latestDeviceStatus = nil
        latestWriteCompletionDiagnostic = nil
        latestDeviceAcknowledgementDiagnostic = nil
        inFlightWrite = nil
        pendingCommands.removeAll()
        recentSubmissions.removeAll()
    }

    private func handleConnectionFailure(_ message: String, peripheral: CBPeripheral) {
        let shouldReconnect = !intentionalDisconnect
            && automaticReconnectEnabled
            && peripheral.identifier == preferredPeripheralIdentifier

        clearActiveConnection()

        if shouldReconnect, centralManager.state == .poweredOn {
            beginPreferredReconnect()
        } else {
            state = .failed(message)
        }
    }

    private func persistDiscoveredDevice(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        let rssiValue = rssi.intValue
        guard rssiValue != 127 else { return }

        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let device = DiscoveredBLEDevice(
            id: peripheral.identifier,
            name: displayName(for: peripheral, advertisementName: advertisedName),
            rssi: rssiValue
        )

        peripheralsByIdentifier[peripheral.identifier] = peripheral
        devicesByIdentifier[peripheral.identifier] = device
        discoveredDevices = devicesByIdentifier.values.sorted {
            if $0.rssi == $1.rssi {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.rssi > $1.rssi
        }
    }

    private func displayName(for peripheral: CBPeripheral, advertisementName: String?) -> String {
        if let name = advertisementName ?? peripheral.name, !name.isEmpty {
            return name
        }
        return Self.advertisedName
    }

    private func updateUnavailableState() {
        switch centralManager.state {
        case .poweredOff:
            state = .unavailable("Bluetooth is turned off.")
        case .unauthorized:
            state = .unavailable("Bluetooth access is not authorized for ClimbTrack.")
        case .unsupported:
            state = .unavailable("This device does not support Bluetooth Low Energy.")
        case .resetting:
            state = .unavailable("Bluetooth is restarting.")
        case .unknown:
            state = .unavailable("Bluetooth is not ready yet.")
        case .poweredOn:
            break
        @unknown default:
            state = .unavailable("Bluetooth is unavailable.")
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            central.stopScan()
            scanPurpose = nil
            clearActiveConnection()
            updateUnavailableState()
            return
        }

        if preferredPeripheralIdentifier == nil {
            startScan()
        } else if automaticReconnectEnabled {
            beginPreferredReconnect()
        } else {
            state = .idle
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Scanning is already filtered by the verified service UUID. The name is
        // display metadata only because multiple valid devices share it.
        persistDiscoveredDevice(
            peripheral: peripheral,
            advertisementData: advertisementData,
            rssi: RSSI
        )

        if scanPurpose == .preferredReconnect,
           peripheral.identifier == preferredPeripheralIdentifier {
            beginConnection(to: peripheral, reconnecting: true)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        handleConnectionFailure(
            error?.localizedDescription ?? "Could not connect to the ClimbTrack device.",
            peripheral: peripheral
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let wasIntentional = intentionalDisconnect
        let nextPeripheral = pendingPeripheral
        let shouldStartManualScan = scanAfterIntentionalDisconnect

        pendingPeripheral = nil
        scanAfterIntentionalDisconnect = false
        clearActiveConnection()

        if let nextPeripheral {
            intentionalDisconnect = false
            beginConnection(to: nextPeripheral, reconnecting: false)
            return
        }

        if wasIntentional {
            intentionalDisconnect = false
            if shouldStartManualScan {
                startScan()
            } else {
                state = preferredPeripheralIdentifier == nil ? .neverSelected : .idle
            }
            return
        }

        if automaticReconnectEnabled,
           peripheral.identifier == preferredPeripheralIdentifier,
           central.state == .poweredOn {
            beginPreferredReconnect()
        } else {
            state = .failed(
                error?.localizedDescription ?? "The ClimbTrack device disconnected."
            )
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Self.commandCharacteristicUUID else { return }
        let completedAt = ProcessInfo.processInfo.systemUptime
        let completed = inFlightWrite
        inFlightWrite = nil
        latestWriteCompletionDiagnostic = BLEWriteCompletionDiagnostic(
            command: completed?.command ?? "UNKNOWN",
            queueDelay: max(
                0,
                (completed?.submittedAt ?? completedAt)
                    - (completed?.requestedAt ?? completedAt)
            ),
            latency: max(0, completedAt - (completed?.submittedAt ?? completedAt)),
            errorDescription: error?.localizedDescription
        )
        transmitNextCommandIfPossible()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            handleConnectionFailure(error.localizedDescription, peripheral: peripheral)
            return
        }

        guard let service = peripheral.services?.first(where: {
            $0.uuid == Self.serviceUUID
        }) else {
            handleConnectionFailure(
                "The expected ClimbTrack BLE service was not found.",
                peripheral: peripheral
            )
            return
        }

        peripheral.discoverCharacteristics(
            [Self.commandCharacteristicUUID, Self.statusCharacteristicUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            handleConnectionFailure(error.localizedDescription, peripheral: peripheral)
            return
        }

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.commandCharacteristicUUID:
                commandCharacteristic = characteristic
            case Self.statusCharacteristicUUID:
                statusCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            default:
                break
            }
        }

        guard commandCharacteristic != nil else {
            handleConnectionFailure(
                "The ClimbTrack command characteristic was not found.",
                peripheral: peripheral
            )
            return
        }

        completeConnection(to: peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              characteristic.uuid == Self.statusCharacteristicUUID,
              let data = characteristic.value,
              let status = String(data: data, encoding: .utf8) else { return }

        let receivedAt = ProcessInfo.processInfo.systemUptime
        // Firmware processes writes in order, so associate repeated commands
        // with their oldest still-unmatched submission.
        let matchingIndex = recentSubmissions.firstIndex {
            expectedAcknowledgement(for: $0.command) == status.uppercased()
        }
        let matchingLatency = matchingIndex.map {
            max(0, receivedAt - recentSubmissions[$0].submittedAt)
        }
        if let matchingIndex {
            recentSubmissions.removeSubrange(0...matchingIndex)
        }
        latestDeviceAcknowledgementDiagnostic = BLEDeviceAcknowledgementDiagnostic(
            status: status,
            matchingCommandLatency: matchingLatency
        )
        latestDeviceStatus = status
    }

    private func expectedAcknowledgement(for command: String) -> String {
        switch command {
        case "ENABLE": "OK ENABLE"
        case "DISABLE": "OK DISABLE"
        case "STOP": "OK STOP"
        case "TESTPAN": "OK TESTPAN"
        case "TESTTILT": "OK TESTTILT"
        default:
            command.hasPrefix("MOVE ") ? "OK \(command)" : ""
        }
    }
}
