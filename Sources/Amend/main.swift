import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AmendCore
import AmendApp

@main
struct AmendMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appViewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            MainAppView(appViewModel: appViewModel)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    appDelegate.openURLHandler = { url in
                        if url.pathExtension.lowercased() == "amend" {
                            try? appViewModel.loadProject(from: url)
                        } else if ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
                            appViewModel.importMedia(from: url)
                        }
                    }
                    let args = CommandLine.arguments.dropFirst()
                    if let filePath = args.first(where: { !$0.hasPrefix("-") }) {
                        let url = URL(fileURLWithPath: filePath)
                        if url.pathExtension.lowercased() == "amend" {
                            try? appViewModel.loadProject(from: url)
                        } else if ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
                            appViewModel.importMedia(from: url)
                        }
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Media...") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie]
                    if panel.runModal() == .OK, let url = panel.url {
                        appViewModel.importMedia(from: url)
                    }
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open Project...") {
                    let panel = NSOpenPanel()
                    if let uti = UTType(filenameExtension: "amend") {
                        panel.allowedContentTypes = [uti]
                    }
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = true
                    panel.title = "Open Amend Project"
                    if panel.runModal() == .OK, let url = panel.url {
                        do {
                            try appViewModel.loadProject(from: url)
                        } catch {
                            appViewModel.errorMessage = "Failed to open project: \(error.localizedDescription)"
                            appViewModel.statusMessage = "Project load failed"
                        }
                    }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Save Project...") {
                    let panel = NSSavePanel()
                    if let uti = UTType(filenameExtension: "amend") {
                        panel.allowedContentTypes = [uti]
                    }
                    panel.nameFieldStringValue = "Recording.amend"
                    panel.title = "Save Amend Project"
                    if panel.runModal() == .OK, let url = panel.url {
                        do {
                            try appViewModel.saveProject(to: url)
                        } catch {
                            appViewModel.errorMessage = "Failed to save project: \(error.localizedDescription)"
                            appViewModel.statusMessage = "Project save failed"
                        }
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(appViewModel.sourceMediaURL == nil)

                Button("Export Video...") {
                    appViewModel.prepareExport()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(appViewModel.sourceMediaURL == nil)
            }

            CommandMenu("Transport") {
                Button(appViewModel.timelineViewModel.clock.isPlaying ? "Pause" : "Play") {
                    appViewModel.timelineViewModel.clock.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Step Forward 1 Frame") {
                    appViewModel.timelineViewModel.clock.stepForward(by: 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Button("Step Backward 1 Frame") {
                    appViewModel.timelineViewModel.clock.stepBackward(by: 1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
            }

            CommandMenu("Narration") {
                Button("Synthesize Current Cue") {
                    if let id = appViewModel.selectedCueID {
                        Task {
                            try? await appViewModel.synthesizeCue(id: id, providerType: appViewModel.selectedProviderType)
                        }
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(appViewModel.selectedCueID == nil)

                Button("Fix Grammar") {
                    if let id = appViewModel.selectedCueID, let cue = appViewModel.cues.first(where: { $0.id == id }) {
                        appViewModel.scriptEditorViewModel.triggerRewrite(cueText: cue.text, action: .fixGrammar, title: "Fix Grammar")
                    }
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(appViewModel.selectedCueID == nil)

                Button("Rewrite to Fit") {
                    if let id = appViewModel.selectedCueID, let cue = appViewModel.cues.first(where: { $0.id == id }) {
                        appViewModel.scriptEditorViewModel.triggerRewrite(cueText: cue.text, action: .rewriteToFit(targetDuration: cue.duration), title: "Rewrite to Fit")
                    }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(appViewModel.selectedCueID == nil)

                Button("Split Cue at Playhead") {
                    try? appViewModel.timelineViewModel.splitCueAtPlayhead()
                }
                .keyboardShortcut("s", modifiers: [])
                .disabled(appViewModel.cues.isEmpty)

                Divider()

                Button("Select Next Cue") {
                    if let id = appViewModel.selectedCueID, let idx = appViewModel.cues.firstIndex(where: { $0.id == id }), idx + 1 < appViewModel.cues.count {
                        let next = appViewModel.cues[idx + 1]
                        appViewModel.selectedCueID = next.id
                        appViewModel.timelineViewModel.seek(to: next.start)
                    } else if !appViewModel.cues.isEmpty {
                        appViewModel.selectedCueID = appViewModel.cues[0].id
                        appViewModel.timelineViewModel.seek(to: appViewModel.cues[0].start)
                    }
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(appViewModel.cues.isEmpty)

                Button("Select Previous Cue") {
                    if let id = appViewModel.selectedCueID, let idx = appViewModel.cues.firstIndex(where: { $0.id == id }), idx > 0 {
                        let prev = appViewModel.cues[idx - 1]
                        appViewModel.selectedCueID = prev.id
                        appViewModel.timelineViewModel.seek(to: prev.start)
                    }
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(appViewModel.cues.isEmpty)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var openURLHandler: ((URL) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        openURLHandler?(url)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
