import Foundation
import Darwin
import AppKit
import IOKit.hid
import IOKit.hidsystem

// The launcher redirects this daemon's output to /tmp/arestime.log.  Disable
// buffering so connection and permission failures are immediately diagnosable.
setbuf(stdout, nil)
setbuf(stderr, nil)

// =============================================================================
// AresTranslator
//
// Single-purpose, single-device HID translation layer:
//   CosmicByte Ares (Direct Input / red mode) -> synthetic HID gamepad
//   that Apple's GameController framework (GCController) can pick up.
// =============================================================================

// ----- Config -----------------------------------------------------------

let ARES_VENDOR_ID: Int  = 0x2563   // 9571
let ARES_PRODUCT_ID: Int = 0x057A   // 1402

let ARES_UDP_PORT: UInt16 = 49152
let ARES_MAGIC: UInt32 = 0x41524553 // 'ARES'

// Print every element's usage page/usage once at startup
let DEBUG_DUMP_ELEMENTS = true
let TRACE_INPUT_EVENTS = ProcessInfo.processInfo.environment["ARES_TRACE"] == "1"
let AZAHAR_KEYBOARD_MODE = ProcessInfo.processInfo.environment["ARES_AZAHAR_KEYBOARD"] == "1"

// Generic Desktop usages (HID Usage Tables 1.12, page 0x01)
let USAGE_PAGE_GENERIC_DESKTOP = 0x01
let USAGE_X  = 0x30 // left stick X
let USAGE_Y  = 0x31 // left stick Y
let USAGE_Z  = 0x32 // Ares: right stick X (SDL a2)
let USAGE_RX = 0x33 // Standard Rx
let USAGE_RY = 0x34 // Standard Ry
let USAGE_RZ = 0x35 // Ares: right stick Y (SDL a3)
let USAGE_HAT = 0x39
let USAGE_PAGE_BUTTON = 0x09

// ----- Permissions ------------------------------------------------------

func checkAndRequestPermissions() {
    let listen = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    let post = IOHIDCheckAccess(kIOHIDRequestTypePostEvent)
    print("Permissions check:")
    print("  • Input Monitoring (ListenEvent): \(listen == kIOHIDAccessTypeGranted ? "GRANTED" : "NOT GRANTED / DENIED")")
    print("  • Accessibility (PostEvent):      \(post == kIOHIDAccessTypeGranted ? "GRANTED" : "NOT GRANTED / DENIED")")

    if listen != kIOHIDAccessTypeGranted {
        print("  --> Requesting Input Monitoring prompt...")
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
    if post != kIOHIDAccessTypeGranted {
        print("  --> Requesting Accessibility prompt...")
        _ = IOHIDRequestAccess(kIOHIDRequestTypePostEvent)
    }
}

// ----- Shared state written by the capture callback, read by the emit loop --

final class ControllerState {
    var buttons: UInt16 = 0          // bitmask, up to 16 buttons
    var lx: Int8 = 0                 // -127...127
    var ly: Int8 = 0
    var rx: Int8 = 0
    var ry: Int8 = 0
    var lt: UInt8 = 0                // 0...127
    var rt: UInt8 = 0
    var hat: UInt8 = 8               // 0...7 = N, NE, E, SE, S, SW, W, NW; 8 = neutral
}

let state = ControllerState()
let stateLock = NSLock()

struct KeyboardState {
    let buttons: UInt16
    let lx: Int8
    let ly: Int8
    let rx: Int8
    let ry: Int8
    let hat: UInt8
}

// Azahar's default keyboard profile, expressed as macOS virtual key codes.
// Events are emitted only while Azahar is the frontmost application.
final class AzaharKeyboardEmitter {
    private let bundleIdentifier = "org.azahar-emu.azahar"
    private var pressed: [CGKeyCode: Bool] = [:]
    private let threshold: Int8 = 55

    private func targetPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { !$0.isTerminated })?.processIdentifier
    }

    private func set(_ key: CGKeyCode, pressed shouldPress: Bool) {
        guard pressed[key, default: false] != shouldPress else { return }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: shouldPress) else {
            return
        }
        event.post(tap: .cgSessionEventTap)
        pressed[key] = shouldPress
    }

    func update(_ input: KeyboardState) {
        guard targetPID() != nil,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier else { return }

        // Face buttons: physical A/B/X/Y -> Azahar defaults A/S/Z/X.
        set(0, pressed: (input.buttons & (1 << 2)) != 0)   // A
        set(1, pressed: (input.buttons & (1 << 1)) != 0)   // S
        set(6, pressed: (input.buttons & (1 << 3)) != 0)   // Z
        set(7, pressed: (input.buttons & (1 << 0)) != 0)   // X
        set(12, pressed: (input.buttons & (1 << 4)) != 0)  // Q / L
        set(13, pressed: (input.buttons & (1 << 5)) != 0)  // W / R
        set(18, pressed: (input.buttons & (1 << 6)) != 0)  // 1 / ZL
        set(19, pressed: (input.buttons & (1 << 7)) != 0)  // 2 / ZR
        set(45, pressed: (input.buttons & (1 << 8)) != 0)  // N / Select
        set(46, pressed: (input.buttons & (1 << 9)) != 0)  // M / Start
        set(11, pressed: (input.buttons & (1 << 12)) != 0) // B / Home

        // D-pad uses Azahar's default T/G/F/H keys.
        let up = input.hat == 0 || input.hat == 1 || input.hat == 7
        let right = input.hat == 1 || input.hat == 2 || input.hat == 3
        let down = input.hat == 3 || input.hat == 4 || input.hat == 5
        let left = input.hat == 5 || input.hat == 6 || input.hat == 7
        set(17, pressed: up)     // T
        set(5, pressed: down)    // G
        set(3, pressed: left)    // F
        set(4, pressed: right)   // H

        // Left stick -> arrow keys (circle pad); right stick -> I/J/K/L (C-stick).
        set(126, pressed: input.ly > threshold)
        set(125, pressed: input.ly < -threshold)
        set(123, pressed: input.lx < -threshold)
        set(124, pressed: input.lx > threshold)
        set(34, pressed: input.ry > threshold)  // I
        set(40, pressed: input.ry < -threshold)  // K
        set(38, pressed: input.rx < -threshold)  // J
        set(37, pressed: input.rx > threshold)   // L
    }
}

