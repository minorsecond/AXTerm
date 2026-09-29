import Foundation
import CoreBluetooth

extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhX", $0) }.joined()
    }
}

class BLETrafficSniffer: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var peripheral: CBPeripheral?
    
    let targetName = "TNC4 Mobilinkd"
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func start() {
        print("Waiting for BLE manager to power on...")
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            print("Listening for \(targetName). Please connect QTH.app to it now.")
            // Try to retrieve it if it's already connected by macOS/QTH
            let connected = centralManager.retrieveConnectedPeripherals(withServices: [CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")])
            if let target = connected.first(where: { $0.name == targetName }) {
                print("Found already connected TNC4. Attaching to it...")
                self.peripheral = target
                centralManager.connect(target, options: nil)
            } else {
                centralManager.scanForPeripherals(withServices: nil, options: nil)
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if peripheral.name == targetName {
            print("Discovered \(targetName). Attaching to it while QTH.app uses it...")
            self.peripheral = peripheral
            centralManager.stopScan()
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Attached! Discovering services...")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            print("Discovered Service: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] {
            print("Discovered Characteristic: \(char.uuid) with properties: \(char.properties.rawValue)")
            if char.properties.contains(.notify) || char.properties.contains(.indicate) {
                print("-> Subscribing to notifications for \(char.uuid)")
                peripheral.setNotifyValue(true, for: char)
            }
            if char.properties.contains(.read) {
                peripheral.readValue(for: char)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        print("INTERCEPT [\(characteristic.uuid)] (len=\(data.count)): \(data.hexEncodedString())")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        print("INTERCEPT WRITE to [\(characteristic.uuid)]")
    }
}

let sniffer = BLETrafficSniffer()
sniffer.start()
RunLoop.main.run()
