import SwiftUI
import CoreMedia
import MacDubCore

public struct TrackPickerView: View {
    public let audioTracks: [AudioTrackInfo]
    @Binding public var designatedNarrationID: Int
    @Binding public var passthroughTrackIDs: Set<Int>
    public let onConfirm: () -> Void

    public init(
        audioTracks: [AudioTrackInfo],
        designatedNarrationID: Binding<Int>,
        passthroughTrackIDs: Binding<Set<Int>>,
        onConfirm: @escaping () -> Void
    ) {
        self.audioTracks = audioTracks
        self._designatedNarrationID = designatedNarrationID
        self._passthroughTrackIDs = passthroughTrackIDs
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.title)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Select Narration Track")
                        .font(.title2.bold())
                    Text("Multiple audio tracks detected. Designate the primary narration track for transcription and voice replacement. All other tracks will pass through untouched.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            List {
                ForEach(audioTracks) { track in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Track \(track.id): \(track.displayName)")
                                    .font(.headline)
                                if track.id == designatedNarrationID {
                                    Text("NARRATION")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue)
                                        .foregroundStyle(.white)
                                        .clipShape(Capsule())
                                } else if passthroughTrackIDs.contains(track.id) {
                                    Text("PASSTHROUGH")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.gray.opacity(0.3))
                                        .foregroundStyle(.primary)
                                        .clipShape(Capsule())
                                }
                            }

                            Text("\(track.formatName) • \(track.channelCount == 1 ? "Mono" : "Stereo") • \(Int(track.sampleRate)) Hz")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Picker("", selection: Binding(
                            get: {
                                if track.id == designatedNarrationID {
                                    return "narration"
                                } else if passthroughTrackIDs.contains(track.id) {
                                    return "passthrough"
                                } else {
                                    return "ignore"
                                }
                            },
                            set: { newRole in
                                if newRole == "narration" {
                                    designatedNarrationID = track.id
                                    passthroughTrackIDs.remove(track.id)
                                } else if newRole == "passthrough" {
                                    if designatedNarrationID == track.id {
                                        // Assign next available
                                        if let next = audioTracks.first(where: { $0.id != track.id }) {
                                            designatedNarrationID = next.id
                                        }
                                    }
                                    passthroughTrackIDs.insert(track.id)
                                } else {
                                    passthroughTrackIDs.remove(track.id)
                                }
                            }
                        )) {
                            Text("Narration (Edit & Dub)").tag("narration")
                            Text("Passthrough (Keep)").tag("passthrough")
                            Text("Ignore").tag("ignore")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(height: 200)

            Divider()

            HStack {
                Spacer()
                Button("Confirm Track Selection") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}
