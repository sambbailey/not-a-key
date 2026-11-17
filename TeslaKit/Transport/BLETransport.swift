import CoreBluetooth
import Foundation
import os

private let log = Logger(subsystem: "com.nevelen.notakey", category: "ble")

/// A `VehicleTransport` over Tesla's BLE GATT service.
///
/// All mutable state is confined to `queue`, which is also the queue CoreBluetooth calls
/// the delegate methods on; that confinement is what makes the `@unchecked Sendable` sound.
public final class BLETransport: NSObject, VehicleTransport, @unchecked Sendable {
    static var serviceUUID: CBUUID { CBUUID(string: "00000211-b2d1-43f0-9b88-960cebf8b91e") }
    static var writeUUID: CBUUID { CBUUID(string: "00000212-b2d1-43f0-9b88-960cebf8b91e") }
    static var notifyUUID: CBUUID { CBUUID(string: "00000213-b2d1-43f0-9b88-960cebf8b91e") }
    static let chunkWriteTimeout: Duration = .seconds(5)
    /// Vehicles don't advertise the vehicle service UUID, so filtering the scan on it finds
    /// nothing; match on the local name instead (as the Go reference does).
    static var scanServices: [CBUUID]? { nil }
    /// Where the vehicle's peripheral identifier is remembered after the first connection, so
    /// later connections (including from a locked phone, where unfiltered scans don't run) can
    /// go straight to it without scanning.
    static var knownPeripherals: UserDefaults { .standard }
    /// How long to try the remembered peripheral before falling back to a scan.
    static let knownPeripheralGrace: Duration = .seconds(3)

    public let incoming: AsyncStream<Data>
    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let queue = DispatchQueue(label: "com.nevelen.notakey.ble")
    private let vin: String

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var blockLength = 0
    private var reassembler = FrameReassembler()
    private var isClosed = false
    private var teslaNamesSeen = 0
    private var isConnected = false

    private var setup: CheckedContinuation<Void, Error>?

    /// Messages waiting to be written, in order; the first one is in flight.
    private var sendQueue: [PendingSend] = []
    /// Identifies the chunk in flight, so a stale write timeout can tell it has been answered.
    private var chunkSerial = 0

    private struct PendingSend {
        var chunks: [Data]
        let continuation: CheckedContinuation<Void, Error>
    }

    private init(vin: String) {
        self.vin = vin
        (incoming, incomingContinuation) = AsyncStream.makeStream(of: Data.self)
        super.init()
    }

    /// Whether a scanned advertisement is the vehicle with this VIN.
    static func matches(advertisement: [String: Any], vin: String) -> Bool {
        advertisement[CBAdvertisementDataLocalNameKey] as? String == VehicleLocalName.make(vin: vin)
    }

    /// Scans for the vehicle, connects and subscribes to its replies.
    ///
    /// `scanTimeout` bounds the whole setup, from waiting for Bluetooth to the subscription;
    /// running out throws `VehicleError.notInRange`.
    public static func connect(vin: String, scanTimeout: Duration = .seconds(10)) async throws -> BLETransport {
        let transport = BLETransport(vin: vin)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transport.queue.async { transport.start(continuation, timeout: scanTimeout) }
            }
        } onCancel: {
            transport.queue.async { transport.tearDown(CancellationError()) }
        }
        return transport
    }

    public func send(_ message: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.enqueue(message, continuation) }
        }
    }

    public func close() {
        queue.async { self.tearDown(VehicleError.notInRange) }
    }

    // MARK: Queue-confined

    private func start(_ continuation: CheckedContinuation<Void, Error>, timeout: Duration) {
        guard !isClosed else {
            continuation.resume(throwing: CancellationError())
            return
        }
        setup = continuation
        central = CBCentralManager(delegate: self, queue: queue)
        queue.asyncAfter(deadline: .now() + timeout.timeInterval) { [weak self] in
            guard let self, setup != nil else { return }
            log.error("Setup timed out after \(timeout, privacy: .public); other Tesla advertisements seen: \(self.teslaNamesSeen, privacy: .public)")
            tearDown(VehicleError.notInRange)
        }
    }

    private func finishSetup() {
        if let peripheral {
            Self.knownPeripherals.set(peripheral.identifier.uuidString, forKey: knownPeripheralKey)
        }
        setup?.resume()
        setup = nil
    }

    private func enqueue(_ message: Data, _ continuation: CheckedContinuation<Void, Error>) {
        guard !isClosed, blockLength > 0 else {
            continuation.resume(throwing: VehicleError.notInRange)
            return
        }
        sendQueue.append(PendingSend(chunks: Framing.chunks(for: message, blockLength: blockLength), continuation: continuation))
        if sendQueue.count == 1 { writeNextChunk() }
    }

    /// Writes the head message's next chunk, or completes it once every chunk is acknowledged.
    private func writeNextChunk() {
        guard let head = sendQueue.first else { return }
        guard let chunk = head.chunks.first else {
            sendQueue.removeFirst().continuation.resume()
            writeNextChunk()
            return
        }
        guard let peripheral, let writeCharacteristic else { return }
        chunkSerial += 1
        let serial = chunkSerial
        peripheral.writeValue(chunk, for: writeCharacteristic, type: .withResponse)
        queue.asyncAfter(deadline: .now() + Self.chunkWriteTimeout.timeInterval) { [weak self] in
            guard let self, chunkSerial == serial, !sendQueue.isEmpty else { return }
            // A late acknowledgement would be credited to the wrong chunk, so the link is unusable.
            log.error("Chunk write timed out")
            tearDown(VehicleError.timeout)
        }
    }

    private var knownPeripheralKey: String { "teslakit.peripheral.\(VehicleLocalName.make(vin: vin))" }

    /// Connects straight to the remembered peripheral, if CoreBluetooth still knows it.
    private func connectToKnownPeripheral(_ central: CBCentralManager) -> Bool {
        guard let stored = Self.knownPeripherals.string(forKey: knownPeripheralKey),
              let id = UUID(uuidString: stored),
              let known = central.retrievePeripherals(withIdentifiers: [id]).first
        else { return false }
        log.info("Connecting to remembered vehicle")
        peripheral = known
        known.delegate = self
        central.connect(known)
        queue.asyncAfter(deadline: .now() + Self.knownPeripheralGrace.timeInterval) { [weak self] in
            guard let self, setup != nil, !isConnected, peripheral === known else { return }
            log.info("Remembered vehicle didn't answer, scanning")
            central.cancelPeripheralConnection(known)
            peripheral = nil
            central.scanForPeripherals(withServices: Self.scanServices)
        }
        return true
    }

    /// Ends the connection: fails setup and every pending send with `error`, and finishes `incoming`.
    private func tearDown(_ error: Error) {
        guard !isClosed else { return }
        log.info("Closing connection: \(String(describing: error), privacy: .public)")
        isClosed = true
        chunkSerial += 1
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        setup?.resume(throwing: error)
        setup = nil
        let pending = sendQueue
        sendQueue.removeAll()
        for send in pending { send.continuation.resume(throwing: error) }
        incomingContinuation.finish()
    }
}