let azaharKeyboard = AZAHAR_KEYBOARD_MODE ? AzaharKeyboardEmitter() : nil

// IOHIDManager is a Core Foundation object.  Scheduling it on the run loop
// does not transfer ownership, so it must remain strongly held after
// startCapture returns or all device/input callbacks stop.
var captureManager: IOHIDManager?

// ----- Compact UDP packet for libAresGCBridge ----------------------------

struct AresPacket {
    var magic: UInt32 = ARES_MAGIC
    var buttons: UInt16 = 0
    var lx: Int8 = 0
    var ly: Int8 = 0
    var rx: Int8 = 0
    var ry: Int8 = 0
    var hat: UInt8 = 8
    var pad0: UInt8 = 0
    var pad1: UInt8 = 0
    var pad2: UInt8 = 0
}

final class UDPEmitter {
    private var fd: Int32 = -1
    private var targetAddr = sockaddr_in()

    init() {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        targetAddr.sin_family = sa_family_t(AF_INET)
        targetAddr.sin_port = in_port_t(ARES_UDP_PORT).bigEndian
        targetAddr.sin_addr.s_addr = inet_addr("127.0.0.1")
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    func send(packet: inout AresPacket) {
        guard fd >= 0 else { return }
        withUnsafePointer(to: &targetAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                withUnsafeBytes(of: &packet) { rawPtr in
                    _ = sendto(fd, rawPtr.baseAddress, rawPtr.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

let emitter = UDPEmitter()

// ----- Capture side: IOHIDManager, matched to the Ares by VID/PID -----------

func startCapture() {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    captureManager = manager

    let matchDict: [String: Any] = [
        kIOHIDVendorIDKey as String: ARES_VENDOR_ID,
        kIOHIDProductIDKey as String: ARES_PRODUCT_ID
    ]
    IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

    IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, sender, device in
        print("Ares connected — enumerating elements")
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            return
        }
        if DEBUG_DUMP_ELEMENTS {
            for element in elements {
                let page = IOHIDElementGetUsagePage(element)
                let usage = IOHIDElementGetUsage(element)
                let type = IOHIDElementGetType(element)
                let min = IOHIDElementGetLogicalMin(element)
                let max = IOHIDElementGetLogicalMax(element)
                print(String(format: "  element type=%-3d usagePage=0x%02X usage=0x%02X [min=%d, max=%d]", type.rawValue, page, usage, min, max))
            }
        }
    }, nil)

    IOHIDManagerRegisterInputValueCallback(manager, { context, result, sender, value in
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let intValue = IOHIDValueGetIntegerValue(value)
        let min = IOHIDElementGetLogicalMin(element)
        let max = IOHIDElementGetLogicalMax(element)

        // The controller continuously emits vendor telemetry on page 0xFF00.
        // Trace only the controls this bridge consumes, otherwise the log is
        // flooded and diagnostic I/O can delay real input processing.
        if TRACE_INPUT_EVENTS && (page == USAGE_PAGE_GENERIC_DESKTOP || page == USAGE_PAGE_BUTTON) {
            print(String(format: "Input event: page=0x%02X usage=0x%02X value=%d", page, usage, intValue))
        }

        // Normalize any axis to the -127...127 range
        func normalizedSigned() -> Int8 {
            guard max > min else { return 0 }
            let ratio = Double(intValue - min) / Double(max - min) // 0...1
            return Int8(clamping: Int((ratio * 254.0) - 127.0))
        }

        stateLock.lock()

        if page == USAGE_PAGE_GENERIC_DESKTOP {
            switch usage {
            case USAGE_X:
                state.lx = normalizedSigned()
            case USAGE_Y:
                // Ares hardware: 0 is Up, 255 is Down. GameController expects +1.0 = Up.
                state.ly = -normalizedSigned()
            case USAGE_RX, USAGE_Z:
                // Ares physical descriptor defines Z (0x32) as Right Stick X
                state.rx = normalizedSigned()
            case USAGE_RY, USAGE_RZ:
                // Ares physical descriptor defines Rz (0x35) as Right Stick Y. Invert so Up is positive.
                state.ry = -normalizedSigned()
            case USAGE_HAT:
                state.hat = UInt8(clamping: intValue)
            default:
                break
            }
        } else if page == USAGE_PAGE_BUTTON {
            let bit = usage - 1 // Button 1 -> bit 0
            if bit >= 0 && bit < 16 {
                let mask: UInt16 = 1 << bit
                if intValue != 0 {
                    state.buttons |= mask
                } else {
                    state.buttons &= ~mask
                }
            }
            if usage == 7 {
                state.lt = (intValue != 0) ? 127 : 0
            } else if usage == 8 {
                state.rt = (intValue != 0) ? 127 : 0
            }
        }

        let keyboardState = KeyboardState(buttons: state.buttons, lx: state.lx, ly: state.ly,
                                          rx: state.rx, ry: state.ry, hat: state.hat)
        stateLock.unlock()
        azaharKeyboard?.update(keyboardState)
    }, nil)

    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    if openResult != kIOReturnSuccess {
        print("IOHIDManagerOpen failed (\(openResult)) — check Input Monitoring permission in System Settings > Privacy & Security")
    } else {
        print("IOHIDManager opened successfully for Ares controller.")
    }
}

func buildPacket() -> AresPacket {
    stateLock.lock()
    defer { stateLock.unlock() }

    var pkt = AresPacket()
    pkt.buttons = state.buttons
    pkt.lx = state.lx
    pkt.ly = state.ly
    pkt.rx = state.rx
    pkt.ry = state.ry
    pkt.hat = state.hat
    return pkt
}

var _timerKeepAlive: DispatchSourceTimer?

func startEmitLoop() {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(10)) // 100 Hz
    timer.setEventHandler {
        var pkt = buildPacket()
        emitter.send(packet: &pkt)
    }
    timer.resume()
    _timerKeepAlive = timer
    print("Broadcasting Ares state to local bridge at 127.0.0.1:\(ARES_UDP_PORT) (100 Hz)")
}

// ----- Entry point -----------------------------------------------------

print("AresTranslator starting — Matching VID:PID \(String(format: "0x%04X", ARES_VENDOR_ID)):\(String(format: "0x%04X", ARES_PRODUCT_ID))")
checkAndRequestPermissions()
if AZAHAR_KEYBOARD_MODE {
        print("Azahar keyboard mode enabled — events are emitted only while Azahar is frontmost.")
}

startCapture()
startEmitLoop()

print("Running translator. Press Ctrl-C to quit.")
CFRunLoopRun()
