# Native Swift and Core ML Stack Without Python

Running local ML models in desktop apps often relies on embedded Python runtimes or localhost HTTP microservices, which introduce complex installation, process management, and resource overhead. We decided to build purely native Swift using Core ML and the `FluidAudio` package for local ASR, VAD, and PocketTTS voice cloning, combined with native AVFoundation audio units for processing. This keeps the application bundle lean, minimizes background overhead on 8GB Apple Silicon Macs, and eliminates all Python or FFmpeg dependencies.
