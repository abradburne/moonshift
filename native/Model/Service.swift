import Foundation

/// The local engine, inside the app: the library of covers and jobs, the runner
/// that makes them, and the endpoint agents reach them through.
@MainActor final class Service {
    /// Models, environments and covers. A build made for a checkout uses that
    /// folder; the packaged app uses its Application Support folder.
    private(set) var root: URL
    /// The transcription helper's Python package and the setup scripts.
    let code: URL
    /// True for the self-contained app, which carries its own engine and uv.
    let isPackaged: Bool
    /// Where agents connect, on the loopback address.
    let port: Int
    private(set) var library: Library?
    private var runner: JobRunner?
    private var agents: LoopbackServer?
    private var seen: Int?
    /// Why agents cannot connect, when the port is taken.
    private(set) var agentProblem: String?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        if let checkout = info["StudioRoot"] as? String {
            root = URL(fileURLWithPath: checkout)
            code = root
            isPackaged = false
        } else {
            root = UserDefaults.standard.string(forKey: Self.libraryKey).map { URL(fileURLWithPath: $0) } ?? Self.defaultLibrary
            code = Bundle.main.resourceURL ?? Bundle.main.bundleURL
            isPackaged = true
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        port = info["StudioPort"] as? Int ?? 8766
    }

    private static let libraryKey = "LibraryFolder"
    static var defaultLibrary: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Moonshift")
    }
    /// Tools shipped inside the packaged app: the music engine and uv.
    var helpers: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers") }
    var paths: Paths { Paths(root: root, code: code, helpers: isPackaged ? helpers : nil) }

    /// Keeps models and covers somewhere else. Only before anything is installed.
    func relocate(to folder: URL) {
        guard isPackaged, library == nil else { return }
        root = folder
        UserDefaults.standard.set(folder.path, forKey: Self.libraryKey)
    }

    var data: URL { root.appendingPathComponent("data") }
    var log: URL { data.appendingPathComponent("moonshift.log") }
    var isInstalled: Bool { paths.anythingInstalled }

    func file(_ relative: String) -> URL { data.appendingPathComponent(relative) }

    // MARK: Lifecycle

    /// Opens the library and starts the runner and the agent endpoint.
    func start() throws -> Health {
        if library == nil {
            let library = try Library(paths: paths)
            library.markInterrupted()
            let runner = JobRunner(library: library)
            self.library = library
            self.runner = runner
            startAgents(library)
        }
        seen = nil
        return health()
    }

    private func startAgents(_ library: Library) {
        let tools = AgentTools(library: library)
        do {
            let server = try LoopbackServer(port: port) { method, path, body in
                guard path == "/mcp" else { return (404, [:], nil) }
                guard method == "POST" else { return (405, ["Allow": "POST"], nil) }
                let reply = await tools.respond(to: body)
                return (reply.status, reply.body == nil ? [:] : ["Content-Type": "application/json"], reply.body)
            }
            server.start { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.agentProblem = "Agents cannot connect: port \(self?.port ?? 0) is in use (\(error.localizedDescription))."
                    self?.note(self?.agentProblem ?? "")
                }
            }
            agents = server
        } catch {
            agentProblem = "Agents cannot connect: \(error.localizedDescription)"
            note(agentProblem ?? "")
        }
    }

    /// Stops whatever is running: the app is quitting, and nothing it started may outlive it.
    func stop() {
        agents?.stop()
        runner?.shutdown()
    }

    private func note(_ line: String) {
        guard let handle = FileHandle.create(log, appending: true) else { return }
        handle.write(Data("\(timestamp()) \(line)\n".utf8))
        try? handle.close()
    }

    // MARK: The library

    private func open() throws -> Library {
        guard let library else { throw ServiceError("The local engine is not running.") }
        return library
    }

    func health() -> Health {
        let paths = paths
        return Health(root: paths.root.path, models: ["covers": paths.coversInstalled, "lookup": paths.lookupInstalled],
                      engines: Dictionary(uniqueKeysWithValues: Quality.allCases.map { ($0.rawValue, paths.installed($0.rawValue)) }),
                      memory: library?.memory() ?? Machine.memory())
    }

    /// Covers and jobs, or nil when nothing changed since the last call.
    func state() -> LibraryState? {
        guard let library, library.revision != seen else { return nil }
        let state = library.state()
        seen = state.revision
        return state
    }

    func estimate(_ project: Project) throws -> RenderEstimate { try open().queuedEstimate(project) }
    func save(_ project: Project) throws -> Project { try open().save(project) }
    func deleteProject(_ id: String) throws { try open().deleteProject(id) }
    func createJob(_ request: JobRequest) throws -> Job { try open().createJob(request) }
    func cancelJob(_ id: String) throws { try open().cancelJob(id) }
    func deleteJob(_ id: String) throws { try open().deleteJob(id) }

    /// Copies a recording into the library, away from the main thread, and returns its path there.
    func importAudio(_ url: URL) async throws -> String {
        let library = try open()
        return try await Task.detached(priority: .userInitiated) { try library.importAudio(url) }.value
    }

    func details(_ source: String, name: String) async throws -> SongDetails {
        try await SongLookup.details(of: try open().resolve(source), name: name)
    }

    func identify(_ source: String) async throws -> SongDetails {
        let file = try open().resolve(source)
        return try await SongLookup.identify(file, paths: paths)
    }
}

extension FileHandle {
    static func create(_ url: URL, appending: Bool) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        if appending { _ = try? handle.seekToEnd() }
        return handle
    }
}
