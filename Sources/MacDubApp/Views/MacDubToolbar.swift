import SwiftUI
import UniformTypeIdentifiers
import MacDubCore

public struct MacDubToolbar: View {
    public let sourceURL: URL?
    public let projectBundleURL: URL?
    public let isProcessing: Bool
    public let statusMessage: String
    public let hasUnsavedChanges: Bool
    public let selectedProvider: SynthesisProviderType
    public let isInspectorVisible: Bool
    public let onOpenMedia: () -> Void
    public let onOpenProject: () -> Void
    public let onSaveProject: () -> Void
    public let onExport: () -> Void
    public let onOpenSettings: () -> Void
    public let onToggleInspector: () -> Void

    public init(
        sourceURL: URL?,
        projectBundleURL: URL?,
        isProcessing: Bool,
        statusMessage: String,
        hasUnsavedChanges: Bool = false,
        selectedProvider: SynthesisProviderType = .pocketTTS,
        isInspectorVisible: Bool = true,
        onOpenMedia: @escaping () -> Void,
        onOpenProject: @escaping () -> Void,
        onSaveProject: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onToggleInspector: @escaping () -> Void = {}
    ) {
        self.sourceURL = sourceURL
        self.projectBundleURL = projectBundleURL
        self.isProcessing = isProcessing
        self.statusMessage = statusMessage
        self.hasUnsavedChanges = hasUnsavedChanges
        self.selectedProvider = selectedProvider
        self.isInspectorVisible = isInspectorVisible
        self.onOpenMedia = onOpenMedia
        self.onOpenProject = onOpenProject
        self.onSaveProject = onSaveProject
        self.onExport = onExport
        self.onOpenSettings = onOpenSettings
        self.onToggleInspector = onToggleInspector
    }

    public var body: some View {
        HStack(spacing: 12) {
            // App Branding
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(MacDubTheme.accent)

                Text("MacDub")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
            }

            Divider()
                .frame(height: 16)

            // Primary File Actions (Open, Save, Export)
            GlassEffectContainer {
                HStack(spacing: 6) {
                    Menu {
                        Button("Open Recording...", action: onOpenMedia)
                            .keyboardShortcut("o", modifiers: .command)

                        Button("Open Project Bundle...", action: onOpenProject)
                            .keyboardShortcut("o", modifiers: [.command, .shift])
                    } label: {
                        Label("Open", systemImage: "folder")
                    }
                    .buttonStyle(GlassButtonStyle())

                    Button(action: onSaveProject) {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(sourceURL == nil)

                    Button(action: onExport) {
                        Label("Export...", systemImage: "arrow.up.forward.square.fill")
                    }
                    .buttonStyle(GlassButtonStyle(isProminent: true))
                    .disabled(sourceURL == nil)
                }
            }

            Spacer()

            // Center Project Title, Saved/Unsaved state, and Status (Phase 4 & 7)
            HStack(spacing: 8) {
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }

                VStack(alignment: .center, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(projectTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)

                        if hasUnsavedChanges {
                            Text("Edited")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 5) {
                        Text(statusMessage)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)

                        Text("•")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)

                        Text(providerDisplayName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(MacDubTheme.accent)
                    }
                }
            }

            Spacer()

            // Settings & Inspector Toggles
            GlassEffectContainer {
                HStack(spacing: 6) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(GlassButtonStyle())
                    .help("Provider credentials & settings")

                    Button(action: onToggleInspector) {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 12))
                            .foregroundStyle(isInspectorVisible ? MacDubTheme.accent : .secondary)
                    }
                    .buttonStyle(GlassButtonStyle())
                    .help("Toggle Inspector & Video Reference Monitor")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular)
    }

    private var projectTitle: String {
        if let bundle = projectBundleURL {
            return bundle.deletingPathExtension().lastPathComponent
        }
        if let source = sourceURL {
            return source.lastPathComponent
        }
        return "Untitled Project"
    }

    private var providerDisplayName: String {
        switch selectedProvider {
        case .pocketTTS:
            return "PocketTTS"
        case .elevenLabs:
            return "ElevenLabs"
        case .geminiTTS:
            return "Gemini"
        case .resemble:
            return "Resemble"
        }
    }
}

