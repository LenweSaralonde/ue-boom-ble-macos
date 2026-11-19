import Foundation
import CoreBluetooth
final class S: NSObject, CBCentralManagerDelegate {
  var m: CBCentralManager!; var seen = [UUID: String]()
  override init() { super.init(); m = CBCentralManager(delegate: self, queue: nil) }
  func centralManagerDidUpdateState(_ c: CBCentralManager) {
    if c.state == .poweredOn { c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]) }
    else { print("state \(c.state.rawValue)") }
  }
  func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
    let n = (a[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "-"
    let mfg = (a[CBAdvertisementDataManufacturerDataKey] as? Data).map { $0.map { String(format: "%02x", $0) }.joined() } ?? ""
    if seen[p.identifier] == nil { seen[p.identifier] = n; print("\(n)\trssi=\(rssi)\tmfg=\(mfg)") }
  }
}
let s = S(); RunLoop.main.run(until: Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "12") ?? 12))
print("--- \(s.seen.count) devices")
