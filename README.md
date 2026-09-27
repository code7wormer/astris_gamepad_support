# Astris Gamepad Support

This project makes a Cosmic Byte Ares wired controller work in Astris on macOS when macOS does not expose the controller through `GameController.framework` by itself.

It runs two local components:

1. `AresTranslator` reads the physical USB controller in Direct Input mode.
2. An Astris-only bridge turns those readings into a writable native GameController snapshot inside Astris.

Nothing is installed system-wide. No SIP changes, kernel extension, virtual-HID entitlement, or Apple Developer account is required.

## Architecture

```text
Cosmic Byte Ares (USB, Direct Input)
        │ raw HID
        ▼
AresTranslator
        │ loopback UDP, 127.0.0.1 only
        ▼
Astris + in-process GameController bridge
        │ native Extended Gamepad events
        ▼
Astris game input
```

The bridge is entirely local: no controller data leaves your Mac.

## Quick start

1. Put the Ares in **Direct Input / red LED mode**. Hold `HOME` for about five seconds to change modes if needed.
2. Quit Astris completely.
3. Double-click **`Run Astris with Ares.command`** in Finder, or run this from Terminal:

   ```bash
   cd /path/to/Astris_gamepad
   ./launch_astris.sh
   ```

4. In Astris, select **Pro Controller** first. A Joy-Con Pair also works when a specific game needs that controller type.

The launcher rebuilds its small local components automatically when their source changes.

## First-time macOS permissions

The first launch can prompt for **Input Monitoring** and **Accessibility**. Allow both. If no prompt appears or input does not work:

1. Open **System Settings → Privacy & Security → Input Monitoring**.
2. Enable the app that launched the helper—usually Terminal. If `AresTranslator` is listed, enable it too.
3. Do the same under **Accessibility**.
4. Quit Astris and launch it again with `Run Astris with Ares.command`.

Check the helper’s status with:

```bash
tail -f /tmp/astris-ares-translator.log
```

Healthy startup output includes `IOHIDManager opened successfully` followed by `Ares connected` when the controller is plugged in.

## Keeping it easy to run

Keep this whole folder together in a permanent location. The Finder-friendly `Run Astris with Ares.command` always finds the launcher beside it, so you can move the folder without editing paths.

To use a non-default Astris location, set `ASTRIS_APP` once for that launch:

```bash
ASTRIS_APP="/path/to/Astris.app" ./launch_astris.sh
```

### Spotlight launcher

Run `./install_nintendo_app.sh` once to install **Nintendo.app** in `/Applications`. It appears in Spotlight and asks whether to launch Astris or Azahar. It remembers this project folder and asks you to select it again if you later move the repository.

Remove `/Applications/Nintendo.app` to remove the Spotlight launcher. The launcher does not copy the controller project; keep this folder while you use it.

Only one emulator can use the Ares helper at once. If Nintendo.app is opened while Astris or Azahar is already running, it brings that emulator forward without starting a second launcher or altering the active controller session.

Useful commands:

```bash
./launch_astris.sh --diagnose  # checks Astris compatibility and build tools
./launch_astris.sh --stop      # stops only the controller helper
ARES_TRACE=1 ./launch_astris.sh  # records physical input events in the helper log
```

## After an Astris update

1. Quit Astris.
2. Run `./launch_astris.sh --diagnose` from this folder.
3. If it reports compatibility is OK, double-click `Run Astris with Ares.command` as usual.

The launcher checks the two Astris signing entitlements that permit the bridge (`allow-dyld-environment-variables` and `disable-library-validation`). If an update removes either one, it stops before launching rather than starting Astris without controller support. In that case, keep this project folder and wait for an updated compatible Astris build or bridge approach.

## Azahar (Nintendo 3DS)

Azahar cannot enumerate this Ares controller through its SDL backend on this Mac. The included Azahar launcher therefore translates Ares input to Azahar's built-in **Default** keyboard profile. It does not inject code into Azahar.

1. Quit Azahar and Astris.
2. Double-click **`Run Azahar with Ares.command`**, or run:

   ```bash
   cd /path/to/Astris_gamepad
   ./launch_azahar.sh
   ```

3. Click the Azahar game window before using the controller.

The controller service runs through macOS `launchd` for reliable background operation, but the launcher owns its lifetime: it stops automatically when Azahar quits or when its Terminal window is closed. When Azahar is not the frontmost app, it emits no keyboard events.

If macOS denies the helper's Input Monitoring or Accessibility permission, the launcher stops before opening Azahar and explains what is needed. This prevents a silent no-input session.

Azahar's keyboard profile must bind `T/G/C/H` to D-pad Up/Down/Left/Right respectively. The other relevant keys are `A/S/Z/X` for face buttons, `Q/W` for shoulders, `1/2` for triggers, arrow keys for the Circle Pad, and `I/J/K/L` for the C-Stick. You can verify Azahar's keyboard controls directly with those keys before launching the controller helper.

## Limitations

- This release targets the **Cosmic Byte Ares wired controller** (`VID:PID 2563:057a`) in Direct Input mode. Other controllers are not automatically supported.
- XInput / blue LED mode is not supported on macOS. Use red Direct Input mode.
- Standard buttons, triggers, D-pad, and both sticks are supported. Rumble, motion controls, touch input, and controller LEDs are not implemented.
- The bridge depends on Astris retaining its current hardened-runtime exceptions. The update diagnostic detects a removed entitlement; it cannot bypass one.
- Astris must be launched through this script. The bridge cannot be injected into an already-open Astris instance.
- Azahar support is keyboard translation, not native controller support. It follows Azahar's Default keyboard profile and may affect emulator shortcuts if the game window is not focused.
- This is a user-space compatibility bridge, not an official Astris feature.

## Troubleshooting

- **Controller appears in Astris but no buttons move:** quit Astris, run `./launch_astris.sh --stop`, confirm the red LED mode, then launch again. Check the helper log and Input Monitoring permission.
- **Astris is already open:** quit it before using the launcher. An already-open instance cannot load the bridge afterward.
- **Build-tool error:** install Apple Command Line Tools with `xcode-select --install`, then launch again.
- **Need detailed HID enumeration:** launch once with `ARES_DEBUG=1 ./launch_astris.sh`; the extra details are written to the helper log.
- **Azahar works with the keyboard but not the controller:** quit Azahar, start it using `Run Azahar with Ares.command`, and click the game window. Confirm that Azahar has its Default keyboard profile selected.


## Controller mapping

The Ares is read as USB VID:PID `2563:057a`. Left stick uses X/Y, right stick uses Z/Rz, the D-pad uses the hat switch, and all 13 buttons are translated to an extended GameController profile.
