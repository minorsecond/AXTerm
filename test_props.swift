import Foundation
import CoreBluetooth

let props = CBCharacteristicProperties(rawValue: 12)
print("Write: \(props.contains(.write))")
print("WriteNR: \(props.contains(.writeWithoutResponse))")
