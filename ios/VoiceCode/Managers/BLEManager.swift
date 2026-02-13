// BLEManager.swift
// BLE spike: CoreBluetooth GATT between iPhone (peripheral) and Mac (central)
// Disposable — will be reverted after proving BLE works on corporate Mac.

import Foundation
import CoreBluetooth
import os

// MARK: - Shared Constants

enum BLEConstants {
    static let serviceUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
    static let characteristicUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567891")
    static let localName = "VoiceCode"
}

enum BLEConnectionState: String {
    case idle
    case scanning
    case advertising
    case connecting
    case connected
    case disconnected
}

private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "BLE")

// MARK: - BLEManager

class BLEManager: NSObject, ObservableObject {
    @Published var connectionState: BLEConnectionState = .idle
    @Published var connectedPeerName: String?
    @Published var lastReceivedMessage: String?
    @Published var lastSentMessage: String?

    #if os(iOS)
    private var peripheralManager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    private var subscribedCentral: CBCentral?
    #else
    private var centralManager: CBCentralManager?
    private var discoveredPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    #endif

    override init() {
        super.init()
    }

    // MARK: - Public API

    #if os(iOS)
    func startAdvertising() {
        guard peripheralManager == nil else { return }
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        // Advertising deferred until peripheralManagerDidUpdateState reports .poweredOn
    }

    func stopAdvertising() {
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        peripheralManager = nil
        subscribedCentral = nil
        characteristic = nil
        connectionState = .idle
        connectedPeerName = nil
        logger.info("Stopped advertising")
    }

    func sendMessage(_ text: String) {
        guard let characteristic = characteristic,
              let central = subscribedCentral,
              let data = text.data(using: .utf8) else {
            logger.warning("Cannot send: no subscribed central or characteristic")
            return
        }
        let sent = peripheralManager?.updateValue(data, for: characteristic, onSubscribedCentrals: [central])
        if sent == true {
            lastSentMessage = text
            logger.info("Sent message: \(text)")
        } else {
            logger.warning("updateValue returned false (transmit queue full)")
        }
    }
    #else
    func startScanning() {
        guard centralManager == nil else { return }
        centralManager = CBCentralManager(delegate: self, queue: nil)
        // Scanning deferred until centralManagerDidUpdateState reports .poweredOn
    }

    func disconnect() {
        if let peripheral = discoveredPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        centralManager?.stopScan()
        centralManager = nil
        discoveredPeripheral = nil
        writeCharacteristic = nil
        connectionState = .idle
        connectedPeerName = nil
        logger.info("Disconnected")
    }

    func sendMessage(_ text: String) {
        guard let peripheral = discoveredPeripheral,
              let characteristic = writeCharacteristic,
              let data = text.data(using: .utf8) else {
            logger.warning("Cannot send: no connected peripheral or characteristic")
            return
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        lastSentMessage = text
        logger.info("Sent message: \(text)")
    }
    #endif
}

// MARK: - iOS Peripheral Manager

#if os(iOS)
extension BLEManager: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            logger.info("Peripheral powered on, setting up service")
            setupService()
        case .poweredOff:
            logger.warning("Bluetooth powered off")
            connectionState = .disconnected
        case .unauthorized:
            logger.error("Bluetooth unauthorized")
            connectionState = .disconnected
        case .unsupported:
            logger.error("Bluetooth unsupported on this device")
            connectionState = .disconnected
        default:
            logger.info("Peripheral state: \(String(describing: peripheral.state.rawValue))")
        }
    }

    private func setupService() {
        let characteristic = CBMutableCharacteristic(
            type: BLEConstants.characteristicUUID,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )
        self.characteristic = characteristic

        let service = CBMutableService(type: BLEConstants.serviceUUID, primary: true)
        service.characteristics = [characteristic]

        peripheralManager?.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            logger.error("Failed to add service: \(error.localizedDescription)")
            return
        }
        logger.info("Service added, starting advertising")
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: BLEConstants.localName
        ])
        connectionState = .advertising
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            logger.error("Failed to start advertising: \(error.localizedDescription)")
            connectionState = .disconnected
            return
        }
        logger.info("Advertising started")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        logger.info("Central subscribed, max write length: \(central.maximumUpdateValueLength)")
        subscribedCentral = central
        connectionState = .connected
        connectedPeerName = "Central"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        logger.info("Central unsubscribed")
        subscribedCentral = nil
        connectionState = .advertising
        connectedPeerName = nil
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if request.characteristic.uuid == BLEConstants.characteristicUUID {
            if let lastMessage = lastSentMessage, let data = lastMessage.data(using: .utf8) {
                request.value = data.subdata(in: request.offset..<data.count)
            } else {
                request.value = Data()
            }
            peripheral.respond(to: request, withResult: .success)
        } else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == BLEConstants.characteristicUUID,
               let data = request.value,
               let text = String(data: data, encoding: .utf8) {
                logger.info("Received write: \(text)")
                DispatchQueue.main.async {
                    self.lastReceivedMessage = text
                }
            }
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }
}
#endif

// MARK: - macOS Central Manager

#if os(macOS)
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            logger.info("Central powered on, starting scan")
            central.scanForPeripherals(
                withServices: [BLEConstants.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            connectionState = .scanning
        case .poweredOff:
            logger.warning("Bluetooth powered off")
            connectionState = .disconnected
        case .unauthorized:
            logger.error("Bluetooth unauthorized")
            connectionState = .disconnected
        case .unsupported:
            logger.error("Bluetooth unsupported on this device")
            connectionState = .disconnected
        default:
            logger.info("Central state: \(String(describing: central.state.rawValue))")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
        logger.info("Discovered peripheral: \(name) RSSI: \(RSSI)")

        discoveredPeripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        connectionState = .connecting
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("Connected to peripheral: \(peripheral.name ?? "Unknown")")
        peripheral.discoverServices([BLEConstants.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.error("Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        connectionState = .disconnected
        discoveredPeripheral = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info("Disconnected from peripheral: \(peripheral.name ?? "Unknown")")
        connectionState = .disconnected
        connectedPeerName = nil
        discoveredPeripheral = nil
        writeCharacteristic = nil
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logger.error("Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == BLEConstants.serviceUUID }) else {
            logger.warning("VoiceCode service not found")
            return
        }
        logger.info("Discovered service, discovering characteristics")
        peripheral.discoverCharacteristics([BLEConstants.characteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            logger.error("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == BLEConstants.characteristicUUID }) else {
            logger.warning("VoiceCode characteristic not found")
            return
        }
        writeCharacteristic = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
        connectionState = .connected
        connectedPeerName = peripheral.name ?? "iPhone"
        let maxWrite = peripheral.maximumWriteValueLength(for: .withResponse)
        logger.info("Ready. Max write length: \(maxWrite)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logger.error("Characteristic update error: \(error.localizedDescription)")
            return
        }
        guard characteristic.uuid == BLEConstants.characteristicUUID,
              let data = characteristic.value,
              let text = String(data: data, encoding: .utf8) else { return }
        logger.info("Received notification: \(text)")
        DispatchQueue.main.async {
            self.lastReceivedMessage = text
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logger.error("Write failed: \(error.localizedDescription)")
        }
    }
}
#endif
