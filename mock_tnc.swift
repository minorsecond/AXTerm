import CoreBluetooth

class MockPeripheral: NSObject, CBPeripheralManagerDelegate {
    var pm: CBPeripheralManager!
    
    let serviceUUID = CBUUID(string: "00000001-BA2A-46C9-AE49-01B0961F68BB")
    let txUUID = CBUUID(string: "00000002-BA2A-46C9-AE49-01B0961F68BB") // Write property
    let rxUUID = CBUUID(string: "00000003-BA2A-46C9-AE49-01B0961F68BB") // Notify property
    
    var txChar: CBMutableCharacteristic!
    var rxChar: CBMutableCharacteristic!
    
    override init() {
        super.init()
        pm = CBPeripheralManager(delegate: self, queue: nil)
    }
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            print("Starting Mock TNC4 on Mobilinkd Custom Service...")
            txChar = CBMutableCharacteristic(type: txUUID, properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
            rxChar = CBMutableCharacteristic(type: rxUUID, properties: [.notify, .read], value: nil, permissions: [.readable])
            
            let service = CBMutableService(type: serviceUUID, primary: true)
            service.characteristics = [txChar, rxChar]
            
            pm.add(service)
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        print("Service added. Advertising as 'TNC4 Mobilinkd'...")
        pm.startAdvertising([
            CBAdvertisementDataLocalNameKey: "TNC4 Mobilinkd",
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID]
        ])
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        print("Advertising started. Connect with QTH.app now!")
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for req in requests {
            if let data = req.value {
                let hex = data.map { String(format: "%02hhX", $0) }.joined()
                print("MOCK TNC RECEIVED WRITE to \(req.characteristic.uuid): \(hex)")
            }
            if req.characteristic.properties.contains(.write) {
                pm.respond(to: req, withResult: .success)
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        print("QTH.app subscribed to \(characteristic.uuid)")
    }
}

let mock = MockPeripheral()
RunLoop.main.run()
