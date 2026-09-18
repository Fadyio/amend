# MacDub

Native macOS speech dubbing, voice cloning, and timeline editing designed exclusively for macOS 26+ on Apple Silicon.

## System Requirements
- **Operating System:** macOS 26.0 or later
- **Architecture:** Apple Silicon (M-series)
- **Frameworks:** Apple Foundation Models (`FoundationModels`), Core ML, AVFoundation, SwiftUI Liquid Glass (`glassEffect`, `GlassEffectContainer`)

## Run MacDub

### Development
```bash
make run
```

### Build a real app
```bash
make app
```
Output:
```text
dist/MacDub.app
```

### Build and launch
```bash
make open
```

### Install locally
```bash
make install
```
The installed app is available at `~/Applications/MacDub.app` by default.

For an optional system-wide Applications install, run:
```bash
make install INSTALL_DIR=/Applications
```

## Project Documents

MacDub uses `.voicefix` Project Bundles (registered with macOS as document type `com.fady.macdub.voicefix`). Project bundles can be opened and saved from within the app via **File → Open Project...** (`Cmd+Shift+O`) and **File → Save Project...** (`Cmd+S`), or opened directly from Finder.

## Build Automation

* `make help`: Show available targets
* `make run`: Run development binary
* `make build`: Compile release binary
* `make test`: Run deterministic test suite
* `make app`: Package into `dist/MacDub.app`
* `make open`: Build and open `dist/MacDub.app`
* `make install`: Install to `~/Applications/MacDub.app` (or custom `INSTALL_DIR`)
* `make dmg`: Create standalone disk image `dist/MacDub.dmg`
* `make clean`: Clean `dist/` and build artifacts
