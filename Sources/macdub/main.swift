import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacDubCore
import MacDubApp

@main
struct MacDubMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appViewModel = AppViewModel()

    var body: some Scene {
        WindowGroup("macdub") {
            MainAppView(appViewModel: appViewModel)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
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
                    if let uti = UTType(filenameExtension: "voicefix") {
                        panel.allowedContentTypes = [uti]
                    }
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = true
                    panel.title = "Open MacDub Project Bundle"
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
                    if let uti = UTType(filenameExtension: "voicefix") {
                        panel.allowedContentTypes = [uti]
                    }
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
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
