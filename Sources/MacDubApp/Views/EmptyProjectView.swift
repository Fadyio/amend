import SwiftUI
import UniformTypeIdentifiers

public struct EmptyProjectView: View {
    public let onOpenMedia: () -> Void
    public let onOpenProject: () -> Void

    public init(
        onOpenMedia: @escaping () -> Void,
        onOpenProject: @escaping () -> Void
    ) {
        self.onOpenMedia = onOpenMedia
        self.onOpenProject = onOpenProject
    }

    public var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(MacDubTheme.accent)

                VStack(spacing: 6) {
                    Text("MacDub")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Repair your hackathon narration\nwithout re-recording your demo.")
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                Button(action: onOpenMedia) {
                    Label("Open Recording...", systemImage: "video.fill")
                        .frame(minWidth: 150)
                }
                .buttonStyle(GlassButtonStyle(isProminent: true))
                .controlSize(.large)

                Button(action: onOpenProject) {
                    Label("Open Project...", systemImage: "doc.badge.gearshape")
                        .frame(minWidth: 150)
                }
                .buttonStyle(GlassButtonStyle())
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacDubTheme.wellGraphite)
    }
}

public struct TranscribingStateView: View {
    public let statusMessage: String

    public init(statusMessage: String) {
        self.statusMessage = statusMessage
    }

    public var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.3)
                .controlSize(.regular)

            VStack(spacing: 4) {
                Text("Analyzing narration…")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(statusMessage.isEmpty ? "Transcribing locally with Parakeet" : statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacDubTheme.wellGraphite)
    }
}
