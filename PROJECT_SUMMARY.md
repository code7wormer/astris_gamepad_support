# Ares Controller on macOS (Astris GameController Bridge)
## Project Overview, Aim & Technical Architecture

---

## 1. Project Aim & Goal

The goal of this project is to enable full, seamless gamepad support for the **CosmicByte Ares Wired Controller** in macOS applications that strictly rely on Apple's native **`GameController.framework`** (specifically the Nintendo Switch emulator **Astris** / `V380-Ori.Astris`), without requiring:
- A paid Apple Developer Program account or custom provisioning profiles
- Disabling System Integrity Protection (SIP) or Apple Mobile File Integrity (AMFI)
- Full Xcode.app installation (building completely with Command Line Tools via `swift build` and `clang`)

The primary technical challenge was getting Apple's `GCController` ecosystem to recognize this controller and map its axes accurately—especially the **right thumbstick**, which was previously non-functional in generic HID mapping layers.

---

## 2. Hardware Profile

- **Device:** CosmicByte Ares Wired Controller
- **VID / PID:** `0x2563` : `0x057A` (Decimal `9571` : `1402`)
- **Transport:** USB (`AppleUserUSBHostHIDDevice`)
- **Controller Mode:** **Direct Input (Red LED Mode)**
  > *Note:* XInput mode (Blue LED) requires a Microsoft proprietary handshake unavailable on macOS, falling back to Android mode. Direct Input (Red LED) is the stable standard mode for macOS.
- **Physical HID Usages Confirmed:**
  - **Left Thumbstick:** Generic Desktop `0x01`, Usages `0x30` ($X$) and `0x31` ($Y$), range $0 \dots 255$
  - **Right Thumbstick:** Generic Desktop `0x01`, Usages `0x32` ($Z \rightarrow \text{Right Stick } X$) and `0x35` ($Rz \rightarrow \text{Right Stick } Y$), range $0 \dots 255$
  - **D-Pad / Hat Switch:** Generic Desktop `0x01`, Usage `0x39` (Hat switch, values $0 \dots 7$, neutral $8$)
  - **Buttons (13 buttons):** Button Page `0x09`, Usages `0x01` through `0x0D`

---

## 3. Root Cause Analysis: Why Standard Approaches Failed

### A. The Virtual HID Device Roadblock (`IOHIDUserDevice` / `CoreHID`)
Initial attempts to build an OS-level virtual gamepad (both in the original `AresTranslator` and in `OpenJoystickDriver`) failed with:
- `IOHIDUserDeviceCreateWithProperties failed`
- `CoreHID HIDVirtualDevice create returned nil`

**Root Cause:** Starting in macOS 11 through macOS 15+ / 26+, creating virtual HID devices system-wide requires the restricted entitlement `com.apple.developer.hid.virtual.device`. Apple only signs this entitlement with a paid Apple Developer Program Provisioning Profile. The kernel rejects unsigned virtual HID requests unconditionally, even when executed with `sudo`.

### B. Why `gamecontrollerd` Ignores the Physical Ares
When the physical controller is connected:
- macOS kernel DriverKit matches the device as `AppleUserHIDEventDriver`.
- However, Apple's `gamecontrollerd` daemon only surfaces devices that exist within its internal `.gcdevice` bundle database (Xbox, PlayStation, Nintendo Switch, and certified MFi pads).
- Because `0x2563:0x057A` is not in Apple's device DB, `gamecontrollerd` leaves `GCController.controllers()` empty.

---

## 4. The Solution Architecture

Astris (`/Applications/Astris.app`) ships with standard hardened runtime exceptions:
- `com.apple.security.cs.allow-dyld-environment-variables: true`
- `com.apple.security.cs.disable-library-validation: true`
- `com.apple.security.network.client: true` / `network.server: true`

This allows an **in-process bridge dynamic library** to feed GameController events directly to Astris, coupled with a lightweight background daemon that reads the physical USB device.

```
┌──────────────────────────────────────────────┐
│  CosmicByte Ares USB Gamepad (0x2563:0x057A)  │
└──────────────────────┬───────────────────────┘
                       │
                       │ Raw HID Events
                       ▼
┌──────────────────────────────────────────────┐
│       AresTranslator (Background Daemon)      │
│  - Captures USB HID via IOHIDManager         │
│  - Translates Z/Rz -> Right Stick X/Y        │
│  - Inverts vertical axes (+1.0 = UP)         │
│  - Broadcasts a 16-byte local UDP packet @ 100Hz │
└──────────────────────┬───────────────────────┘
                       │
                       │ Loopback UDP (127.0.0.1:49152)
                       ▼
┌──────────────────────────────────────────────┐
│  Astris Process (/Applications/Astris.app)   │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │   libAresGCBridge.dylib (Injected)     │  │
│  │   - Receives UDP packets               │  │
│  │   - Manages GCController snapshot      │  │
│  │   - Swizzles +[GCController controllers│  │
│  │   - Dispatches ExtendedGamepad events  │  │
│  │   - Posts GCControllerDidConnect       │  │
│  └───────────────────┬────────────────────┘  │
│                      │                       │
│                      ▼ Native GC Events      │
│  ┌────────────────────────────────────────┐  │
│  │   libRyujinx.dylib (Astris Engine)     │  │
│  │   _ryujinx_set_controller_stick_axis   │  │
│  │   _ryujinx_set_controller_button_*     │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
```

