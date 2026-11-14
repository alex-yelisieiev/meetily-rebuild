import SwiftUI
import AppKit

@main
struct MeetilyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    init() {
        if CommandLine.arguments.contains("--mlx-selftest") { MLXSelfTest.runBlocking() }
    }

    var body: some Scene {
        Window("Meetily", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(app.isRecording ? "Stop Recording" : "New Recording") {
                    Task { await app.toggleRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(app.engineState != .ready)

                Button(app.phase == .paused ? "Resume Recording" : "Pause Recording") {
                    Task { await app.togglePause() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!(app.phase == .recording || app.phase == .paused))

                Divider()
                Button("Import Audio…") { app.chooseAudioToImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(app.engineState != .ready || !app.importAndRetranscribe || app.importJob?.running == true)
            }
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppModel.isRecordingNow
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.isRecordingNow else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A recording is in progress"
        alert.informativeText = "Quitting now stops the recording without saving it as a meeting. Stop the recording first to keep it."
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Quit Anyway")
        alert.buttons.last?.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        EngineClient.shared.stop()
    }
}
