import AppKit
import Darwin
import Foundation
import GameController
import IOKit
import IOKit.hid

// This diagnostic is often launched with stdout redirected to a file.  Keep
// each observation immediately readable instead of waiting for a full buffer.
setbuf(stdout, nil)

// GCController daemon on macOS only delivers HID devices to AppKit-backed processes
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu-bar-less app

print("=== GCTest: Monitoring GameController Framework ===")
print("macOS version: \(ProcessInfo.processInfo.operatingSystemVersionString)")

if #available(macOS 11.3, *) {
    GCController.shouldMonitorBackgroundEvents = true
}

func scanIOHIDGamepads() {
    print("\n--- IOHIDManager scan for GD:Gamepad/Joystick devices ---")
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [[String: Any]] = [
        [kIOHIDDeviceUsagePageKey as String: 0x01, kIOHIDDeviceUsageKey as String: 0x05],
        [kIOHIDDeviceUsagePageKey as String: 0x01, kIOHIDDeviceUsageKey as String: 0x04],
    ]
    IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
        print("  (no HID gamepad devices found)"); return
    }
    for device in deviceSet {
        func prop(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
        let vid = prop(kIOHIDVendorIDKey as String) as? Int ?? 0
        let pid = prop(kIOHIDProductIDKey as String) as? Int ?? 0
        let name = prop(kIOHIDProductKey as String) as? String ?? "?"
        let transport = prop(kIOHIDTransportKey as String) as? String ?? "?"
        print(String(format: "  HID: %@ (VID:0x%04X PID:0x%04X transport:%@)", name, vid, pid, transport))
        if #available(macOS 13, *) {
            print("    GCController.supportsHIDDevice: \(GCController.supportsHIDDevice(device))")
        }
    }
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
}

func logController(_ c: GCController, prefix: String = "") {
    print("\(prefix)Controller: \"\(c.vendorName ?? "Unknown")\" | Category: \(c.productCategory)")
    if let extended = c.extendedGamepad {
        print("\(prefix)  Profile: ExtendedGamepad ✓")
        extended.valueChangedHandler = { gamepad, element in
            if element === gamepad.leftThumbstick {
                print(String(format: "  [LS] x:%+.2f y:%+.2f",
                    gamepad.leftThumbstick.xAxis.value, gamepad.leftThumbstick.yAxis.value))
            } else if element === gamepad.rightThumbstick {
                print(String(format: "  [RS] x:%+.2f y:%+.2f",
                    gamepad.rightThumbstick.xAxis.value, gamepad.rightThumbstick.yAxis.value))
            } else if element === gamepad.dpad {
                print(String(format: "  [DPAD] x:%+.2f y:%+.2f",
                    gamepad.dpad.xAxis.value, gamepad.dpad.yAxis.value))
            } else if let btn = element as? GCControllerButtonInput, btn.isPressed {
                print("  [BTN] \(element.localizedName ?? "?")")
            }
        }
    } else {
        print("\(prefix)  Profile: \(c.microGamepad != nil ? "MicroGamepad" : "none/generic")")
        let profile = c.physicalInputProfile
        print("\(prefix)  Elements (\(profile.elements.count)):")
        for (key, el) in profile.elements.prefix(30) {
            print("\(prefix)    \(key): \(type(of: el))")
        }
    }
}

func printControllers(label: String) {
    let cs = GCController.controllers()
    print("\n[\(label)] GCController.controllers() = \(cs.count)")
    for (i, c) in cs.enumerated() { logController(c, prefix: "  [\(i)] ") }
}

scanIOHIDGamepads()

NotificationCenter.default.addObserver(
    forName: .GCControllerDidConnect, object: nil, queue: .main
) { notification in
    guard let c = notification.object as? GCController else { return }
    print("\n>>> GCController CONNECTED:"); logController(c, prefix: ">>> ")
}
NotificationCenter.default.addObserver(
    forName: .GCControllerDidDisconnect, object: nil, queue: .main
) { notification in
    guard let c = notification.object as? GCController else { return }
    print("\n<<< GCController DISCONNECTED: \"\(c.vendorName ?? "Unknown")\"")
}

// Deferred checks
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { printControllers(label: "t+0.5s") }
DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { printControllers(label: "t+2.0s") }
Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in printControllers(label: "poll") }

GCController.startWirelessControllerDiscovery { }

print("GCTest running — wiggle sticks/buttons. Ctrl-C to exit.")
app.run()  // NSApplication.run() instead of RunLoop.main.run()
