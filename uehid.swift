// uehid — talk to a UE BOOM 2 over USB (vendor HID interface, usage page 0xFFA0).
//
// Reverse engineered from Logitech "UE Speaker Update Assistant" 1.4.18:
//   output report (no report ID), 127 bytes: [cmd, p1, p2, 0...]
//   0x56        -> get device info (read only)
//   0x51 0x07   -> reboot into boot mode 7 = USB DFU mode (device re-enumerates as PID 0x0a5f)
//   0x51 0x01   -> boot mode 1 (normal)  [as used by the updater after DFU]
// Normal-mode PID 0x0a5e (UE BOOM 2 "Maximus"), DFU-mode PID 0x0a5f.
//
// Build: swiftc -O -o uehid uehid.swift -framework IOKit
// Usage: uehid info                  send 0x56 and print the reply
//        uehid enter-dfu             send 0x51 0x07, then wait for the DFU device
//        uehid send "56"             send any command bytes (hex), print replies
//        uehid wait-dfu              wait for 046d:0a5f to appear

import Foundation
import IOKit
import IOKit.hid
import IOKit.usb

let VID = 0x046d, PID_RUN = 0x0a5e, PID_DFU = 0x0a5f

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func ascii(_ b: [UInt8]) -> String { String(b.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "." }) }
func spin(_ s: Double, until: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(s)
    while !until() && Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
}

var replies = [[UInt8]]()
let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)

var hidManager: IOHIDManager?   // must outlive the device, or the device gets closed

func openSpeaker() -> IOHIDDevice? {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID_RUN] as CFDictionary)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    hidManager = mgr
    guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = set.first else { return nil }
    if set.count > 1 { print("note: \(set.count) speakers on USB, using the first one") }
    let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    guard r == kIOReturnSuccess else { print("cannot open HID device: \(String(UInt32(bitPattern: r), radix: 16))"); return nil }
    IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    IOHIDDeviceRegisterInputReportCallback(dev, inBuf, 256, { _, _, _, _, _, report, len in
        replies.append(Array(UnsafeBufferPointer(start: report, count: len)))
    }, nil)
    return dev
}

func sendCmd(_ dev: IOHIDDevice, _ bytes: [UInt8]) -> Bool {
    var report = [UInt8](repeating: 0, count: 127)
    for (i, b) in bytes.prefix(127).enumerated() { report[i] = b }
    let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, report, report.count)
    if r != kIOReturnSuccess { print("SetReport failed: 0x\(String(UInt32(bitPattern: r), radix: 16))"); return false }
    print("→ \(hex(bytes))")
    return true
}

func usbPresent(_ pid: Int) -> Bool {
    let m = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
    m["idVendor"] = VID; m["idProduct"] = pid
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) == KERN_SUCCESS else { return false }
    defer { IOObjectRelease(it) }
    let s = IOIteratorNext(it); if s != 0 { IOObjectRelease(s); return true }
    return false
}

func dumpReplies() {
    if replies.isEmpty { print("(no reply)") }
    for r in replies {
        let trimmed = Array(r.prefix(through: r.lastIndex(where: { $0 != 0 }) ?? 0))
        print("← \(hex(trimmed))   \(ascii(trimmed))")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "info", "send":
    var bytes: [UInt8] = [0x56]
    if args.first == "send" {
        guard args.count > 1 else { print("usage: uehid send \"56\""); exit(2) }
        let h = args[1].filter { $0.isHexDigit }
        bytes = stride(from: 0, to: h.count - 1, by: 2).map {
            UInt8(h[h.index(h.startIndex, offsetBy: $0)..<h.index(h.startIndex, offsetBy: $0 + 2)], radix: 16)!
        }
    }
    guard let dev = openSpeaker() else { print("No UE BOOM 2 (046d:0a5e) on USB."); exit(1) }
    guard sendCmd(dev, bytes) else { exit(1) }
    spin(2)
    dumpReplies()
case "enter-dfu":
    if usbPresent(PID_DFU) { print("Already in DFU mode (046d:0a5f)."); exit(0) }
    guard let dev = openSpeaker() else { print("No UE BOOM 2 (046d:0a5e) on USB."); exit(1) }
    guard sendCmd(dev, [0x51, 0x07]) else { exit(1) }
    spin(2)
    _ = sendCmd(dev, [0x59])   // restart so the boot mode takes effect
    print("Waiting for DFU device 046d:0a5f …")
    spin(Double(args.count > 1 ? args[1] : "20") ?? 20) { usbPresent(PID_DFU) }
    dumpReplies()
    if usbPresent(PID_DFU) { print("✓ Speaker is in DFU mode."); exit(0) }
    print("✗ DFU device did not appear in time."); exit(1)
case "wait-dfu":
    spin(Double(args.count > 1 ? args[1] : "30") ?? 30) { usbPresent(PID_DFU) }
    print(usbPresent(PID_DFU) ? "DFU device present" : "no DFU device"); exit(usbPresent(PID_DFU) ? 0 : 1)
default:
    print("usage: uehid info | enter-dfu | wait-dfu [secs] | send HEX")
    exit(2)
}