extension BLETransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.info("Bluetooth state: \(central.state.name, privacy: .public)")
        switch central.state {
        case .poweredOn:
            guard setup != nil, peripheral == nil else { return }
            if connectToKnownPeripheral(central) { return }
            log.info("Scanning")
            central.scanForPeripherals(withServices: Self.scanServices)
        case .poweredOff, .resetting, .unsupported:
            tearDown(VehicleError.bluetoothOff)
        case .unauthorized:
            tearDown(VehicleError.bluetoothUnauthorized)
        default:
            break
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "-"
        guard self.peripheral == nil, Self.matches(advertisement: advertisementData, vin: vin) else {
            if name.count == 18, name.hasPrefix("S"), name.hasSuffix("C") { teslaNamesSeen += 1 }
            log.debug("Skipped \(name, privacy: .private) RSSI \(RSSI.intValue, privacy: .public)")
            return
        }
        log.info("Found \(name, privacy: .private) RSSI \(RSSI.intValue, privacy: .public), connecting")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        log.info("Connected, discovering services")
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return } // an abandoned remembered-peripheral attempt
        log.error("Failed to connect: \(String(describing: error), privacy: .public)")
        tearDown(VehicleError.notInRange)
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        guard peripheral === self.peripheral else { return } // an abandoned remembered-peripheral attempt
        log.info("Disconnected: \(String(describing: error), privacy: .public)")
        tearDown(VehicleError.notInRange)
    }
}

extension BLETransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            log.error("Vehicle service not found: \(String(describing: error), privacy: .public)")
            tearDown(error ?? VehicleError.notInRange)
            return
        }
        log.info("Discovering characteristics")
        peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: service)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        let characteristics = service.characteristics ?? []
        guard let write = characteristics.first(where: { $0.uuid == Self.writeUUID }),
              let notify = characteristics.first(where: { $0.uuid == Self.notifyUUID }) else {
            log.error("Vehicle characteristics not found: \(String(describing: error), privacy: .public)")
            tearDown(error ?? VehicleError.notInRange)
            return
        }
        writeCharacteristic = write
        // One ATT Write Request per chunk, as Go does: the `.withResponse` limit (512) would force long writes.
        blockLength = min(peripheral.maximumWriteValueLength(for: .withoutResponse), Framing.maxMessageLength)
        log.info("Block length \(self.blockLength, privacy: .public), subscribing")
        peripheral.setNotifyValue(true, for: notify)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard characteristic.uuid == Self.notifyUUID else { return }
        if let error {
            log.error("Subscribe failed: \(String(describing: error), privacy: .public)")
            tearDown(error)
        } else {
            log.info("Subscribed, ready")
            finishSetup()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.writeUUID, !sendQueue.isEmpty else { return }
        if let error {
            // The vehicle now holds a partial frame that would corrupt the next message.
            log.error("Chunk write failed: \(String(describing: error), privacy: .public)")
            tearDown(error)
            return
        }
        chunkSerial += 1
        sendQueue[0].chunks.removeFirst()
        writeNextChunk()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.notifyUUID, error == nil, let value = characteristic.value else { return }
        for message in reassembler.append(value, at: Date()) {
            incomingContinuation.yield(message)
        }
    }
}

private extension CBManagerState {
    var name: String {
        switch self {
        case .unknown: "unknown"
        case .resetting: "resetting"
        case .unsupported: "unsupported"
        case .unauthorized: "unauthorized"
        case .poweredOff: "poweredOff"
        case .poweredOn: "poweredOn"
        @unknown default: "rawValue \(rawValue)"
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
