import Foundation
import Observation

/// Downloads and builds the local engines by running `scripts/setup-moonshift.sh`,
/// and reports its progress one step at a time.
@MainActor @Observable final class Installer {
    struct Tool: Identifiable, Equatable {
        let id: String
        let name: String
        let purpose: String
        /// The Homebrew formula, when Homebrew can provide it.
        let formula: String?
        var found = false
    }

    struct Step: Identifiable, Equatable {
        enum State { case pending, running, done, failed }
        let id: String
        let title: String
        let detail: String
        var state = State.pending
        /// Share of the download on disk, for steps that fetch model weights.
        var fraction: Double?
    }

    enum Plan: Equatable {
        case engines(Quality)
        case lookup
    }

    /// What a checkout needs to build the music engine. The packaged app needs nothing.
    private(set) var tools: [Tool] = [
        Tool(id: "clang", name: "Xcode Command Line Tools", purpose: "Builds the music engine for your Mac", formula: nil),
        Tool(id: "uv", name: "uv", purpose: "Sets up the private Python runtimes", formula: "uv"),
        Tool(id: "cmake", name: "CMake", purpose: "Builds the music engine", formula: "cmake")
    ]
    private(set) var steps: [Step] = []
    private(set) var running = false
    private(set) var failure: String?
    private(set) var log = ""
    private(set) var homebrew: String?
    private(set) var freeSpace: Int64?

    /// Where everything is installed.
    var root: URL { didSet { checkTools() } }
    @ObservationIgnored private let scripts: URL
    /// Bundled tools, when this is the packaged app.
    @ObservationIgnored private let helpers: URL?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var pending = Data()
    @ObservationIgnored private var lines: [String] = []
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var cancelled = false

    init(root: URL, scripts: URL, helpers: URL?) {
        self.root = root
        self.scripts = scripts
        self.helpers = helpers
        if helpers != nil { tools = [] }
        checkTools()
    }

    /// Homebrew and user-level locations a Finder-launched app does not have on its PATH.
    private static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.cargo/bin", "/usr/bin", "/bin"]

    var missingTools: [Tool] { tools.filter { !$0.found } }
    /// Missing tools Homebrew can install on the user's behalf.
    var installableTools: [Tool] { homebrew == nil ? [] : missingTools.filter { $0.formula != nil } }
    var toolsReady: Bool { missingTools.isEmpty }
    var succeeded: Bool { !steps.isEmpty && steps.allSatisfy { $0.state == .done } }

    /// Approximate download for a fresh install, in bytes.
    static func downloadSize(_ quality: Quality) -> Int64 { musicBytes(quality) + transcriptionBytes + 1_300_000_000 }
    /// The same, as "about 7 GB".
    static func downloadLabel(_ quality: Quality) -> String {
        "about \(Int((Double(downloadSize(quality)) / 1e9).rounded())) GB"
    }
    private static func musicBytes(_ quality: Quality) -> Int64 { (quality == .standard ? 2_665_641_504 : 4_264_195_616) + 265_218_656 }
    private static let transcriptionBytes: Int64 = 2_759_254_075

    func checkTools() {
        let manager = FileManager.default
        func find(_ name: String) -> String? {
            Self.searchPath.map { $0 + "/" + name }.first { manager.isExecutableFile(atPath: $0) }
        }
        homebrew = find("brew")
        for index in tools.indices {
            tools[index].found = tools[index].id == "clang"
                ? manager.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/clang") || manager.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild")
                : find(tools[index].id) != nil
        }
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        freeSpace = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    private func plan(_ plan: Plan, installingTools: Bool) -> [Step] {
        let lookup = Step(id: "lookup", title: "Song identification", detail: "A small helper for optional online lookup")
        guard case .engines(let quality) = plan else { return [lookup] }
        let tools = installingTools ? [Step(id: "tools", title: "Developer tools", detail: "Installs \(installableTools.map(\.name).joined(separator: ", ")) with Homebrew")] : []
        let engine = helpers == nil ? [Step(id: "engine", title: "Music engine", detail: "Compiled for your Mac's GPU · takes a few minutes")] : []
        return tools + engine + [
            Step(id: "music", title: "Music model", detail: "YuE2 \(quality.bits) · \(Self.musicBytes(quality).formatted(.byteCount(style: .file)))"),
            Step(id: "transcriber-runtime", title: "Transcription runtime", detail: "PyTorch, in its own environment"),
            Step(id: "transcriber", title: "Transcription models", detail: "SheetSage2 and MERT · \(Self.transcriptionBytes.formatted(.byteCount(style: .file)))"),
            lookup
        ]
    }

