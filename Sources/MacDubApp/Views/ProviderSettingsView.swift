import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacDubCore

@MainActor
public final class ProviderSettingsViewModel: ObservableObject {
    public let vault: CredentialVaultProtocol
    public let session: URLSession
    public weak var appViewModel: AppViewModel?

    @Published public var elevenLabsKey: String = ""
    @Published public var resembleKey: String = ""
    @Published public var geminiKey: String = ""

    @Published public var elevenLabsConfigured: Bool = false
    @Published public var resembleConfigured: Bool = false
    @Published public var geminiConfigured: Bool = false

    @Published public var elevenLabsStatus: String?
    @Published public var resembleStatus: String?
    @Published public var geminiStatus: String?

    @Published public var isTestingElevenLabs: Bool = false
    @Published public var isTestingResemble: Bool = false
    @Published public var isTestingGemini: Bool = false

    // Reference Voice Fields
    @Published public var referenceVoiceName: String = ""
    @Published public var referenceVoicePath: String = ""
    @Published public var elevenLabsVoiceIDInput: String = ""
    @Published public var resembleVoiceUUIDInput: String = ""
    @Published public var isCloningElevenLabs: Bool = false
    @Published public var voiceActionStatus: String?

    public init(
        vault: CredentialVaultProtocol = KeychainVault(),
        session: URLSession = .shared,
        appViewModel: AppViewModel? = nil
    ) {
        self.vault = vault
        self.session = session
        self.appViewModel = appViewModel
        refreshKeyStatuses()
        loadVoiceState()
    }

    public func loadVoiceState() {
        if let refVoice = appViewModel?.referenceVoice {
            self.referenceVoiceName = refVoice.name
            self.referenceVoicePath = refVoice.audioRelativePath
            self.elevenLabsVoiceIDInput = refVoice.elevenLabsVoiceID ?? ""
            self.resembleVoiceUUIDInput = refVoice.resembleVoiceUUID ?? ""
        }
    }

    public func refreshKeyStatuses() {
        elevenLabsConfigured = vault.has(keyFor: .elevenLabs)
        resembleConfigured = vault.has(keyFor: .resemble)
        geminiConfigured = vault.has(keyFor: .gemini)
    }

    public func saveKey(_ key: String, for service: ServiceKey) {
        do {
            try vault.save(key: key, for: service)
            refreshKeyStatuses()
        } catch {
            print("Failed to save key: \(error.localizedDescription)")
        }
    }

    public func deleteKey(for service: ServiceKey) {
        do {
            try vault.delete(keyFor: service)
            refreshKeyStatuses()
        } catch {
            print("Failed to delete key: \(error.localizedDescription)")
        }
    }

    // MARK: - Reference Voice Actions

    public func importReferenceVoiceFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .audio, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Select Reference Voice Recording (.wav, .m4a)"

