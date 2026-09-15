import SwiftUI
import AppKit
import PianoCore

@main
struct PianoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: AppModel
    init() {
        InstallationCompatibility.importPreferences(into: .standard)
        do {
            let testing = ["--integration-test", "--playback-test", "--research-test"].contains(where: CommandLine.arguments.contains)
            let root = testing ? FileManager.default.temporaryDirectory.appendingPathComponent("PianoIntegration-\(UUID())") : nil
            let instance = try AppModel(root: root)
            _model = StateObject(wrappedValue: instance)
        }
        catch {
            // A failed workspace must be visible, never silently replaced with an ephemeral one.
            let alert = NSAlert(); alert.messageText = "Piano could not open its workspace"; alert.informativeText = error.localizedDescription; alert.runModal()
            exit(1)
        }
    }
    var body: some Scene {
        Window("Piano", id: "studio") {
            ContentView(model: model)
                .task {
                    delegate.onQuit = { model.shutdown() }
                    if CommandLine.arguments.contains("--playback-test") { await IntegrationCheck.playback(model); return }
                    if !model.connected { await model.connect() }
                    if CommandLine.arguments.contains("--research-test") { await IntegrationCheck.research(model); return }
                    if CommandLine.arguments.contains("--integration-test") { await IntegrationCheck.run(model) }
                }
        }.defaultSize(width: 1340, height: 930).windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .newItem) { Button("New Conversation") { model.newConversation() }.keyboardShortcut("n").disabled(model.busy) }
                CommandGroup(after: .newItem) {
                    Button("Import MIDI…") { model.chooseMIDI() }.keyboardShortcut("o")
                    Button("Export MIDI…") { model.exportMIDI() }.keyboardShortcut("e", modifiers: [.command, .shift])
                }
                CommandGroup(replacing: .appSettings) { Button("Settings…") { model.settingsShown = true }.keyboardShortcut(",") }
                CommandMenu("Piano") {
                    Button("Play / Pause") { model.transport.toggle() }.keyboardShortcut(.space, modifiers: .command)
                    Button("Stop") { model.transport.stop() }.keyboardShortcut(".")
                    Button("Open Memory Folder") { model.openWorkspace() }
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onQuit: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { onQuit?() }
}
