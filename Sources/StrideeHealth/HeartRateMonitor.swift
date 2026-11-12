import Combine
import CoreBluetooth
import Foundation
import os

/// A Bluetooth heart-rate strap — Polar, Wahoo, Garmin, COROS, any of them.
///
/// Every strap speaks the Bluetooth SIG Heart Rate Service the same way, so
/// there is no per-brand code: scan for service `0x180D`, subscribe to
/// `0x2A37`, and it reports about once a second. The strap the athlete picks
/// is remembered and reconnects whenever it is in range, and while
/// ``WorkoutRecorder`` is recording its readings go into the workout — laps'
/// average heart rate, Apple Health, the FIT file — with nothing to wire.
///
/// ```swift
/// @ObservedObject var strap = HeartRateMonitor.shared
/// strap.startScan()                 // a pairing screen: strap.discovered
/// strap.connect(device)             // remembered from now on
/// strap.currentBPM                  // live
/// ```
///
/// Strictly opt-in: Bluetooth is not touched — and its permission alert never
/// shown — until ``startScan()`` is called, or a strap was paired before.
/// Needs `NSBluetoothAlwaysUsageDescription` in `Info.plist`.
@MainActor
public final class HeartRateMonitor: NSObject, ObservableObject {
    public static let shared = HeartRateMonitor()

    public enum State: Sendable, Equatable {
        /// Waiting for Bluetooth to report.
        case unknown
        /// No Bluetooth LE on this device, or no `NSBluetoothAlwaysUsageDescription`.
        case unsupported
        /// The athlete turned Bluetooth off for your app.
        case unauthorized
        case poweredOff
        /// Ready, not connected.
        case idle
        case scanning
        /// Connecting, or reconnecting after a dropout.
        case connecting
        case connected

        public var isConnected: Bool { self == .connected }
    }

