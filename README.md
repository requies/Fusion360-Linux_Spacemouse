# ⚠️ [Unmaintained]

> **This project is archived and no longer maintained.**
> It is provided as-is for reference and forking. Feel free to copy, modify, and continue the work.

---

A user-space SpaceMouse bridge for **Autodesk Fusion 360 running under Wine on Linux**.

This makes a 3Dconnexion SpaceMouse work for viewport navigation in Fusion 360 when Fusion is launched through the [cryinkfly](https://github.com/cryinkfly/autodesk_fusion_linux) Wine launcher on Linux.

It does **not** install the Windows 3DxWare driver into Wine. Instead, it uses the native Linux `spacenavd` daemon, so all settings configured with `spnavcfg` continue to apply.

## Architecture

```
SpaceMouse → spacenavd (Linux) → spacenav-fusion-bridge (UDP) → SpacenavBridge.py (Fusion Add-in)
```

1. `spacenavd` reads the SpaceMouse from Linux input devices (`/dev/input/event*`).
2. `spnavcfg` controls sensitivity, axis mapping, inversion, and button behavior at the native Linux daemon layer.
3. `spacenav-fusion-bridge` connects to `/run/spnav.sock` via `libspnav` and forwards motion/button events to `127.0.0.1:39030` over UDP.
4. `SpacenavBridge.py` runs inside Fusion as a Python add-in, listens on UDP, and updates `app.activeViewport.camera`.
5. The cryinkfly Fusion launcher is patched to start the bridge before Wine and stop it after Fusion exits.

## What Is Included

| File | Description |
|------|-------------|
| `src/spacenav-fusion-bridge.c` | Native Linux bridge (C, links against `libspnav`) |
| `addin/SpacenavBridge.py` | Fusion Python add-in (UDP listener + camera controller) |
| `addin/SpacenavBridge.manifest` | Fusion add-in manifest with `runOnStartup` enabled |
| `bin/spacenav-fusion-bridge` | Prebuilt binary (fallback if no C compiler) |
| `install.sh` | Idempotent installer for another Linux machine |
| `reference/` | Copies of working launcher and Fusion options files, for comparison |

## Requirements

- A Linux-supported 3Dconnexion SpaceMouse
- `spacenavd` running as a system service
- `libspnav` runtime and development headers
- A C compiler (`gcc` or `cc`)
- Fusion 360 installed via the [cryinkfly](https://github.com/cryinkfly/autodesk_fusion_linux) Linux/Wine launcher (usually under `~/.autodesk_fusion`)
- Python 3 (for the installer and Fusion's add-in runtime)

### Arch / CachyOS

```bash
sudo pacman -S --needed spacenavd libspnav gcc spnavcfg
sudo systemctl enable --now spacenavd.service
```

### Debian / Ubuntu

```bash
sudo apt-get install -y spacenavd libspnav-dev build-essential
sudo systemctl enable --now spacenavd.service
```

### Fedora

```bash
sudo dnf install -y spacenavd libspnav-devel gcc
sudo systemctl enable --now spacenavd.service
```

## Installation

### Automatic

From this directory:

```bash
./install.sh
```

If Fusion is installed somewhere other than `~/.autodesk_fusion`:

```bash
./install.sh --fusion-root /path/to/.autodesk_fusion
```

Useful options:

```bash
./install.sh --skip-deps              # Do not install distro packages
./install.sh --skip-service           # Do not enable/start spacenavd.service
./install.sh --skip-launcher-patch    # Install files only; do not patch the launcher
```

The installer:

1. Installs distro packages when possible
2. Enables and starts `spacenavd.service`
3. Copies and compiles the native bridge to `~/.local/bin/spacenav-fusion-bridge`
4. Installs the Fusion add-in into the Wine prefix
5. Patches the cryinkfly Fusion launcher so the bridge starts with Fusion and exits when Fusion exits
6. Sets Fusion's SpaceMouse driver preference to the older SDK mode
7. Runs a bridge smoke test against `spacenavd`

The launcher patch is marked with `# >>> spacemouse360_linux` / `# <<< spacemouse360_linux` comments. A timestamped launcher backup is created before patching.

### Manual

1. **Install dependencies and start `spacenavd`** (see above)

2. **Build and install the bridge:**

   ```bash
   mkdir -p ~/.local/share/autodesk-fusion-spacenav ~/.local/bin
   cp src/spacenav-fusion-bridge.c ~/.local/share/autodesk-fusion-spacenav/
   cc -O2 -Wall -Wextra -o ~/.local/bin/spacenav-fusion-bridge ~/.local/share/autodesk-fusion-spacenav/spacenav-fusion-bridge.c -lspnav
   ~/.local/bin/spacenav-fusion-bridge --check
   ```

3. **Install the Fusion add-in:**

   ```bash
   WINE_PFX="$HOME/.autodesk_fusion/wineprefixes/default"
   ADDIN_DIR="$WINE_PFX/drive_c/users/$USER/AppData/Roaming/Autodesk/Autodesk Fusion 360/API/AddIns/SpacenavBridge"
   mkdir -p "$ADDIN_DIR"
   cp addin/SpacenavBridge.py addin/SpacenavBridge.manifest "$ADDIN_DIR/"
   ```

4. **Patch the launcher** — the easiest safe method:

   ```bash
   ./install.sh --skip-deps --skip-service
   ```

5. **Restart Fusion** through the normal cryinkfly launcher.

## How It Works

`spacenavd` reads the SpaceMouse from Linux input devices and applies the settings you configure with `spnavcfg`, including sensitivity, axis mapping, inversion, and button behavior.

`spacenav-fusion-bridge` connects to `/run/spnav.sock` through `libspnav`. It forwards motion and button events to `127.0.0.1:39030` over UDP.

`SpacenavBridge.py` runs inside Fusion as a Python add-in. It listens on `127.0.0.1:39030`, receives the forwarded events, and updates `app.activeViewport.camera`.

Default button behavior:

- **Button 0**: fit viewport
- **Button 1**: home view

## Tuning

Most tuning should be done in `spnavcfg`, because those settings are applied by `spacenavd` before events reach Fusion.

If Fusion-specific tuning is needed, edit constants near the top of `addin/SpacenavBridge.py`:

| Constant | Purpose |
|----------|---------|
| `PAN_SCALE` | X/Y translation sensitivity |
| `ZOOM_SCALE` | Z-axis zoom sensitivity |
| `ROT_SCALE` | Pitch/yaw rotation sensitivity |
| `ROLL_SCALE` | Roll rotation sensitivity |
| `PAN_X_SIGN` / `PAN_Y_SIGN` | X/Y pan direction (1.0 or -1.0) |
| `ZOOM_SIGN` | Zoom direction (1.0 or -1.0) |
| `PITCH_SIGN` / `YAW_SIGN` / `ROLL_SIGN` | Rotation direction (1.0 or -1.0) |

After editing the installed add-in copy, restart Fusion.

## Fusion SpaceMouse Driver Option

Fusion must be set to the **Older/Legacy** SpaceMouse SDK mode:

```xml
<spacemouseDriverOptionId Value="0" />
```

The installer sets this automatically when the options file exists. The file is typically at:

```
<WINEPREFIX>/drive_c/users/<user>/Application Data/Autodesk/Neutron Platform/Options/NMachineSpecificOptions.xml
```

## Verification

```bash
~/.local/bin/spacenav-fusion-bridge --check
```

Expected output includes `connected to spacenavd`, the SpaceMouse device name, 6 axes, button count, and USB ID.

Check launcher patch:

```bash
grep -n "spacemouse360\|spacenav-fusion-bridge" ~/.autodesk_fusion/bin/autodesk_fusion_launcher.sh
```

Check add-in files:

```bash
find ~/.autodesk_fusion/wineprefixes/default -path '*API/AddIns/SpacenavBridge/*' -type f
```

## Troubleshooting

### Bridge check fails

```bash
systemctl status spacenavd.service
ls -l /run/spnav.sock
```

Confirm the SpaceMouse is plugged in and `spacenavd` is running.

### Fusion launches but SpaceMouse does nothing

- Confirm the launcher contains the marked `spacemouse360_linux` block
- Confirm the add-in directory exists in the Wine prefix
- In Fusion, check **Utilities > Add-Ins > Scripts and Add-Ins** and verify `SpacenavBridge` is loaded
- Restart Fusion after installing or editing the add-in

### X/Y pan and rotation work but Z-axis zoom does nothing

The active camera is likely orthographic (`camType == 0`). In orthographic mode, zoom is controlled by `camera.viewExtents`, not by moving the camera eye position.

The add-in includes a fix that detects orthographic cameras and scales `viewExtents` directly. If you still have issues, verify the installed `SpacenavBridge.py` contains the `camera.cameraType` check.

If zoom direction feels reversed, toggle `ZOOM_SIGN` (1.0 → -1.0 or vice versa).

### Z-axis zoom is too slow

Increase `ZOOM_SCALE` in `SpacenavBridge.py`. Test values:

```bash
python3 -c "
import math
for scale in [0.000075, 0.000300, 0.000750]:
    print(f'scale={scale:.6f} z=-12 zoom={math.exp(12*scale):.4f}')
"
```

## Known Working Configuration

- **Device**: 3Dconnexion SpaceMouse Compact (`256f:c635`)
- **spacenavd**: 1.3.1
- **libspnav**: 1.2
- **Session**: Wayland or X11 (bridge is session-agnostic)

## Notes

- This is a user-space workaround for Wine. It avoids raw `/dev/input` access and avoids trying to run the Windows 3Dconnexion kernel driver under Wine.
- The bridge only controls Fusion viewport navigation. It is not a complete replacement for all 3DxWare features.
- The bundled binary in `bin/` is architecture-specific and included only as a fallback. Compiling from source is preferred.

## License

MIT License. See [LICENSE](LICENSE).
