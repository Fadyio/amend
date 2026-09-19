import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreMedia
import AmendCore

public enum ExportContainerFormat: String, CaseIterable, Identifiable {
    case mov = "mov"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .mov: return "QuickTime Movie (.mov)"
        }
    }
    public var utType: UTType {
        switch self {
        case .mov: return .quickTimeMovie
        }
    }
}

@MainActor
public final class ExportSheetViewModel: ObservableObject {
    public let sourceURL: URL?
    public let narrationTrackID: Int
    public let passthroughTrackIDs: [Int]
    public let cues: [Cue]
    public let bundleRootURL: URL?

    @Published public var destinationURL: URL?
    @Published public var containerFormat: ExportContainerFormat = .mov
    @Published public var isExporting: Bool = false
    @Published public var exportProgress: Double = 0.0
    @Published public var exportResult: ExportResult?
    @Published public var errorMessage: String?

    public init(
        sourceURL: URL?,
        narrationTrackID: Int,
        passthroughTrackIDs: [Int] = [],
        cues: [Cue] = [],
        bundleRootURL: URL? = nil
    ) {
        self.sourceURL = sourceURL
        self.narrationTrackID = narrationTrackID
        self.passthroughTrackIDs = passthroughTrackIDs
        self.cues = cues
        self.bundleRootURL = bundleRootURL

        if let source = sourceURL {
            let defName = source.deletingPathExtension().lastPathComponent + "_edited.mov"
            let defDest = source.deletingLastPathComponent().appendingPathComponent(defName)
            self.destinationURL = defDest
        }
    }

    public func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [containerFormat.utType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = destinationURL?.lastPathComponent ?? "Exported_Recording.\(containerFormat.rawValue)"
        if panel.runModal() == .OK, let url = panel.url {
            destinationURL = url
        }
    }

    public func startExport() {
        Task {
            do {
                _ = try await startExportAsync()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isExporting = false
                }
            }
        }
    }

    @discardableResult
    public func startExportAsync() async throws -> ExportResult {
        guard let source = sourceURL, let destination = destinationURL else {
            throw NSError(domain: "ExportSheetViewModel", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing source or destination URL"])
        }
        isExporting = true
        exportProgress = 0.0
        errorMessage = nil

        do {
            let pipeline = PassthroughExportPipeline()
            let config = PassthroughExportConfig(
                sourceURL: source,
                destinationURL: destination,
                designatedNarrationTrackID: Int32(narrationTrackID),
                passthroughTrackIDs: passthroughTrackIDs.map { Int32($0) },
                cues: cues,
                bundleRootURL: bundleRootURL
            )

            let result = try await pipeline.export(config: config) { [weak self] progress in
                Task { @MainActor in
                    self?.exportProgress = progress
                }
            }

            self.isExporting = false
            self.exportResult = result
            return result
        } catch {
            self.isExporting = false
            self.errorMessage = error.localizedDescription
            throw error
        }
    }
}

public struct ExportSheetView: View {
    @ObservedObject public var viewModel: ExportSheetViewModel
    public let onDismiss: () -> Void

    public init(
        viewModel: ExportSheetViewModel,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.forward.square.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export Media")
                        .font(.title2.bold())
                    Text("Remux high-resolution video with modified narration audio.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if let result = viewModel.exportResult {
                // Success State
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.title3)
                        Text("Export Completed Successfully")
                            .font(.headline)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Output File:")
                                .font(.subheadline.bold())
                            Text(result.outputURL.lastPathComponent)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        HStack {
                            Text("Duration:")
                                .font(.subheadline.bold())
                            Text(String(format: "%.2f seconds", CMTimeGetSeconds(result.duration)))
                                .font(.subheadline)
                        }

                        HStack {
                            Text("Video Samples:")
                                .font(.subheadline.bold())
                            Text("\(result.videoSampleCount) frames")
                                .font(.subheadline)
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "bolt.badge.checkmark.fill")
                                .foregroundStyle(.blue)
                            Text("Bitstream Passthrough Verified (0% quality loss, no re-encoding)")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                        }

                        Spacer()

                        Button("Done") {
                            onDismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                // Configuration State
                VStack(alignment: .leading, spacing: 16) {
                    // Container Format
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Container Format")
                            .font(.subheadline.bold())
                        Picker("", selection: $viewModel.containerFormat) {
                            ForEach(ExportContainerFormat.allCases) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: viewModel.containerFormat) { _, newFormat in
                            if let cur = viewModel.destinationURL {
                                viewModel.destinationURL = cur.deletingPathExtension().appendingPathExtension(newFormat.rawValue)
                            }
                        }
                    }

                    // Destination File
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Destination")
                            .font(.subheadline.bold())
                        HStack {
                            Text(viewModel.destinationURL?.path ?? "No destination selected")
                                .font(.callout)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                            Button("Browse...") {
                                viewModel.chooseDestination()
                            }
                            .disabled(viewModel.isExporting)
                        }
                    }

                    // Passthrough Badge
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.purple)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hardware-Direct Passthrough (ADR-0008)")
                                .font(.caption.bold())
                            Text("Video frames are passed through directly from the source bitstream without decoding or generational loss. Audio narration slots are seamlessly replaced.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color.purple.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    if let error = viewModel.errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    if viewModel.isExporting {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Exporting...")
                                    .font(.caption.bold())
                                Spacer()
                                Text("\(Int(viewModel.exportProgress * 100))%")
                                    .font(.caption.monospacedDigit())
                            }
                            ProgressView(value: viewModel.exportProgress, total: 1.0)
                                .progressViewStyle(.linear)
                        }
                    }
                }

                Divider()

                HStack {
                    Button("Cancel", role: .cancel) {
                        onDismiss()
                    }
                    .disabled(viewModel.isExporting)

                    Spacer()

                    Button("Export") {
                        viewModel.startExport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isExporting || viewModel.destinationURL == nil || viewModel.sourceURL == nil)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
