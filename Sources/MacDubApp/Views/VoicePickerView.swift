import SwiftUI
import MacDubCore

public struct VoicePickerView: View {
    @Binding public var selectedProvider: SynthesisProviderType
    public let referenceVoice: ReferenceVoice?
    public let onOpenSettings: () -> Void

    public init(
        selectedProvider: Binding<SynthesisProviderType>,
        referenceVoice: ReferenceVoice? = nil,
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self._selectedProvider = selectedProvider
        self.referenceVoice = referenceVoice
        self.onOpenSettings = onOpenSettings
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