        if panel.runModal() == .OK, let url = panel.url {
            let voiceName = referenceVoiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? url.deletingPathExtension().lastPathComponent
                : referenceVoiceName
            do {
                try appViewModel?.setReferenceVoice(name: voiceName, audioURL: url)
                self.referenceVoiceName = voiceName
                self.referenceVoicePath = url.lastPathComponent
                self.voiceActionStatus = "Reference voice imported successfully."
            } catch {
                self.voiceActionStatus = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    public func saveVoiceIDs() {
        if let appVM = appViewModel {
            let elID = elevenLabsVoiceIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !elID.isEmpty {
                appVM.setElevenLabsVoiceID(elID)
            }
            let resUUID = resembleVoiceUUIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !resUUID.isEmpty {
                appVM.setResembleVoiceUUID(resUUID)
            }
            self.voiceActionStatus = "Voice configuration updated."
        }
    }

    public func cloneToElevenLabs() {
        guard let appVM = appViewModel else { return }
        isCloningElevenLabs = true
        voiceActionStatus = nil

        Task {
            do {
                let name = referenceVoiceName.isEmpty ? "MacDub Clone" : referenceVoiceName
                let id = try await appVM.cloneElevenLabsVoice(name: name)
                await MainActor.run {
                    self.elevenLabsVoiceIDInput = id
                    self.voiceActionStatus = "Cloned to ElevenLabs! Voice ID: \(id)"
                    self.isCloningElevenLabs = false
                }
            } catch {
                await MainActor.run {
                    self.voiceActionStatus = "ElevenLabs clone failed: \(error.localizedDescription)"
                    self.isCloningElevenLabs = false
                }
            }
        }
    }

    // MARK: - Testing Connections (Header-Based Auth & Zero Key Leakage)

    public func testGeminiConnection() {
        guard let key = try? vault.get(keyFor: .gemini), !key.isEmpty else { return }
        isTestingGemini = true
        geminiStatus = nil

        Task {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models") else {
                await MainActor.run {
                    self.geminiStatus = "Invalid URL"
                    self.isTestingGemini = false
                }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

            do {
                let (_, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    self.geminiStatus = code == 200 ? "Success (Connected)" : "Error: HTTP \(code)"
                    self.isTestingGemini = false
                }
            } catch {
                await MainActor.run {
                    self.geminiStatus = "Connection Failed"
                    self.isTestingGemini = false
                }
            }
        }
    }

    public func testElevenLabsConnection() {
        guard let key = try? vault.get(keyFor: .elevenLabs), !key.isEmpty else { return }
        isTestingElevenLabs = true
        elevenLabsStatus = nil

        Task {
            guard let url = URL(string: "https://api.elevenlabs.io/v1/user") else {
                await MainActor.run {
                    self.elevenLabsStatus = "Invalid URL"
                    self.isTestingElevenLabs = false
                }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(key, forHTTPHeaderField: "xi-api-key")

            do {
                let (_, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    self.elevenLabsStatus = code == 200 ? "Success (Connected)" : "Error: HTTP \(code)"
                    self.isTestingElevenLabs = false
                }
            } catch {
                await MainActor.run {
                    self.elevenLabsStatus = "Connection Failed"
                    self.isTestingElevenLabs = false
                }
            }
        }
    }

    public func testResembleConnection() {
        guard let key = try? vault.get(keyFor: .resemble), !key.isEmpty else { return }
        isTestingResemble = true
        resembleStatus = nil

        Task {
            guard let url = URL(string: "https://app.resemble.ai/api/v2/projects") else {
                await MainActor.run {
                    self.resembleStatus = "Invalid URL"
                    self.isTestingResemble = false
                }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

            do {
                let (_, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    self.resembleStatus = code == 200 ? "Success (Connected)" : "Error: HTTP \(code)"
                    self.isTestingResemble = false
                }
            } catch {
                await MainActor.run {
                    self.resembleStatus = "Connection Failed"
                    self.isTestingResemble = false
                }
            }
        }
    }
}

@MainActor
public struct ProviderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject public var viewModel: ProviderSettingsViewModel

    public init(viewModel: ProviderSettingsViewModel) {
        self.viewModel = viewModel
    }

    public init(appViewModel: AppViewModel? = nil) {
        self.viewModel = ProviderSettingsViewModel(appViewModel: appViewModel)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice & Provider Settings")
                        .font(.headline)
                    Text("Configure Reference Voice, cloud voice IDs, and Keychain API keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Reference Voice Section (Blocker 1 & 5)
                    referenceVoiceSection

                    // PocketTTS Local Model Card
                    pocketTTSSection

                    // Gemini Section
                    geminiSection

                    // ElevenLabs Section
                    elevenLabsSection

                    // Resemble AI Section
                    resembleSection
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 640)
        .onAppear {
            viewModel.refreshKeyStatuses()
            viewModel.loadVoiceState()
        }
    }

    // MARK: - Reference Voice Section
    private var referenceVoiceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "person.wave.2.fill")
                        .foregroundStyle(.blue)
                    Text("Reference Voice Configuration")
                        .font(.subheadline.bold())
                    Spacer()
                    if viewModel.appViewModel?.referenceVoice != nil {
                        Text("Active Voice")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    } else {
                        Text("No Voice Configured")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                }

                Text("Import a clean 10-30 second audio recording of your voice. Used for PocketTTS Core ML cloning and cloud voice cloning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("Voice Name (e.g. Fady Voice)", text: $viewModel.referenceVoiceName)
                        .textFieldStyle(.roundedBorder)

                    Button("Import Audio...") {
                        viewModel.importReferenceVoiceFile()
                    }
                }

                if !viewModel.referenceVoicePath.isEmpty {
                    HStack {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Source file: \(viewModel.referenceVoicePath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Cloud Provider Voice IDs")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("ElevenLabs Voice ID:")
                            .font(.caption)
                            .frame(width: 140, alignment: .leading)
                        TextField("Voice ID", text: $viewModel.elevenLabsVoiceIDInput)
                            .textFieldStyle(.roundedBorder)

                        Button(action: {
                            viewModel.cloneToElevenLabs()
                        }) {
                            if viewModel.isCloningElevenLabs {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Create Clone")
                            }
                        }
                        .disabled(!viewModel.elevenLabsConfigured || viewModel.referenceVoicePath.isEmpty || viewModel.isCloningElevenLabs)
                    }

                    HStack {
                        Text("Resemble Voice UUID:")
                            .font(.caption)
                            .frame(width: 140, alignment: .leading)
                        TextField("voice_uuid", text: $viewModel.resembleVoiceUUIDInput)
                            .textFieldStyle(.roundedBorder)

                        Button("Save UUID") {
                            viewModel.saveVoiceIDs()
                        }
                        .disabled(viewModel.resembleVoiceUUIDInput.isEmpty)
                    }
                }

                if let status = viewModel.voiceActionStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.contains("failed") ? .red : .blue)
                }
            }
            .padding(4)
        }
    }

    // MARK: - PocketTTS Section
    private var pocketTTSSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "cpu")
                        .foregroundStyle(.purple)
                    Text("PocketTTS (Local Voice Clone)")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("Zero Cloud Dependencies")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text("Runs entirely on Apple Silicon Core ML and Neural Engine. Synthesizes using your configured Reference Voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Image(systemName: viewModel.appViewModel?.referenceVoice != nil ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(viewModel.appViewModel?.referenceVoice != nil ? .green : .orange)
                    Text(viewModel.appViewModel?.referenceVoice != nil ? "Cloning Ready with Active Reference Voice" : "Requires Reference Voice configured above")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Gemini Section
    private var geminiSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.blue)
                    Text("Google Gemini (Grammar & Natural TTS)")
                        .font(.subheadline.bold())
                    Spacer()
                    statusBadge(configured: viewModel.geminiConfigured)
                }

                Text("Used for Fix Grammar, Make Natural, and Rewrite to Fit operations (gemini-2.5-flash), as well as Gemini prebuilt voices (gemini-3.1-flash-tts-preview).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    SecureField("Paste Gemini API Key", text: $viewModel.geminiKey)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        viewModel.saveKey(viewModel.geminiKey, for: .gemini)
                        viewModel.geminiKey = ""
                    }
                    .disabled(viewModel.geminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if viewModel.geminiConfigured {
                        Button("Delete", role: .destructive) {
                            viewModel.deleteKey(for: .gemini)
                        }
                    }
                }

                HStack {
                    Button("Test Connection") {
                        viewModel.testGeminiConnection()
                    }
                    .disabled(!viewModel.geminiConfigured || viewModel.isTestingGemini)

                    if viewModel.isTestingGemini {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let status = viewModel.geminiStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status.contains("Success") ? .green : .red)
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - ElevenLabs Section
    private var elevenLabsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "waveform")
                        .foregroundStyle(.orange)
                    Text("ElevenLabs (Cloud Voice Clone)")
                        .font(.subheadline.bold())
                    Spacer()
                    statusBadge(configured: viewModel.elevenLabsConfigured)
                }

                Text("Used for Instant Voice Cloning and cloud speech dubbing via ElevenLabs API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    SecureField("Paste ElevenLabs API Key", text: $viewModel.elevenLabsKey)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        viewModel.saveKey(viewModel.elevenLabsKey, for: .elevenLabs)
                        viewModel.elevenLabsKey = ""
                    }
                    .disabled(viewModel.elevenLabsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if viewModel.elevenLabsConfigured {
                        Button("Delete", role: .destructive) {
                            viewModel.deleteKey(for: .elevenLabs)
                        }
                    }
                }

                HStack {
                    Button("Test Connection") {
                        viewModel.testElevenLabsConnection()
                    }
                    .disabled(!viewModel.elevenLabsConfigured || viewModel.isTestingElevenLabs)

                    if viewModel.isTestingElevenLabs {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let status = viewModel.elevenLabsStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status.contains("Success") ? .green : .red)
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Resemble Section
    private var resembleSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "waveform.circle")
                        .foregroundStyle(.teal)
                    Text("Resemble AI (Cloud Voice Clone)")
                        .font(.subheadline.bold())
                    Spacer()
                    statusBadge(configured: viewModel.resembleConfigured)
                }

                Text("Used for Resemble AI speech dubbing (POST /synthesize with Bearer auth and voice_uuid).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    SecureField("Paste Resemble API Key", text: $viewModel.resembleKey)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        viewModel.saveKey(viewModel.resembleKey, for: .resemble)
                        viewModel.resembleKey = ""
                    }
                    .disabled(viewModel.resembleKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if viewModel.resembleConfigured {
                        Button("Delete", role: .destructive) {
                            viewModel.deleteKey(for: .resemble)
                        }
                    }
                }

                HStack {
                    Button("Test Connection") {
                        viewModel.testResembleConnection()
                    }
                    .disabled(!viewModel.resembleConfigured || viewModel.isTestingResemble)

                    if viewModel.isTestingResemble {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let status = viewModel.resembleStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status.contains("Success") ? .green : .red)
                    }
                }
            }
            .padding(4)
        }
    }

    private func statusBadge(configured: Bool) -> some View {
        Text(configured ? "Keychain Active" : "Not Configured")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(configured ? Color.green.opacity(0.12) : Color.gray.opacity(0.12))
            .foregroundStyle(configured ? Color.green : Color.secondary)
            .clipShape(Capsule())
    }
}
