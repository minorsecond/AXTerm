import Foundation
import CoreBluetooth

extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhX", $0) }.joined()
    }
}

class BLEController: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var peripheral: CBPeripheral?
    var txChar: CBCharacteristic?
    var rxChar: CBCharacteristic?
    
    let targetName = "TNC4 Mobilinkd"
    let serviceUUID = CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")
    let txUUID = CBUUID(string: "49535343-6DAA-4D02-ABF6-19569ACA69FE") // We write to this
    let rxUUID = CBUUID(string: "49535343-ACA3-481C-91EC-D85E28A60318") // We notify on this
    
    let txQueue = DispatchQueue(label: "txQueue")
    var hasTransmitted = false
    var receivedResponse = false
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func start() {
        print("Waiting for BLE manager to power on...")
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            print("Scanning for \(targetName)...")
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        } else {
            print("Bluetooth not available: \(central.state.rawValue)")
            exit(1)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if peripheral.name == targetName {
            print("Found \(targetName), connecting...")
            self.peripheral = peripheral
            centralManager.stopScan()
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected! Discovering services...")
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Error discovering services: \(error)")
            exit(1)
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            print("Service not found")
            exit(1)
        }
        print("Found Microchip Transparent UART service. Discovering characteristics...")
        peripheral.discoverCharacteristics([txUUID, rxUUID], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("Error discovering characteristics: \(error)")
            exit(1)
        }
        
        for char in service.characteristics ?? [] {
            if char.uuid == txUUID {
                txChar = char
                print("Found TX char (Write): \(char.uuid) - properties: \(char.properties.rawValue)")
            } else if char.uuid == rxUUID {
                rxChar = char
                print("Found RX char (Notify): \(char.uuid) - properties: \(char.properties.rawValue)")
                peripheral.setNotifyValue(true, for: char)
            }
        }
        
        if txChar != nil && rxChar != nil {
            print("Ready to transmit. Sending Test SABM frame in 2 seconds...")
            txQueue.asyncAfter(deadline: .now() + 2.0) {
                self.sendTestFrame()
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error enabling notifications: \(error)")
        } else {
            print("Notifications enabled for \(characteristic.uuid)")
        }
    }
    
    func sendTestFrame() {
        guard let peripheral = peripheral, let char = txChar else { return }
        
        // Exact frame reported in logs: C00096608AA09240EE96608AA092406E96608AA092406F3FC0
        let frameData = Data([0xC0, 0x00, 0x96, 0x60, 0x8A, 0xA0, 0x92, 0x40, 0xEE, 0x96, 0x60, 0x8A, 0xA0, 0x92, 0x40, 0x6E, 0x96, 0x60, 0x8A, 0xA0, 0x92, 0x40, 0x6F, 0x3F, 0xC0])
        
        let writeType: CBCharacteristicWriteType = .withoutResponse
        print("Sending SABM to K0EPI-7 (\(frameData.count) bytes) using writeType: withoutResponse to \(char.uuid)")
        
        peripheral.writeValue(frameData, for: char, type: writeType)
        hasTransmitted = true
        print("Write executed. Listening for UA response...")
        
        // Let it listen for 10 seconds after transmission.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            if !self.receivedResponse {
                print("TIMEOUT: Did not receive an answer from K0EPI-7. Transmission might have failed.")
            } else {
                print("SUCCESS: Connection test passed.")
            }
            exit(0)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Write failed: \(error)")
        } else {
            print("Write acknowledged (This should not fire for withoutResponse)!")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        print("RX [\(data.count) bytes]: \(data.hexEncodedString())")
        
        if data.count > 5 {
            // A non-empty packet received.
            receivedResponse = true
        }
    }
}

let controller = BLEController()
controller.start()
RunLoop.main.run()
