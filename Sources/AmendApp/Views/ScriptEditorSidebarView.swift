import SwiftUI
import CoreMedia
import AmendCore

public struct IdentifiableRewriteResult: Identifiable {
    public let id = UUID()
    public let result: GrammarRewriteResult
}

@MainActor
public final class ScriptEditorViewModel: ObservableObject {
    public weak var appViewModel: AnyObject?
    private var providerGetter: (() -> SynthesisProviderType)?
    private var providerSetter: ((SynthesisProviderType) -> Void)?

    @Published public var isSynthesizing: Bool = false
    @Published public var isRewriting: Bool = false
    @Published public var activeRewriteResult: GrammarRewriteResult?
    @Published public var activeRewriteActionTitle: String = ""
    @Published public var errorMessage: String?

    public let grammarProvider: GrammarProvider

    public var selectedProvider: SynthesisProviderType {
        get { providerGetter?() ?? .pocketTTS }
        set { providerSetter?(newValue) }
    }

    public func bindProvider(get: @escaping () -> SynthesisProviderType, set: @escaping (SynthesisProviderType) -> Void) {
        self.providerGetter = get
        self.providerSetter = set
    }

    public init(grammarProvider: GrammarProvider = AdaptiveGrammarProvider()) {
        self.grammarProvider = grammarProvider
    }

    public func triggerRewrite(cueText: String, action: GrammarAction, title: String) {
        isRewriting = true
        activeRewriteActionTitle = title
        Task {
            do {
                let result = try await grammarProvider.rewrite(text: cueText, action: action)
                self.isRewriting = false
                self.activeRewriteResult = result
            } catch {
                self.isRewriting = false
                self.errorMessage = error.localizedDescription
            }
        }
    }
}

public struct ScriptEditorSidebarView: View {
    @ObservedObject public var editorViewModel: ScriptEditorViewModel
    @Binding public var selectedProvider: SynthesisProviderType
    @Binding public var cues: [Cue]
    @Binding public var selectedCueID: UUID?
    public let currentTime: CMTime
    public let onSeek: (CMTime) -> Void
    public let onSplitCue: (UUID, CMTime) -> Void
    public let onSynthesizeCue: (UUID, SynthesisProviderType) async throws -> Void
    public let onForceFitCue: (UUID) async throws -> Void
    public let onDiscardCandidate: ((UUID) -> Void)?

    public init(
        editorViewModel: ScriptEditorViewModel,
        selectedProvider: Binding<SynthesisProviderType>,
        cues: Binding<[Cue]>,
        selectedCueID: Binding<UUID?>,
        currentTime: CMTime,
        onSeek: @escaping (CMTime) -> Void,
        onSplitCue: @escaping (UUID, CMTime) -> Void,
        onSynthesizeCue: @escaping (UUID, SynthesisProviderType) async throws -> Void,
        onForceFitCue: @escaping (UUID) async throws -> Void,
        onDiscardCandidate: ((UUID) -> Void)? = nil
    ) {
        self.editorViewModel = editorViewModel
        self._selectedProvider = selectedProvider
        self._cues = cues
        self._selectedCueID = selectedCueID
        self.currentTime = currentTime
        self.onSeek = onSeek
        self.onSplitCue = onSplitCue
        self.onSynthesizeCue = onSynthesizeCue
        self.onForceFitCue = onForceFitCue
        self.onDiscardCandidate = onDiscardCandidate
    }