---

## 5. Mapping Reference

| Ares Hardware Input | HID Usage Page / Usage | In GameController Profile (`GCExtendedGamepad`) |
|---|---|---|
| **Left Stick Horizontal** | Page `0x01`, Usage `0x30` | `leftThumbstick.xAxis` ($-1.0 \dots +1.0$) |
| **Left Stick Vertical** | Page `0x01`, Usage `0x31` | `leftThumbstick.yAxis` (Inverted: UP $= +1.0$) |
| **Right Stick Horizontal** | Page `0x01`, Usage `0x32` ($Z$) | `rightThumbstick.xAxis` ($-1.0 \dots +1.0$) |
| **Right Stick Vertical** | Page `0x01`, Usage `0x35` ($Rz$) | `rightThumbstick.yAxis` (Inverted: UP $= +1.0$) |
| **D-Pad Up/Down/Left/Right** | Page `0x01`, Usage `0x39` (Hat) | `dpad` (`xAxis`, `yAxis` values) |
| **Button 1 (X)** | Page `0x09`, Usage `0x01` | `buttonX` |
| **Button 2 (A)** | Page `0x09`, Usage `0x02` | `buttonA` |
| **Button 3 (B)** | Page `0x09`, Usage `0x03` | `buttonB` |
| **Button 4 (Y)** | Page `0x09`, Usage `0x04` | `buttonY` |
| **Button 5 (LB / L)** | Page `0x09`, Usage `0x05` | `leftShoulder` |
| **Button 6 (RB / R)** | Page `0x09`, Usage `0x06` | `rightShoulder` |
| **Button 7 (LT / ZL)** | Page `0x09`, Usage `0x07` | `leftTrigger` |
| **Button 8 (RT / ZR)** | Page `0x09`, Usage `0x08` | `rightTrigger` |
| **Button 9 (Back / Minus)** | Page `0x09`, Usage `0x09` | `buttonOptions` |
| **Button 10 (Start / Plus)** | Page `0x09`, Usage `0x0A` | `buttonMenu` |
| **Button 11 (L3)** | Page `0x09`, Usage `0x0B` | `leftThumbstickButton` |
| **Button 12 (R3)** | Page `0x09`, Usage `0x0C` | `rightThumbstickButton` |
| **Button 13 (Home)** | Page `0x09`, Usage `0x0D` | `buttonHome` |

---

## 6. Project Structure

```
/Users/shardul/Downloads/files/
├── Package.swift                    # Swift package manifest
├── Sources/
│   ├── AresTranslator/
│   │   └── main.swift               # Daemon reading USB HID and emitting UDP packets
│   └── GCTest/
│       └── main.swift               # Test & diagnostic tool for GameController framework
├── bridge/
│   ├── AresGCBridge.m               # In-process bridge dylib for Astris / GCController
│   └── libAresGCBridge.dylib        # Compiled dynamic library
├── launch_astris.sh                 # Unified launcher for Astris + Ares Bridge
├── ares-controller-troubleshooting-summary.md  # Historical troubleshooting notes
└── PROJECT_SUMMARY.md               # This document
```

---

## 7. How to Build & Run

### Quick Launch
To start Astris with the controller bridge running:
```bash
cd /Users/shardul/Downloads/files
./launch_astris.sh
```

### Manual Build Commands
If you make modifications to any components:

1. **Rebuild `AresTranslator`**:
   ```bash
   swift build --target AresTranslator
   ```

2. **Recompile `libAresGCBridge.dylib`**:
   ```bash
   clang -dynamiclib -O2 -fobjc-arc \
     -framework Foundation -framework GameController \
     -o bridge/libAresGCBridge.dylib \
     bridge/AresGCBridge.m
   ```

3. **Verify with `GCTest`**:
   ```bash
   # Terminal 1: run translator daemon
   swift run AresTranslator

   # Terminal 2: run GCTest with injected bridge
   DYLD_INSERT_LIBRARIES=bridge/libAresGCBridge.dylib swift run GCTest
   ```
