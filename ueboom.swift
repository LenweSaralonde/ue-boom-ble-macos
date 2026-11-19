// ueboom — manage the BLE radio of UE BOOM 2 speakers from macOS.
//
// Run with no arguments for an interactive menu. It finds every paired "BOOM"
// speaker, checks whether it is powered on, scans BLE adverts to see which
// ones are still advertising while off (battery drain), and lets you disable or
// enable BLE on one speaker or all of them.
//
// Protocol (community reverse engineering, see README.md):
//   SPP / RFCOMM channel 1, frame = [len][payload]
//   03 01 B9 00 -> BLE off while the speaker is off (persistent)   reply 05 00 00 01 B9 00
//   03 01 B9 01 -> BLE always on (factory behaviour)
//
// Build:  swiftc -O -o ueboom ueboom.swift -framework IOBluetooth -framework CoreBluetooth
// CLI:    ueboom                      interactive menu
//         ueboom status               table only
//         ueboom ble-off [ADDR|all]   ueboom ble-on [ADDR|all]
//         ueboom raw ADDR "02 01 6B"  [--channel N]

import Foundation
import IOBluetooth
import CoreBluetooth

// MARK: - Terminal helpers

let tty = isatty(STDOUT_FILENO) != 0
func c(_ code: String, _ s: String) -> String { tty ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
func bold(_ s: String) -> String { c("1", s) }
func dim(_ s: String) -> String { c("2", s) }
func red(_ s: String) -> String { c("31", s) }
func green(_ s: String) -> String { c("32", s) }
func yellow(_ s: String) -> String { c("33", s) }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func ioerr(_ r: IOReturn) -> String { "0x" + String(UInt32(bitPattern: r), radix: 16) }

func spin(_ secs: Double, until: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(secs)
    while !until() && Date() < end {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

func parseHex(_ s: String) -> [UInt8]? {
    let clean = s.replacingOccurrences(of: "0x", with: "").filter { $0.isHexDigit }
    guard clean.count % 2 == 0, !clean.isEmpty else { return nil }
    var out = [UInt8](); var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        out.append(UInt8(clean[i..<j], radix: 16)!); i = j
    }
    return out
}

// MARK: - Remembered BLE setting per speaker
// The speaker has no known "get BLE state" command, so we remember what we sent
// and what we observed (an OFF speaker that advertises = setting on).

struct Known: Codable { var ble: String; var updated: Date; var source: String }

final class StateStore {
    let url: URL
    var data: [String: Known] = [:]
    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ueboom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("state.json")
        if let d = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            data = (try? dec.decode([String: Known].self, from: d)) ?? [:]
        }
    }
    func set(_ addr: String, ble: Bool, source: String) {
        data[addr] = Known(ble: ble ? "on" : "off", updated: Date(), source: source)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        try? enc.encode(data).write(to: url)
    }
}
let store = StateStore()

// MARK: - BLE scanner (runs on its own queue so it keeps scanning while we page speakers)

final class BLEScanner: NSObject, CBCentralManagerDelegate {
    private let q = DispatchQueue(label: "ueboom.ble")
    private var mgr: CBCentralManager!
    private var adverts = [String]()          // lowercase hex of manufacturer data
    private var stateKnown = false
    private(set) var available = false

    override init() {
        super.init()
        mgr = CBCentralManager(delegate: self, queue: q)
    }
    func centralManagerDidUpdateState(_ m: CBCentralManager) {
        stateKnown = true
        available = m.state == .poweredOn
        if available { m.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) }
    }
    func centralManager(_ m: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData a: [String: Any], rssi: NSNumber) {
        guard let d = a[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        adverts.append(d.map { String(format: "%02x", $0) }.joined())
    }
    func waitReady() { spin(3) { q.sync { stateKnown } } }
    func reset() { q.sync { adverts.removeAll() } }
    /// UE BOOM adverts embed the speaker's own Bluetooth address.
    func advertising(_ addr: String) -> Bool {
        let key = addr.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").lowercased()
        return q.sync { adverts.contains { $0.contains(key) } }
    }
}
let ble = BLEScanner()

// MARK: - Speakers

enum Power { case on, off }

struct Speaker {
    let dev: IOBluetoothDevice
    var name: String { dev.name ?? "?" }
    var addr: String { (dev.addressString ?? "?").lowercased() }
    var power: Power = .off
    var advertising = false
}

func pairedBooms() -> [IOBluetoothDevice] {
    let all = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    return all.filter { ($0.name ?? "").uppercased().contains("BOOM") }
        .sorted { ($0.name ?? "") < ($1.name ?? "") }
}

