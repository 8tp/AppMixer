<div align="center">

# AppMixer

**Per-app volume control for macOS**

[![macOS](https://img.shields.io/badge/macOS-13%2B-000000?style=flat-square&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![HAL Driver](https://img.shields.io/badge/Audio-HAL%20Driver-8B5CF6?style=flat-square)](Driver/)

<br>

*A lightweight menu bar utility that gives you individual volume sliders for every app on your Mac &mdash; something macOS still doesn't offer natively.*

</div>

---

## How It Works

AppMixer uses a **HAL (Hardware Abstraction Layer) virtual audio driver** to intercept and control audio at the per-process level. This is the same proven approach used by professional tools like [Background Music](https://github.com/kyleneideck/BackgroundMusic) and [SoundSource](https://rogueamoeba.com/soundsource/).

```
┌──────────────┐     ┌─────────────────────┐     ┌──────────────┐
│   Spotify     │────▶│                     │     │              │
├──────────────┤     │   AppMixer Driver    │     │   Real       │
│   Chrome      │────▶│   (Virtual Device)   │────▶│   Speakers   │
├──────────────┤     │                     │     │   / AirPods   │
│   Discord     │────▶│  Per-PID volume     │     │              │
└──────────────┘     │  scaling in kernel   │     └──────────────┘
                     └─────────┬───────────┘
                               │ shared memory
                     ┌─────────▼───────────┐
                     │   AppMixer App       │
                     │   (Menu Bar UI)      │
                     └─────────────────────┘
```

### Architecture

| Component | Language | Role |
|-----------|----------|------|
| **Driver** (`Driver/AppMixerDriver.c`) | C | HAL AudioServerPlugIn loaded by `coreaudiod`. Registers as a virtual output device, applies per-process volume scaling, and provides a ring buffer loopback for audio forwarding. |
| **App** (`Sources/AppMixer/`) | Swift | Menu bar UI. Detects audio apps via CoreAudio process objects, writes per-PID volumes to shared memory, forwards mixed audio from the virtual device to real hardware via an aggregate device with drift correction. |

### Key Design Decisions

- **Shared memory IPC** &mdash; The app writes per-PID volume maps to `/tmp/appmixer_volumes` (file-backed `mmap`). The driver reads it lock-free in the IO path. Zero syscall overhead.
- **Sample-time ring buffer** &mdash; Inspired by [BlackHole](https://github.com/ExistentialAudio/BlackHole). Uses `inIOCycleInfo` sample times for ring buffer indexing instead of separate read/write counters. Eliminates internal clock drift.
- **Aggregate device forwarding** &mdash; Audio is bridged from the virtual device to real hardware through a private aggregate device with drift correction enabled. CoreAudio handles clock synchronization.
- **Native volume keys** &mdash; The driver exposes volume and mute control objects so F10/F11/F12 work normally and stay in sync with the UI.

## Features

- Individual volume sliders for every audio-producing app
- Master volume control with mute toggle
- F10/F11/F12 media keys work normally
- Auto-detection of audio apps via CoreAudio process objects
- Pin apps to keep them visible even when silent
- Apps fade out after 5 seconds of inactivity
- Dark mode / light mode (follows system)
- Lightweight menu bar popover UI

## Quick Start

### Prerequisites

- macOS 13 (Ventura) or later
- Xcode Command Line Tools (`xcode-select --install`)
- Admin privileges (for driver installation)

### Install

```bash
# Clone
git clone https://github.com/YOUR_USERNAME/app-mixer.git
cd app-mixer

# Build the HAL driver
bash build_driver.sh

# Install the driver (requires admin, restarts coreaudiod)
sudo bash install_driver.sh

# Build and run the app
swift run
```

### Build App Bundle

```bash
# Create a standalone .app bundle
bash build.sh

# Copy to Applications
cp -r AppMixer.app /Applications/
```

### Uninstall

```bash
# Remove the driver
sudo rm -rf /Library/Audio/Plug-Ins/HAL/AppMixerDriver.driver
sudo killall coreaudiod

# Remove the app
rm -rf /Applications/AppMixer.app
```

## Project Structure

```
app-mixer/
├── Driver/
│   ├── AppMixerDriver.c        # HAL AudioServerPlugIn implementation
│   └── Info.plist               # Driver bundle metadata (CFPlugIn UUIDs)
├── Sources/AppMixer/
│   ├── main.swift               # Entry point
│   ├── AppDelegate.swift        # Lifecycle management
│   ├── StatusBarController.swift # Menu bar icon + popover
│   ├── Audio/
│   │   ├── AudioManager.swift   # App detection, volume state, system volume
│   │   └── AudioTapManager.swift # Shared memory IPC, device switching, forwarding
│   ├── Models/
│   │   └── AudioApp.swift       # Audio app data model
│   └── Views/
│       ├── PopoverContentView.swift  # Main mixer UI
│       ├── AppVolumeRow.swift        # Per-app slider row
│       └── SettingsView.swift        # Settings panel
├── Resources/
│   └── Info.plist               # App bundle metadata
├── Package.swift                # Swift Package Manager manifest
├── build_driver.sh              # Compiles the HAL driver bundle
├── build.sh                     # Builds the .app bundle
└── install_driver.sh            # Installs driver + restarts coreaudiod
```

## How the Driver Works

The driver implements Apple's `AudioServerPlugInDriverInterface` &mdash; a C interface that `coreaudiod` loads as a plugin. It runs in-process with the audio server.

### IO Pipeline

```
App writes audio ──▶ ProcessOutput (per-client volume scaling)
                         │
                         ▼
                    WriteMix (store to ring buffer)
                         │
                         ▼
                    ReadInput (read from ring buffer) ──▶ AppMixer app forwards to real output
```

1. **`ProcessOutput`** &mdash; Called per-client per IO cycle. Looks up the client's PID, reads the volume from shared memory, and scales the audio buffer in-place.
2. **`WriteMix`** &mdash; Writes the mixed output to a ring buffer indexed by sample time.
3. **`ReadInput`** &mdash; The app reads the ring buffer via the device's input stream and forwards it to the real output hardware.

### Volume Controls

The driver exposes `kAudioVolumeControlClassID` and `kAudioMuteControlClassID` objects so macOS routes F10/F11/F12 key events to it. The app listens for property changes on these controls and forwards them to the real output device.

## Limitations

- Requires admin privileges to install the driver
- Requires `coreaudiod` restart after driver installation
- Driver is not code-signed (local development only; signing required for distribution)
- Some Electron apps share a single audio process
- The app must be running for audio to pass through

## Acknowledgments

- [BlackHole](https://github.com/ExistentialAudio/BlackHole) &mdash; Ring buffer and `GetZeroTimeStamp` patterns
- [Background Music](https://github.com/kyleneideck/BackgroundMusic) &mdash; Architecture inspiration for per-app volume via HAL driver

## License

[MIT](LICENSE)