// MARK: - Native macOS Unified Toolbar Content

public struct MacDubToolbarContent: ToolbarContent {
    public let sourceURL: URL?
    public let projectBundleURL: URL?
    public let isProcessing: Bool
    public let statusMessage: String
    public let hasUnsavedChanges: Bool
    public let selectedProvider: SynthesisProviderType
    public let isInspectorVisible: Bool
    public let onOpenMedia: () -> Void
    public let onOpenProject: () -> Void
    public let onSaveProject: () -> Void
    public let onExport: () -> Void
    public let onOpenSettings: () -> Void
    public let onToggleInspector: () -> Void

    public init(
        sourceURL: URL?,
        projectBundleURL: URL?,
        isProcessing: Bool,
        statusMessage: String,
        hasUnsavedChanges: Bool = false,
        selectedProvider: SynthesisProviderType = .pocketTTS,
        isInspectorVisible: Bool = true,
        onOpenMedia: @escaping () -> Void,
        onOpenProject: @escaping () -> Void,
        onSaveProject: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onToggleInspector: @escaping () -> Void = {}
    ) {
        self.sourceURL = sourceURL
        self.projectBundleURL = projectBundleURL
        self.isProcessing = isProcessing
        self.statusMessage = statusMessage
        self.hasUnsavedChanges = hasUnsavedChanges
        self.selectedProvider = selectedProvider
        self.isInspectorVisible = isInspectorVisible
        self.onOpenMedia = onOpenMedia
        self.onOpenProject = onOpenProject
        self.onSaveProject = onSaveProject
        self.onExport = onExport
        self.onOpenSettings = onOpenSettings
        self.onToggleInspector = onToggleInspector
    }

    public var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            GlassEffectContainer {
                HStack(spacing: 4) {
                    Menu {
                        Button("Open Recording...", action: onOpenMedia)
                            .keyboardShortcut("o", modifiers: .command)

                        Button("Open Project Bundle...", action: onOpenProject)
                            .keyboardShortcut("o", modifiers: [.command, .shift])
                    } label: {
                        Label("Open", systemImage: "folder")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .help("Open Recording or Project Bundle (⌘O)")

                    Button(action: onSaveProject) {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(sourceURL == nil)
                    .help("Save Project Bundle (⌘S)")

                    Button(action: onExport) {
                        Label("Export", systemImage: "arrow.up.forward.square.fill")
                    }
                    .buttonStyle(GlassButtonStyle(isProminent: true))
                    .disabled(sourceURL == nil)
                    .help("Export QuickTime Video (⌘E)")
                }
            }
        }

        ToolbarItem(placement: .principal) {
            VStack(alignment: .center, spacing: 1) {
                HStack(spacing: 6) {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    Text(projectTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    if hasUnsavedChanges {
                        Text("Edited")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 5) {
                    Text(statusMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)

                    Text(providerDisplayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MacDubTheme.accent)
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            GlassEffectContainer {
                HStack(spacing: 4) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(GlassButtonStyle())
                    .help("Provider credentials & settings")

                    Button(action: onToggleInspector) {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 12))
                            .foregroundStyle(isInspectorVisible ? MacDubTheme.accent : .secondary)
                    }
                    .buttonStyle(GlassButtonStyle())
                    .help("Toggle Inspector & Video Reference Monitor")
                }
            }
        }
    }

    private var projectTitle: String {
        if let bundle = projectBundleURL {
            return bundle.deletingPathExtension().lastPathComponent
        }
        if let source = sourceURL {
            return source.lastPathComponent
        }
        return "Untitled Project"
    }

    private var providerDisplayName: String {
        switch selectedProvider {
        case .pocketTTS:
            return "PocketTTS"
        case .elevenLabs:
            return "ElevenLabs"
        case .geminiTTS:
            return "Gemini"
        case .resemble:
            return "Resemble"
        }
    }
}

