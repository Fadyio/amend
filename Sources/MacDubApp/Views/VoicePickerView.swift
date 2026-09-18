import SwiftUI
import MacDubCore

public struct VoicePickerView: View {
    @Binding public var selectedProvider: SynthesisProviderType
    public let referenceVoice: ReferenceVoice?
    public let onOpenSettings: () -> Void
    public let onImportReferenceVoice: () -> Void

    public init(
        selectedProvider: Binding<SynthesisProviderType>,
        referenceVoice: ReferenceVoice? = nil,
        onOpenSettings: @escaping () -> Void = {},
        onImportReferenceVoice: @escaping () -> Void = {}
    ) {
        self._selectedProvider = selectedProvider
        self.referenceVoice = referenceVoice
        self.onOpenSettings = onOpenSettings
        self.onImportReferenceVoice = onImportReferenceVoice
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("VOICE ENGINE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Provider credentials & settings")
            }

            // Intentional Engine Selection Menu
            Menu {
                ForEach(SynthesisProviderType.allCases, id: \.self) { provider in
                    Button(action: {
                        selectedProvider = provider
                    }) {
                        HStack {
                            Text(title(for: provider))
                            if provider == selectedProvider {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon(for: selectedProvider))
                        .font(.system(size: 12))
                        .foregroundStyle(MacDubTheme.accent)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(for: selectedProvider))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text(subtitle(for: selectedProvider))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassPanel(cornerRadius: MacDubTheme.cornerRadiusSmall)
            }
            .menuStyle(.borderlessButton)

            // Voice Status / Reference Voice Configuration Card (Phase 11 & 12)
            if selectedProvider == .pocketTTS || selectedProvider == .elevenLabs {
                if let ref = referenceVoice, !ref.name.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "person.wave.2.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(MacDubTheme.statusSuccess)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(ref.name)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.primary)
                            Text("Reference Voice Active")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Change", action: onImportReferenceVoice)
                            .buttonStyle(GlassButtonStyle())
                            .controlSize(.mini)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassPanel(cornerRadius: MacDubTheme.cornerRadiusSmall)
                } else {
                    // Empty state: No reference voice (Phase 11)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "mic.slash.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(MacDubTheme.statusWarning)

                            Text("No Reference Voice")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.primary)
                        }

                        Text("Import a short clean recording to generate narration in your voice.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button(action: onImportReferenceVoice) {
                            Label("Import Reference Voice", systemImage: "arrow.up.circle.fill")
                                .font(.system(size: 10, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GlassButtonStyle(isProminent: true))
                        .controlSize(.small)
                    }
                    .padding(8)
                    .glassPanel(cornerRadius: MacDubTheme.cornerRadiusSmall)
                }
            } else if selectedProvider == .geminiTTS {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(MacDubTheme.accent)
                    Text("Voice: Puck • Natural Cloud Voice")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            } else if selectedProvider == .resemble {
                if let uuid = referenceVoice?.resembleVoiceUUID, !uuid.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10))
                            .foregroundStyle(MacDubTheme.statusSuccess)
                        Text("UUID: \(uuid.prefix(12))...")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                } else {
                    Button(action: onOpenSettings) {
                        Label("Configure Resemble Voice UUID", systemImage: "exclamationmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(MacDubTheme.statusWarning)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func title(for provider: SynthesisProviderType) -> String {
        switch provider {
        case .pocketTTS:
            return "PocketTTS"
        case .elevenLabs:
            return "ElevenLabs"
        case .geminiTTS:
            return "Gemini Voice"
        case .resemble:
            return "Resemble AI"
        }
    }

    private func subtitle(for provider: SynthesisProviderType) -> String {
        switch provider {
        case .pocketTTS:
            return "Local Clone • On-Device Neural Engine"
        case .elevenLabs:
            return "Cloud Clone • Instant Voice Lab"
        case .geminiTTS:
            return "Natural Cloud Voice • Low Latency"
        case .resemble:
            return "Existing Voice UUID • Professional"
        }
    }

    private func icon(for provider: SynthesisProviderType) -> String {
        switch provider {
        case .pocketTTS:
            return "cpu"
        case .elevenLabs:
            return "waveform.badge.mic"
        case .geminiTTS:
            return "sparkles"
        case .resemble:
            return "waveform"
        }
    }
}