/// Page the speaker briefly to find out whether it is powered on.
func isPoweredOn(_ d: IOBluetoothDevice) -> Bool {
    if d.isConnected() { return true }
    // 4800 slots * 0.625 ms = 3 s page timeout
    let r = d.openConnection(nil, withPageTimeout: 4800, authenticationRequired: false)
    if r == kIOReturnSuccess { d.closeConnection(); return true }
    return false
}

func survey(scanSeconds: Double = 6) -> [Speaker] {
    let devs = pairedBooms()
    ble.waitReady()
    ble.reset()
    let start = Date()
    print(dim("Scanning BLE and checking \(devs.count) paired speaker(s)…"))
    var out = devs.map { Speaker(dev: $0) }
    for i in out.indices {
        out[i].power = isPoweredOn(out[i].dev) ? .on : .off
    }
    let left = scanSeconds - Date().timeIntervalSince(start)
    if left > 0 { spin(left) }
    for i in out.indices {
        out[i].advertising = ble.advertising(out[i].addr)
        // Learn from observation: an OFF speaker's BLE behaviour reveals the setting.
        if out[i].power == .off && ble.available {
            store.set(out[i].addr, ble: out[i].advertising, source: "observed")
        }
    }
    return out
}

func statusText(_ s: Speaker) -> String {
    if s.power == .off {
        if !ble.available { return yellow("unknown (BLE scan unavailable)") }
        return s.advertising ? red("BLE ON while off — draining battery") : green("BLE off while off ✓")
    }
    if let k = store.data[s.addr] {
        let when = DateFormatter.localizedString(from: k.updated, dateStyle: .short, timeStyle: .none)
        return k.ble == "off" ? green("set to off-when-off ✓") + dim(" (\(k.source) \(when))")
                              : red("always on") + dim(" (\(k.source) \(when))")
    }
    return yellow("unknown") + dim(" (turn off & rescan, or apply a setting)")
}

func printTable(_ list: [Speaker]) {
    if list.isEmpty {
        print(yellow("No paired speaker with \"BOOM\" in its name. Pair your speakers in System Settings → Bluetooth."))
        return
    }
    print()
    print(bold("  #  " + pad("Speaker", 20) + pad("Address", 20) + pad("Power", 7) + "BLE"))
    for (i, s) in list.enumerated() {
        let pw = s.power == .on ? green(pad("ON", 7)) : dim(pad("off", 7))
        print("  \(i + 1)  " + pad(s.name, 20) + pad(s.addr, 20) + pw + statusText(s))
    }
    print()
}

// MARK: - SPP

final class Link: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var rx = [UInt8](); var closed = false
    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data p: UnsafeMutableRawPointer!, length: Int) {
        rx += Array(UnsafeRawBufferPointer(start: p, count: length))
    }
    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) { closed = true }
}

func rfcommChannelID(_ dev: IOBluetoothDevice, forced: UInt8?) -> UInt8 {
    if let f = forced { return f }
    if let rec = dev.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1101)) {
        var id: BluetoothRFCOMMChannelID = 0
        if rec.getRFCOMMChannelID(&id) == kIOReturnSuccess, id != 0 { return id }
    }
    return 1   // UE BOOM 2 uses channel 1
}

/// Sends a frame; returns the reply bytes (possibly empty) or nil on failure.
func send(_ frame: [UInt8], to dev: IOBluetoothDevice, forced: UInt8? = nil, quiet: Bool = false) -> [UInt8]? {
    let label = dev.name ?? dev.addressString ?? "?"
    let wasConnected = dev.isConnected()
    if !wasConnected {
        let r = dev.openConnection(nil, withPageTimeout: 8000, authenticationRequired: false)
        if r != kIOReturnSuccess {
            print(red("✗ \(label): not reachable (\(ioerr(r))). Turn it on and keep it in range."))
            return nil
        }
    }
    defer { if !wasConnected { dev.closeConnection() } }
    let id = rfcommChannelID(dev, forced: forced)
    let link = Link()
    var ch: IOBluetoothRFCOMMChannel?
    let o = dev.openRFCOMMChannelSync(&ch, withChannelID: id, delegate: link)
    guard o == kIOReturnSuccess, let channel = ch else {
        print(red("✗ \(label): could not open the control channel (\(ioerr(o)))."))
        print(dim("  Tip: disconnect the speaker from your phone and try again."))
        return nil
    }
    defer { channel.close() }
    var buf = frame
    let w = buf.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
    guard w == kIOReturnSuccess else { print(red("✗ \(label): write failed (\(ioerr(w)))")); return nil }
    spin(1.5) { link.closed || !link.rx.isEmpty }
    spin(0.2)
    if !quiet { print(dim("  sent \(hex(frame)) on ch \(id)" + (link.rx.isEmpty ? "" : ", reply \(hex(link.rx))"))) }
    return link.rx
}

