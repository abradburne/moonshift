import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var studio: Studio?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let studio else { return .terminateNow }
        // The engine runs inside the app, so a cover in progress would be lost.
        if studio.jobs.contains(where: \.active) {
            let alert = NSAlert()
            alert.messageText = "A cover is still being created"
            alert.informativeText = "Quitting now stops it. Takes that already finished are kept."
            alert.addButton(withTitle: "Keep Working")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        Task {
            await studio.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct MoonshiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var studio = Studio()

    var body: some Scene {
        Window("Moonshift", id: "main") {
            RootView(studio: studio)
                .task {
                    delegate.studio = studio
                    await studio.start()
                    #if SNAPSHOT
                    await Snapshot.run(studio)
                    #endif
                }
        }
        .defaultSize(width: 1120, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Cover") { Task { await studio.newCover() } }
                    .keyboardShortcut("n").disabled(!studio.isReady)
                Button("Choose Song…") { studio.chooseSong() }
                    .keyboardShortcut("o").disabled(!studio.isReady || studio.locked)
                Divider()
                Button("Duplicate Cover") { Task { await studio.duplicate(studio.project) } }
                    .keyboardShortcut("d").disabled(!studio.isReady || !studio.hasContent)
            }
            CommandMenu("Cover") {
                ForEach(CoverStep.allCases) { step in
                    Button(step.title) { studio.step = step }
                        .keyboardShortcut(KeyEquivalent(Character("\(step.rawValue + 1)")))
                }
                Divider()
                Button("Create Cover") { Task { await studio.createCover() } }
                    .keyboardShortcut(.return, modifiers: .command).disabled(!studio.canCreate)
                Button(studio.player.playing ? "Pause" : "Play") { studio.player.toggle() }
                    .keyboardShortcut("p").disabled(!studio.player.isLoaded)
            }
            CommandGroup(replacing: .help) {
                Button("Set Up Local Models…") { studio.showsOnboarding = true }.disabled(studio.installer.running)
                Button("Show Moonshift Folder") { NSWorkspace.shared.open(studio.service.root) }
            }
        }

        Settings {
            SettingsView(studio: studio)
        }
    }
}