    private var selectedIndex: Int? {
        guard let id = selectedCueID else { return nil }
        return cues.firstIndex(where: { $0.id == id })
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Sidebar Header
            HStack {
                Image(systemName: "character.bubble")
                    .font(.headline)
                    .foregroundStyle(.blue)
                Text("Script & Narration")
                    .font(.headline)
                Spacer()
                Text("\(cues.count) cues")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Main Split: Cue List (top) + Cue Editor & Actions (bottom)
            VStack(spacing: 0) {
                // Cue Navigation List
                ScrollViewReader { proxy in
                    List(selection: $selectedCueID) {
                        ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                            cueRowView(cue: cue, index: index)
                                .tag(cue.id)
                                .id(cue.id)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .onChange(of: selectedCueID) { _, newID in
                        if let newID = newID {
                            withAnimation {
                                proxy.scrollTo(newID, anchor: .center)
                            }
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: .infinity)

                Divider()

                // Selected Cue Editor
                if let index = selectedIndex, index < cues.count {
                    selectedCueDetailView(index: index)
                        .frame(height: 320)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "cursorarrow.click.2")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("Select a cue to edit narration")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 320)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .sheet(item: Binding<IdentifiableRewriteResult?>(
            get: { editorViewModel.activeRewriteResult.map { IdentifiableRewriteResult(result: $0) } },
            set: { editorViewModel.activeRewriteResult = $0?.result }
        )) { item in
            DiffPreviewView(
                result: item.result,
                actionTitle: editorViewModel.activeRewriteActionTitle,
                onApply: { updatedText in
                    if let index = selectedIndex {
                        cues[index] = cues[index].withUpdatedText(updatedText)
                    }
                    editorViewModel.activeRewriteResult = nil
                },
                onCancel: {
                    editorViewModel.activeRewriteResult = nil
                }
            )
        }
    }

    // MARK: - Cue Row View
    private func cueRowView(cue: Cue, index: Int) -> some View {
        let isSelected = cue.id == selectedCueID
        let isActive = cue.contains(time: currentTime)

        return HStack(alignment: .top, spacing: 10) {
            // Index & Status
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("#\(index + 1)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(isSelected ? .blue : .primary)

                    if isActive {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                    }
                }

                Text(formatTimeRange(cue.timeRange))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 75, alignment: .leading)

            // Text Snippet
            Text(cue.text.isEmpty ? "— (empty silence) —" : cue.text)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Edit State Badge
            statusBadge(for: cue)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedCueID = cue.id
            onSeek(cue.timeRange.start)
        }
    }

    // MARK: - Selected Cue Detail
    private func selectedCueDetailView(index: Int) -> some View {
        let cue = cues[index]
        let durationSec = CMTimeGetSeconds(cue.duration)

        return VStack(alignment: .leading, spacing: 10) {
            // Top Toolbar: Cue Index & Duration
            HStack {
                Text("Cue #\(index + 1)")
                    .font(.headline)
                Text(String(format: "(%.2fs)", durationSec))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                // Split at playhead trigger
                if cue.contains(time: currentTime) {
                    Button(action: {
                        onSplitCue(cue.id, currentTime)
                    }) {
                        Label("Split at Playhead", systemImage: "scissors")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Split this cue slot into two at current playhead timestamp")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            // Editable Script Text Area
            TextEditor(text: Binding(
                get: { cues[index].text },
                set: { newText in
                    if cues[index].text != newText {
                        cues[index] = cues[index].withUpdatedText(newText)
                    }
                }
            ))
            .font(.body)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1))
            .padding(.horizontal, 14)
            .frame(height: 75)

            // Grammar & Rewrite Action Bar
            HStack(spacing: 8) {
                Button("Fix Grammar") {
                    editorViewModel.triggerRewrite(cueText: cue.text, action: .fixGrammar, title: "Fix Grammar")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Make Natural") {
                    editorViewModel.triggerRewrite(cueText: cue.text, action: .makeNatural, title: "Make Natural")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Rewrite to Fit") {
                    editorViewModel.triggerRewrite(cueText: cue.text, action: .rewriteToFit(targetDuration: cue.duration), title: "Rewrite to Fit Slot")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                if cue.text != cue.originalText {
                    Button("Restore") {
                        cues[index] = cues[index].withUpdatedText(cue.originalText)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .help("Restore original transcribed narration")
                }
            }
            .padding(.horizontal, 14)

            // Duration Overflow Alert (ADR-0006)
            if let overflow = cue.overflowDelta, CMTimeGetSeconds(overflow) > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(String(format: "Overflow: +%.2fs exceeds slot", CMTimeGetSeconds(overflow)))
                        .font(.caption.bold())
                        .foregroundStyle(.red)

                    Spacer()

                    Button("Rewrite to Fit") {
                        editorViewModel.triggerRewrite(cueText: cue.text, action: .rewriteToFit(targetDuration: cue.duration), title: "Rewrite to Fit Slot")
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)

                    Button("Force Fit") {
                        Task {
                            do {
                                try await onForceFitCue(cue.id)
                            } catch {
                                await MainActor.run {
                                    editorViewModel.errorMessage = error.localizedDescription
                                }
                            }
                        }
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                    .help("Compress audio using asymmetric time stretching within safe limits")

                    Button("Discard") {
                        onDiscardCandidate?(cue.id)
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .help("Discard candidate audio and restore unedited narration")
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 14)
            }

            if let err = editorViewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    Button(action: { editorViewModel.errorMessage = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 14)
            }

            Divider()

            // Synthesis Controls
            HStack(spacing: 10) {
                Picker("Voice:", selection: $selectedProvider) {
                    ForEach(SynthesisProviderType.allCases, id: \.self) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)

                Button(action: {
                    synthesizeSelectedCue(id: cue.id)
                }) {
                    if editorViewModel.isSynthesizing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Synthesize", systemImage: "waveform")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(editorViewModel.isSynthesizing || cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Helpers
    private func statusBadge(for cue: Cue) -> some View {
        Group {
            if cue.overflowDelta != nil {
                Text("OVERFLOW")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            } else {
                switch cue.editState {
                case .original:
                    EmptyView()
                case .edited:
                    Text("EDITED")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                case .synthesized:
                    Text("DUBBED")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                case .overflowGated:
                    Text("OVERFLOW")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                case .forceFitted:
                    Text("FITTED")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.2))
                        .foregroundStyle(.purple)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func formatTimeRange(_ range: CMTimeRange) -> String {
        let startSec = CMTimeGetSeconds(range.start)
        let endSec = CMTimeGetSeconds(range.end)
        let sMin = Int(startSec) / 60
        let sSec = Int(startSec) % 60
        let eMin = Int(endSec) / 60
        let eSec = Int(endSec) % 60
        return String(format: "%02d:%02d-%02d:%02d", sMin, sSec, eMin, eSec)
    }

    private func synthesizeSelectedCue(id: UUID) {
        editorViewModel.isSynthesizing = true
        Task {
            do {
                try await onSynthesizeCue(id, selectedProvider)
                self.editorViewModel.isSynthesizing = false
            } catch {
                self.editorViewModel.isSynthesizing = false
                self.editorViewModel.errorMessage = error.localizedDescription
            }
        }
    }
}