    /// A strap found while scanning. `id` is stable across launches.
    public struct DiscoveredDevice: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
    }

    /// The latest reading, or `nil` when no strap is delivering.
    @Published public private(set) var currentBPM: Int?
    @Published public private(set) var state: State = .unknown
    /// The connected (or connecting) strap's name.
    @Published public private(set) var deviceName: String?
    /// Straps found by the current scan.
    @Published public private(set) var discovered: [DiscoveredDevice] = []

    /// Every reading, for an app that wants the stream itself. The recorder
    /// gets them without this.
    public var onSample: ((Date, Int) -> Void)?
    /// The recorder's own subscription.
    var recorderSink: ((Date, Int) -> Void)?

    private var central: CBCentralManager?
    private var wantsScan = false
    private var peripheral: CBPeripheral?
    private var intentionalDisconnect = false
    private var seen: [UUID: CBPeripheral] = [:]
    private var scanTimeout: Task<Void, Never>?
    private let logger = Logger(subsystem: "fit.stridee.health", category: "heart-rate")

    private nonisolated static let service = CBUUID(string: "180D")
    private nonisolated static let measurement = CBUUID(string: "2A37")
    private static let savedDeviceKey = "fit.stridee.health.heartRateDevice"

    private override init() { super.init() }

    // MARK: - Pairing

    /// Whether a strap was paired before — "reconnecting" rather than "pair a
    /// sensor".
    public var hasSavedDevice: Bool { savedDeviceID != nil }

    /// Bring Bluetooth up only if a strap was paired before, so it reconnects
    /// without prompting anyone who never paired one. The recorder calls it
    /// when recording starts; call it when your record screen appears too.
    public func activateIfPaired() {
        guard hasSavedDevice else { return }
        ensureCentral()
        if central?.state == .poweredOn { restoreSavedDevice() }
    }

    /// Scan for straps nearby, for 15 seconds. Results in ``discovered``. The
    /// first call shows Bluetooth's permission alert.
    public func startScan() {
        wantsScan = true
        ensureCentral()
        beginScanIfReady()
    }

    public func stopScan() {
        wantsScan = false
        scanTimeout?.cancel()
        scanTimeout = nil
        if central?.state == .poweredOn { central?.stopScan() }
        if state == .scanning { state = peripheral == nil ? .idle : .connected }
    }

    /// Connect to a strap from ``discovered`` and remember it.
    public func connect(_ device: DiscoveredDevice) {
        guard let target = seen[device.id] else { return }
        stopScan()
        UserDefaults.standard.set(device.id.uuidString, forKey: Self.savedDeviceKey)
        beginConnect(to: target)
    }

    /// Disconnect and forget the strap.
    public func disconnect() {
        intentionalDisconnect = true
        UserDefaults.standard.removeObject(forKey: Self.savedDeviceKey)
        if let peripheral, let central { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        deviceName = nil
        currentBPM = nil
        state = central.map { mapped($0.state) } ?? .idle
    }

    /// Adopt a strap your app paired before using the SDK, saved as a
    /// `CBPeripheral` identifier string under `key` in `UserDefaults.standard`.
    /// Read once, then removed.
    public static func importPairedDevice(fromUserDefaultsKey key: String) {
        guard let old = UserDefaults.standard.string(forKey: key) else { return }
        defer { UserDefaults.standard.removeObject(forKey: key) }
        guard UserDefaults.standard.string(forKey: savedDeviceKey) == nil, UUID(uuidString: old) != nil else { return }
        UserDefaults.standard.set(old, forKey: savedDeviceKey)
    }

    // MARK: - Internals

    private var savedDeviceID: UUID? {
        UserDefaults.standard.string(forKey: Self.savedDeviceKey).flatMap(UUID.init(uuidString:))
    }

    /// Created on first real use, so nobody who never reaches for a strap is
    /// asked about Bluetooth. Without the usage string, creating it would crash.
    private func ensureCentral() {
        guard central == nil else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil else {
            logger.error("Info.plist has no NSBluetoothAlwaysUsageDescription: heart-rate straps are off")
            state = .unsupported
            return
        }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func beginScanIfReady() {
        guard wantsScan, let central, central.state == .poweredOn else { return }
        discovered.removeAll()
        seen.removeAll()
        state = .scanning
        central.scanForPeripherals(withServices: [Self.service])
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.stopScan()
        }
    }

    private func beginConnect(to peripheral: CBPeripheral) {
        guard let central else { return }
        intentionalDisconnect = false
        self.peripheral = peripheral
        peripheral.delegate = self
        deviceName = peripheral.name
        state = .connecting
        // No timeout: CoreBluetooth keeps it pending and connects the moment
        // the strap is reachable, which is what makes out-of-range-and-back
        // reconnect by itself.
        central.connect(peripheral)
    }

    private func restoreSavedDevice() {
        guard let saved = savedDeviceID, let central else { return }
        if let match = central.retrieveConnectedPeripherals(withServices: [Self.service]).first(where: { $0.identifier == saved })
            ?? central.retrievePeripherals(withIdentifiers: [saved]).first {
            beginConnect(to: match)
        }
    }

    /// A Heart Rate Measurement value: a flags byte, whose bit 0 says whether
    /// the reading that follows is 8 or 16 bits.
    nonisolated static func parse(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        if bytes[0] & 0x01 != 0 {
            guard bytes.count >= 3 else { return nil }
            return Int(bytes[1]) | (Int(bytes[2]) << 8)
        }
        return Int(bytes[1])
    }

    private func handle(_ bpm: Int) {
        // 0 is the strap saying "no skin contact yet".
        guard bpm > 0 else { return }
        currentBPM = bpm
        let now = Date()
        recorderSink?(now, bpm)
        onSample?(now, bpm)
    }

    private func mapped(_ s: CBManagerState) -> State {
        switch s {
        case .poweredOn: return peripheral == nil ? .idle : .connected
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        default: return .unknown
        }
    }
}

// MARK: - CoreBluetooth

// The central is created with `queue: nil`, so every callback is on the main thread.
extension HeartRateMonitor: CBCentralManagerDelegate {
    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            state = mapped(central.state)
            if central.state == .poweredOn {
                restoreSavedDevice()
                beginScanIfReady()
            } else {
                currentBPM = nil
            }
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        MainActor.assumeIsolated {
            seen[peripheral.identifier] = peripheral
            // A strap with no name is almost always noise.
            guard let name else { return }
            let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
            if let index = discovered.firstIndex(where: { $0.id == device.id }) {
                discovered[index] = device
            } else {
                discovered.append(device)
            }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            state = .connected
            deviceName = peripheral.name ?? deviceName
            peripheral.discoverServices([Self.service])
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            // The strap may just be waking up.
            if !intentionalDisconnect { central.connect(peripheral) }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            currentBPM = nil
            guard !intentionalDisconnect else { return }
            // A dropout: reconnect when it is back in range.
            state = .connecting
            central.connect(peripheral)
        }
    }
}

extension HeartRateMonitor: CBPeripheralDelegate {
    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { return }
        peripheral.discoverCharacteristics([Self.measurement], for: service)
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.measurement }) else { return }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.measurement, let data = characteristic.value, let bpm = Self.parse(data) else { return }
        MainActor.assumeIsolated { handle(bpm) }
    }
}
