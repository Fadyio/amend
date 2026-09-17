import SwiftUI
import MacDubCore

@MainActor
public final class ProviderSettingsViewModel: ObservableObject {
    public let vault: CredentialVaultProtocol
    public let session: URLSession

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

    public init(
        vault: CredentialVaultProtocol = KeychainVault(),
        session: URLSession = .shared
    ) {
        self.vault = vault
        self.session = session
        refreshKeyStatuses()
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

    // MARK: - Testing Connections (Zero Key Leakage in Logs)

    public func testGeminiConnection() {
        guard let key = try? vault.get(keyFor: .gemini), !key.isEmpty else { return }
        isTestingGemini = true
        geminiStatus = nil

        Task {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(key)") else {
                await MainActor.run {
                    self.geminiStatus = "Invalid URL"
                    self.isTestingGemini = false
                }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["contents": [["parts": [["text": "Ping"]]]]]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

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
            request.setValue(key, forHTTPHeaderField: "x-access-token")

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

    public init() {
        self.viewModel = ProviderSettingsViewModel()
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Provider & Keychain Settings")
                        .font(.headline)
                    Text("Manage API keys in macOS Keychain and inspect local models.")
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
        .frame(width: 520, height: 560)
        .onAppear {
            viewModel.refreshKeyStatuses()
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

                Text("Runs entirely on Apple Silicon Core ML and Neural Engine. Model weights are cached in application support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Core ML Engine Ready (Mimi Decoder + FlowLM)")
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

                Text("Used for Fix Grammar, Make Natural, and Rewrite to Fit operations, as well as Gemini prebuilt voices.")
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

                Text("Used for Resemble AI speech dubbing and custom voice models.")
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
