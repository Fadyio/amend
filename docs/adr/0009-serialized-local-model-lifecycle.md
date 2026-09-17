# Serialized Local Model Lifecycle for 8GB Apple Silicon

Running Core ML ASR (Parakeet), speech synthesis (PocketTTS), and local LLMs simultaneously quickly exhausts memory and causes swapping on 8GB Apple Silicon Macs. We decided to coordinate all local models through a singleton `LocalModelCoordinator` that enforces mutual exclusion: ASR resources are released after initial transcription before PocketTTS is loaded, heavyweight inference jobs are strictly serialized, and intermediate results are cached to disk so weights do not remain resident.
