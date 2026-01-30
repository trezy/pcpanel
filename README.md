# PC Panel Pro - macOS Controller

A macOS application for controlling per-app audio volume using the PC Panel Pro hardware mixer.

## Features

- **9 Virtual Audio Devices**: Creates virtual output devices (K1-K5 for knobs, S1-S4 for sliders) that apps can use as audio outputs
- **Real-time Volume Control**: Hardware knob/slider movements instantly adjust the volume of audio routed through each channel
- **Audio Activity Detection**: Visual feedback showing which channels have active audio
- **System Tray Support**: App runs in the background with menu bar icon
- **React UI**: Modern interface showing device status, channel activity, and controls

## Prerequisites

- macOS 12.0 or later
- Node.js 18+ and npm
- Xcode Command Line Tools (`xcode-select --install`)
- CMake (`brew install cmake`)
- PC Panel Pro hardware device

## Quick Start

```bash
# Clone the repository
git clone <repo-url>
cd pcpanelpro

# Run setup (fetches dependencies, installs npm packages)
npm run setup

# Build and run the app
npm run start
```

## Installation

### 1. Setup Development Environment

```bash
npm run setup
```

This script:
- Fetches libASPL v3.1.2 (Core Audio driver library)
- Installs npm dependencies

### 2. Build and Install the Audio Driver

The audio driver creates 9 virtual audio devices that appear in System Settings.

```bash
# Build the driver
npm run build:driver

# Install the driver (requires sudo password)
npm run install:driver
```

After installation, you should see "PCPanel K1" through "PCPanel S4" in System Settings > Sound > Output.

### 3. Run the App

```bash
npm run start
```

## Usage

1. **Assign Apps to Channels**: In each app's audio settings (or System Settings > Sound), select a PCPanel device (K1-K5, S1-S4) as the output device
2. **Control Volume**: Turn the corresponding knob or move the slider on your PC Panel Pro hardware
3. **Monitor Activity**: The app shows which channels have active audio (green indicator)

## Available Scripts

| Command | Description |
|---------|-------------|
| `npm run setup` | Fetch dependencies and install npm packages |
| `npm run build` | Build the Electron app |
| `npm run start` | Build and run the app |
| `npm run build:native` | Rebuild the native audio addon |
| `npm run build:driver` | Build the Core Audio HAL driver |
| `npm run install:driver` | Install driver to system (requires sudo) |
| `npm run rebuild` | Rebuild native modules for Electron |

## Project Structure

```
pcpanelpro/
├── src/
│   ├── main/                 # Electron main process
│   │   ├── index.ts          # App entry point, window management, tray
│   │   ├── preload.ts        # IPC bridge for renderer
│   │   ├── audio/            # Audio passthrough module
│   │   └── hid/              # USB HID communication
│   └── renderer/             # React UI
│       ├── App.tsx           # Main React component
│       ├── components/       # UI components (Knob, Slider, Button, Status)
│       └── styles.css        # Styling
├── native/                   # Node.js native addon
│   ├── binding.gyp           # Build configuration
│   └── src/
│       └── audio_passthrough.mm  # CoreAudio passthrough implementation
├── driver/                   # Core Audio HAL plugin
│   ├── CMakeLists.txt        # CMake build config
│   ├── Info.plist.in         # Bundle info template
│   └── src/
│       └── Driver.cpp        # Virtual device implementation
├── scripts/                  # Build/setup scripts
│   ├── setup.sh              # Development setup
│   ├── build-driver.sh       # Driver build wrapper
│   └── install-driver.sh     # Driver installation
├── package.json
└── tsconfig.json
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    PC Panel Pro Hardware                     │
│                 (5 knobs, 4 sliders, 5 buttons)              │
└─────────────────────────────┬───────────────────────────────┘
                              │ USB HID
┌─────────────────────────────▼───────────────────────────────┐
│                      Electron App                            │
│  • Reads knob/slider positions via HID                       │
│  • Controls volume of each virtual device                    │
│  • Shows audio activity in React UI                          │
└─────────────────────────────┬───────────────────────────────┘
                              │ CoreAudio APIs
┌─────────────────────────────▼───────────────────────────────┐
│              PCPanelAudio.driver (HAL Plugin)                │
│  • Creates 9 virtual output devices                          │
│  • Apps output audio to assigned virtual device              │
│  • Audio passes through to real output with volume control   │
└─────────────────────────────────────────────────────────────┘
```

## Troubleshooting

### Virtual devices not appearing

1. Ensure the driver is installed: `ls /Library/Audio/Plug-Ins/HAL/ | grep PCPanel`
2. Restart Core Audio: `sudo launchctl kickstart -k system/com.apple.audio.coreaudiod`
3. Check system logs: `log show --predicate 'subsystem == "com.apple.audio"' --last 5m`

### App can't connect to hardware

1. Ensure PC Panel Pro is connected via USB
2. Check if another app is using the device
3. Try unplugging and reconnecting the device

### Build errors

1. Ensure Xcode Command Line Tools are installed: `xcode-select --install`
2. Ensure CMake is installed: `brew install cmake`
3. Re-run setup: `rm -rf libASPL && npm run setup`

## License

MIT