    /// Runs setup to completion. Returns true when every step finished.
    @discardableResult func install(_ plan: Plan, installingTools: Bool = false) async -> Bool {
        guard !running else { return false }
        let withTools = installingTools && !installableTools.isEmpty
        steps = self.plan(plan, installingTools: withTools)
        running = true; failure = nil; log = ""; lines = []; pending = Data(); cancelled = false
        defer { running = false; process = nil; watcher?.cancel(); watcher = nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let argument: String
        switch plan {
        case .engines(let quality): argument = quality.setupArgument
        case .lookup: argument = "lookup"
        }
        var script = scripts.appendingPathComponent("setup-moonshift.sh").path
        #if SNAPSHOT
        script = ProcessInfo.processInfo.environment["MOONSHIFT_SETUP_SCRIPT"] ?? script
        #endif
        process.arguments = [script, argument]
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["MOONSHIFT_HOME"] = root.path
        if let helpers {
            environment["MOONSHIFT_PACKAGED"] = "1"
            environment["MOONSHIFT_UV"] = helpers.appendingPathComponent("uv").path
        }
        environment["PATH"] = (Self.searchPath + [environment["PATH"] ?? ""]).joined(separator: ":")
        if withTools { environment["MOONSHIFT_INSTALL_TOOLS"] = installableTools.compactMap(\.formula).joined(separator: " ") }
        // Progress bars redraw in place; plain output keeps the log readable.
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.receive(data) }
        }
        let quality: Quality? = { if case .engines(let quality) = plan { return quality } else { return nil } }()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.measureDownloads(quality)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        do {
            try process.run()
            self.process = process
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in continuation.resume() }
            }
        } catch {
            failure = error.localizedDescription
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        receive((try? pipe.fileHandleForReading.readToEnd()) ?? Data())
        checkTools()

        if failure == nil, process.terminationStatus == 0 {
            for index in steps.indices { steps[index].state = .done; steps[index].fraction = nil }
            return true
        }
        if let index = steps.firstIndex(where: { $0.state == .running }) ?? steps.firstIndex(where: { $0.state == .pending }) {
            steps[index].state = .failed
        }
        if cancelled {
            failure = "Setup was stopped. Everything downloaded so far is kept, and setup continues from there next time."
        } else if failure == nil {
            // The script's last line says what went wrong, in words.
            failure = lines.last { !$0.trimmed.isEmpty } ?? "Setup could not finish."
        }
        return false
    }

    /// Forgets the last run, so setup starts from its overview again.
    func reset() {
        guard !running else { return }
        steps = []; failure = nil; log = ""
    }

    func cancel() {
        guard running else { return }
        cancelled = true
        process?.terminate()
    }

    private func receive(_ data: Data) {
        pending.append(data)
        // Lines end in a newline, or a carriage return where a tool redraws progress.
        while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
            let redraw = pending[end] == 0x0D
            pending.removeSubrange(pending.startIndex...end)
            if line.hasPrefix("@@step ") {
                begin(String(line.dropFirst(7)).trimmed)
            } else if !line.trimmed.isEmpty {
                if redraw, !lines.isEmpty, lines[lines.count - 1].hasPrefix("\r") { lines.removeLast() }
                lines.append(redraw ? "\r" + line : line)
            }
        }
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        log = lines.suffix(60).map { $0.hasPrefix("\r") ? String($0.dropFirst()) : $0 }.joined(separator: "\n")
    }

    private func begin(_ id: String) {
        guard let current = steps.firstIndex(where: { $0.id == id }) else { return }
        for index in steps.indices where index < current && steps[index].state != .done {
            steps[index].state = .done
            steps[index].fraction = nil
        }
        steps[current].state = .running
    }

    /// Model weights arrive as a few very large files, so bytes on disk are honest progress.
    private func measureDownloads(_ quality: Quality?) async {
        guard let quality, let index = steps.firstIndex(where: { $0.state == .running }) else { return }
        let models = root.appendingPathComponent(".models")
        let targets: ([URL], Int64)
        switch steps[index].id {
        case "music":
            let weight = quality == .standard ? "yue2-3b-q4_0.gguf" : "yue2-3b-q8_0.gguf"
            let folder = models.appendingPathComponent("YuE2-GGUF")
            targets = ([folder.appendingPathComponent(weight), folder.appendingPathComponent("yue2-vae-f16.gguf"), folder.appendingPathComponent(".cache")], Self.musicBytes(quality))
        case "transcriber":
            targets = ([models.appendingPathComponent("SheetSage2"), models.appendingPathComponent("MERT-v2-FullSong")], Self.transcriptionBytes)
        default:
            return
        }
        let bytes = await Task.detached(priority: .utility) { targets.0.reduce(Int64(0)) { $0 + Installer.size(of: $1) } }.value
        if steps.indices.contains(index), steps[index].state == .running {
            steps[index].fraction = min(1, Double(bytes) / Double(targets.1))
        }
    }

    nonisolated private static func size(of url: URL) -> Int64 {
        let resolved = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return Int64((try? resolved.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        var total: Int64 = 0
        let files = FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let file = files?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
