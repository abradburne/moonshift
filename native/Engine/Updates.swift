import Foundation
import Security

/// New versions, as published on the project's GitHub releases: each a disk image
/// holding the signed, notarized app.
enum UpdateFeed {
    static let latest = URL(string: "https://api.github.com/repos/abradburne/moonshift/releases/latest")!
    /// Only an app signed by this team, under this identifier, and notarized by Apple is installed.
    static let requirement = #"anchor apple generic and identifier "jp.co.xenocode.Moonshift" and certificate leaf[subject.OU] = "HVUXZ635F3" and notarized"#

    struct Release: Decodable, Equatable {
        var tag_name: String
        var name: String?
        var body: String?
        var html_url: String
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Asset]

        struct Asset: Decodable, Equatable {
            var name: String
            var browser_download_url: String
            var size: Int?
        }

        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        /// The disk image to install from.
        var image: Asset? { assets.first { $0.name.lowercased().hasSuffix(".dmg") } }
    }

    /// The latest published release, or nil when there is none to offer.
    static func fetch(appVersion: String) async throws -> Release? {
        var request = URLRequest(url: latest, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Moonshift/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError("The update service could not be reached.") }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw ServiceError("The update service could not be reached. Try again later.") }
        let release = try JSONDecoder().decode(Release.self, from: data)
        return release.draft == true || release.prerelease == true ? nil : release
    }

    /// Whether `candidate` is a later version than `current`: "1.10.0" follows "1.9.2".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let (a, b) = (parts(candidate), parts(current))
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x > y }
        }
        return false
    }

    /// Throws unless the app at `url` is Moonshift, signed by its developer, and notarized.
    static func verify(_ url: URL) throws {
        let refused = ServiceError("The downloaded update is not signed and notarized for Moonshift, so it was not installed.")
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw refused }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw refused }
    }

    /// The version an app bundle declares.
    static func version(of app: URL) -> String? {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Mounts a downloaded image, checks the app inside, copies it beside `app` and swaps them.
    /// The image is removed afterwards.
    static func install(_ image: URL, replacing app: URL, newerThan current: String) throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Moonshift-update-" + UUID().uuidString)
        let mount = work.appendingPathComponent("volume")
        try manager.createDirectory(at: mount, withIntermediateDirectories: true)
        defer {
            try? manager.removeItem(at: image)
            try? manager.removeItem(at: work)
        }
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path],
                failure: "The update's disk image could not be opened.")
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], failure: "") }
        let incoming = mount.appendingPathComponent("Moonshift.app")
        try UpdateFeed.verify(incoming)
        guard let version = UpdateFeed.version(of: incoming), UpdateFeed.isNewer(version, than: current) else {
            throw ServiceError("The downloaded update is not newer than this copy of Moonshift.")
        }
        // Copied next to this copy first, so the swap stays on one disk and cannot leave half an app.
        let staged = app.deletingLastPathComponent().appendingPathComponent(".Moonshift-\(version)-\(UUID().uuidString).app")
        try run("/usr/bin/ditto", [incoming.path, staged.path], failure: "The update could not be copied next to Moonshift.")
        do {
            try UpdateFeed.verify(staged)
            _ = try manager.replaceItemAt(app, withItemAt: staged)
        } catch {
            try? manager.removeItem(at: staged)
            throw error is ServiceError ? error : ServiceError("Moonshift could not replace itself: \(error.localizedDescription)")
        }
    }

    private static func run(_ tool: String, _ arguments: [String], failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw ServiceError(failure) }
    }
}
