# Amend

Amend is a native macOS 26+ transcript-driven narration repair app for screen recordings, demos, and hackathon videos.

Edit what you said without re-recording the entire demo. Amend transcribes narration into fixed-time Cues, lets you rewrite or regenerate individual lines, and preserves synchronization with the original video.

## System Requirements

- **Operating System:** macOS 26.0 or later
- **Architecture:** Apple Silicon (M-series)
- **Frameworks:** Apple Foundation Models (`FoundationModels`), Core ML, AVFoundation, SwiftUI Liquid Glass (`glassEffect`, `GlassEffectContainer`)

## Quick Start

```bash
git clone https://github.com/Fadyio/amend.git
cd amend

make app
open dist/Amend.app
```

## Running Amend

### Development Mode
```bash
make run
```

### Build Double-Clickable App
```bash
make app
```
Output:
```text
dist/Amend.app
```

### Build and Launch
```bash
make open
```

### Install Locally
```bash
make install
```
The installed app is available at `~/Applications/Amend.app` by default.

For an optional system-wide Applications install:
```bash
make install INSTALL_DIR=/Applications
```

## Project Documents

Amend uses `.amend` Project Bundles (registered with macOS as document type `com.fady.amend.project`, display name **Amend Project**). Project bundles can be opened and saved from within the app via **File → Open Project...** (`Cmd+Shift+O`) and **File → Save Project...** (`Cmd+S`), or opened directly from Finder.

## Build Automation

* `make help`: Show available targets
* `make run`: Run development binary (`swift run Amend`)
* `make build`: Compile release binary (`swift build -c release --product Amend`)
* `make test`: Run deterministic test suite (`swift test --no-parallel`)
* `make app`: Package into `dist/Amend.app`
* `make open`: Build and open `dist/Amend.app`
* `make install`: Install to `~/Applications/Amend.app` (or custom `INSTALL_DIR`)
* `make dmg`: Create standalone disk image `dist/Amend.dmg`
* `make clean`: Clean `dist/` and build artifacts
