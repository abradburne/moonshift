import AppKit
import Observation

/// Keeps the self-contained app up to date from its GitHub releases: checks about
/// once a day when allowed, and whenever asked. Installs only a build signed by
/// Moonshift's developer and notarized by Apple, then relaunches into it.
@MainActor @Observable final class Updater {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(UpdateFeed.Release)
        case downloading, installing
        case failed(String)
    }

    /// Only the packaged app updates itself; a checkout build follows its source.
    let enabled: Bool
    let current: String
    private(set) var state = State.idle
    /// The update window is showing.
    var presenting = false
    var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "UpdatesAutomatic") }
    }
    /// The release that was offered, kept while it downloads and installs.
    private(set) var offered: UpdateFeed.Release?

    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "UpdatesLastCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "UpdatesLastCheck") }
    }
    @ObservationIgnored private var skipped: String? {
        get { UserDefaults.standard.string(forKey: "UpdatesSkippedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "UpdatesSkippedVersion") }
    }

    init(enabled: Bool) {
        self.enabled = enabled
        current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        automatic = UserDefaults.standard.object(forKey: "UpdatesAutomatic") as? Bool ?? true
    }

    /// Checks quietly now and then while the app is open, when allowed.
    func start() {
        guard enabled, schedule == nil else { return }
        schedule = Task { [weak self] in
            // Not while the app is still opening.
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                if let self, self.automatic, Date().timeIntervalSince(self.lastCheck ?? .distantPast) > 20 * 3600 {
                    await self.check(quietly: true)
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Looks for a newer release. A quiet check says nothing unless there is one the user has not skipped.
    func check(quietly: Bool = false) async {
        guard enabled, ![.checking, .downloading, .installing].contains(state) else { return }
        if !quietly { state = .checking; presenting = true }
        do {
            let release = try await UpdateFeed.fetch(appVersion: current)
            lastCheck = Date()
            if let release, UpdateFeed.isNewer(release.version, than: current), !(quietly && release.version == skipped) {
                offered = release
                state = .available(release)
                presenting = true
            } else if !quietly {
                state = .upToDate
            } else {
                state = .idle
            }
        } catch {
            state = quietly ? .idle : .failed(error.localizedDescription)
        }
    }

    func skip(_ release: UpdateFeed.Release) {
        skipped = release.version
        dismiss()
    }

    func dismiss() {
        presenting = false
        if case .available = state { return }
        state = .idle
    }

    /// Downloads the release, checks it, puts it in place of this copy, and relaunches.
    func install(_ release: UpdateFeed.Release) async {
        guard enabled, let image = release.image, let address = URL(string: image.browser_download_url) else {
            state = .failed("This release has no disk image to install from.")
            return
        }
        let app = Bundle.main.bundleURL
        // A copy run from the disk image, or moved aside by macOS on first launch, cannot replace itself.
        guard !app.path.contains("/AppTranslocation/"), FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            state = .failed("Moonshift cannot replace itself where it is. Download the update from the release page and drag it to Applications.")
            return
        }
        state = .downloading
        let downloaded: URL
        do {
            var request = URLRequest(url: address, timeoutInterval: 60)
            request.setValue("Moonshift/\(current)", forHTTPHeaderField: "User-Agent")
            let (file, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
                throw ServiceError("The update could not be downloaded. Try again later.")
            }
            // URLSession removes its file once this call returns: keep it.
            downloaded = FileManager.default.temporaryDirectory.appendingPathComponent("Moonshift-\(release.version)-\(UUID().uuidString).dmg")
            try FileManager.default.moveItem(at: file, to: downloaded)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        state = .installing
        let current = current
        do {
            try await Task.detached(priority: .userInitiated) { try UpdateFeed.install(downloaded, replacing: app, newerThan: current) }.value
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        relaunch(app)
    }

    /// Opens the new copy once this one has quit.
    private func relaunch(_ app: URL) {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                            "relaunch", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? waiter.run()
        NSApp.terminate(nil)
    }
}
