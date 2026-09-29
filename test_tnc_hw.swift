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
    let combinedUUID = CBUUID(string: "49535343-ACA3-481C-91EC-D85E28A60318") 
    let txUUID = CBUUID(string: "49535343-6DAA-4D02-ABF6-19569ACA69FE") // We write to this
    
    let txQueue = DispatchQueue(label: "txQueue")
    
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
        peripheral.discoverCharacteristics([txUUID, combinedUUID], for: service)
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
            } else if char.uuid == combinedUUID {
                rxChar = char
                print("Found RX char (Notify): \(char.uuid) - properties: \(char.properties.rawValue)")
                peripheral.setNotifyValue(true, for: char)
            }
        }
        
        if txChar != nil && rxChar != nil {
            print("Ready. Polling Battery Level...")
            txQueue.asyncAfter(deadline: .now() + 1.0) {
                // FEND | CMD_HW | GET_BATTERY | FEND
                let battReq = Data([0xC0, 0x06, 0x06, 0xC0])
                self.peripheral?.writeValue(battReq, for: self.txChar!, type: .withoutResponse)
                
                print("Polling Input Levels...")
                let volReq = Data([0xC0, 0x06, 0x04, 0xC0])
                self.peripheral?.writeValue(volReq, for: self.txChar!, type: .withoutResponse)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                print("Test finished.")
                exit(0)
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
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        print("RX [\(data.count) bytes]: \(data.hexEncodedString())")
        
        if data.count >= 4 && data[0] == 0xC0 && data[1] == 0x06 {
            if data[2] == 0x06 {
                let mv = (Int(data[3]) << 8) + Int(data[4])
                print("-> Battery Level: \(mv) mV")
            } else if data[2] == 0x04 && data.count >= 10 {
                let vpp  = UInt16(data[3]) << 8 | UInt16(data[4])
                print("-> Audio Vpp: \(vpp)")
            }
        }
    }
}

let controller = BLEController()
controller.start()
RunLoop.main.run()
