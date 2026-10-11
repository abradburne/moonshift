#if SNAPSHOT
import AppKit
import SwiftUI

/// Development only: drives the app through its screens and saves each as a PNG,
/// so changes to the interface can be reviewed without screen recording access.
/// Built by `scripts/build-moonshift.sh --snapshot`; never part of a normal build.
@MainActor enum Snapshot {
    static func run(_ studio: Studio) async {
        let settings: [String: String] = ProcessInfo.processInfo.environment
        guard let folder = settings["MOONSHIFT_SNAPSHOT_DIR"] else { return }
        let scenes = (settings["MOONSHIFT_SNAPSHOT"] ?? "song,style,create").split(separator: ",").map(String.init)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        func settle(_ seconds: Double = 0.8) async { try? await Task.sleep(for: .seconds(seconds)) }
        func capture(_ name: String, window: NSWindow? = nil) {
            guard let window = window ?? NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) ?? NSApp.mainWindow,
                  let view = window.contentView?.superview ?? window.contentView,
                  let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        await settle(1.5)
        for scene in scenes {
            switch scene {
            case "song", "style", "create":
                studio.step = CoverStep.allCases.first { $0.title.lowercased() == scene } ?? .song
            case "new":
                await studio.newCover()
            case "onboarding":
                studio.showsOnboarding = true; studio.onboardingSetup = false
            case "setup":
                studio.showsOnboarding = true; studio.onboardingSetup = true
            case "installing":
                studio.showsOnboarding = true; studio.onboardingSetup = true
                Task { await studio.installer.install(.engines(.standard), installingTools: true) }
                await settle(Double(settings["MOONSHIFT_SNAPSHOT_WAIT"] ?? "") ?? 4)
            case "duplicate":
                await studio.duplicate(studio.project)
                studio.project.max_tokens = CoverLength.sketch.rawValue
                await studio.save()
            case "workspace":
                studio.finishOnboarding()
            case "play":
                if let job = studio.takes.first, let track = job.tracks.first { studio.toggle(track, title: job.request.project.title); await settle(2); studio.player.pause() }
            case "settings":
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                await settle(1.2)
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }) ?? NSApp.keyWindow {
                    capture("settings", window: window)
                    window.close()
                }
                continue
            case "make":
                // A real cover, start to finish, with a frame every few seconds.
                studio.step = .create
                await studio.createCover()
                var frame = 0
                repeat {
                    await settle(Double(settings["MOONSHIFT_SNAPSHOT_WAIT"] ?? "") ?? 5)
                    frame += 1
                    capture(String(format: "make-%03d", frame))
                } while studio.locked && frame < 400
                await settle(1.5)
            default:
                continue
            }
            await settle()
            capture(scene)
        }
        await studio.shutdown()
        exit(0)
    }
}
#endif