func setBLE(_ s: Speaker, on: Bool) -> Bool {
    let frame: [UInt8] = [0x03, 0x01, 0xB9, on ? 0x01 : 0x00]
    guard let reply = send(frame, to: s.dev) else { return false }
    let ack: [UInt8] = [0x05, 0x00, 0x00, 0x01, 0xB9, on ? 0x01 : 0x00]
    store.set(s.addr, ble: on, source: "set")
    if reply == ack {
        print(green("✓ \(s.name): BLE " + (on ? "always on (factory behaviour)" : "off while the speaker is off")))
    } else {
        print(yellow("? \(s.name): command sent, unexpected reply \(reply.isEmpty ? "(none)" : hex(reply))"))
    }
    return true
}

/// Apply to a list; speakers that are off cannot receive commands.
func apply(_ list: [Speaker], on: Bool) {
    for s in list {
        if s.power == .off {
            print(yellow("• \(s.name) is off — turn it on, then rescan (r) and try again."))
            continue
        }
        _ = setBLE(s, on: on)
    }
    if !on, list.contains(where: { $0.power == .on }) {
        print(dim("  Note: BLE keeps advertising while a speaker is on; it goes quiet once it is switched off."))
    }
}

// MARK: - Interactive menu

func prompt(_ p: String) -> String? {
    print(p, terminator: ""); fflush(stdout)
    return readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
}

func interactive() {
    print(bold("UE BOOM — BLE manager"))
    var list = survey()
    while true {
        printTable(list)
        print("  " + bold("1-\(max(list.count, 1))") + " choose a speaker   "
              + bold("d") + " disable BLE (all ON)   " + bold("e") + " enable BLE (all ON)   "
              + bold("r") + " rescan   " + bold("q") + " quit")
        guard let a = prompt("> ") else { return }
        switch a {
        case "q", "quit", "exit": return
        case "r", "": list = survey()
        case "d": apply(list, on: false); list = survey()
        case "e":
            if prompt("Re-enable BLE on all ON speakers (battery drain returns)? [y/N] ") == "y" {
                apply(list, on: true); list = survey()
            }
        default:
            guard let n = Int(a), n >= 1, n <= list.count else { print(yellow("Unknown choice.")); continue }
            let s = list[n - 1]
            print("\n" + bold(s.name) + "  " + dim(s.addr) + "  " + statusText(s))
            if s.power == .off {
                print(yellow("It is off. Turn it on, then rescan (r) to change its setting."))
                continue
            }
            switch prompt("  d disable BLE   e enable BLE   b back > ") {
            case "d": _ = setBLE(s, on: false); list = survey()
            case "e": _ = setBLE(s, on: true); list = survey()
            default: break
            }
        }
    }
}

// MARK: - CLI

var args = Array(CommandLine.arguments.dropFirst())
var forced: UInt8? = nil
if let i = args.firstIndex(of: "--channel"), i + 1 < args.count {
    forced = UInt8(args[i + 1]); args.removeSubrange(i...(i + 1))
}

func target(_ arg: String?) -> [Speaker] {
    let all = survey(scanSeconds: 0.5)
    if arg == nil || arg == "all" { return all }
    let a = arg!.replacingOccurrences(of: ":", with: "-").lowercased()
    return all.filter { $0.addr == a || $0.name.lowercased().contains(a) }
}

switch args.first {
case nil, "menu":
    interactive()
case "status", "list":
    printTable(survey())
case "ble-off", "ble-on":
    let t = target(args.count > 1 ? args[1] : nil)
    if t.isEmpty { print("No matching speaker. Run `ueboom status`."); exit(1) }
    apply(t, on: args[0] == "ble-on")
case "raw":
    guard args.count >= 3, let frame = parseHex(args[2]), let s = target(args[1]).first else {
        print("usage: ueboom raw ADDR|NAME \"03 01 B9 00\""); exit(2)
    }
    exit(send(frame, to: s.dev, forced: forced) == nil ? 1 : 0)
default:
    print("usage: ueboom [menu | status | ble-off [ADDR|NAME|all] | ble-on [ADDR|NAME|all] | raw ADDR \"HEX\"] [--channel N]")
    exit(2)
}
