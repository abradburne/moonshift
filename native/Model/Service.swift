import Foundation
import Security

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
    /// Held while this copy answers agents, so a second copy of Moonshift cannot share the port.
    private var agentLock: Int32 = -1
    private var seen: Int?
    /// Why agents cannot connect, when the port is taken.
    private(set) var agentProblem: String?
    /// Called on the main actor soon after a cover or job changes.
    var onChange: (() -> Void)?
    private var changePending = false

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

    /// Opens the library, away from the main thread, and starts the runner and the agent endpoint.
    func start() async throws -> Health {
        if library == nil {
            let paths = paths
            let (library, orphans) = try await Task.detached(priority: .userInitiated) {
                let library = try Library(paths: paths)
                return (library, library.markInterrupted())
            }.value
            let runner = JobRunner(library: library)
            runner.eject(orphans)
            library.onChanged = { [weak self] in Task { @MainActor in self?.changed() } }
            self.library = library
            self.runner = runner
            for file in library.unreadable { note("Could not read \(file); it is left as it is.") }
            startAgents(library)
        }
        seen = nil
        return await health()
    }

    /// Changes arrive in bursts while a cover renders; the app hears about them a few times a second at most.
    private func changed() {
        guard !changePending else { return }
        changePending = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            changePending = false
            onChange?()
        }
    }

    // MARK: Agents

    /// What an agent must send as `Authorization: Bearer …`. Kept in the library folder,
    /// readable only by this user, so a connected agent keeps working across launches.
    var agentToken: String { token.value }
    /// Read by the agent endpoint off the main thread.
    private let token = SharedText()
    private var tokenFile: URL { root.appendingPathComponent(".runtime/agent-token") }

    private func loadAgentToken() {
        if let stored = try? String(contentsOf: tokenFile, encoding: .utf8).trimmed, stored.count >= 32 {
            token.value = stored
        } else {
            resetAgentToken()
        }
    }

    /// A new token: agents connected with the old one must be added again.
    func resetAgentToken() {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token.value = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tokenFile.path, contents: Data(agentToken.utf8), attributes: [.posixPermissions: 0o600])
    }

    /// One copy of Moonshift answers agents; a second would split their requests between two libraries.
    private func claimAgentPort() -> Bool {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("moonshift-agents-\(port).lock")
        let descriptor = Darwin.open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return true }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return false }
        agentLock = descriptor
        return true
    }

    private func startAgents(_ library: Library) {
        guard claimAgentPort() else {
            agentProblem = "Agents cannot connect to this copy: another copy of Moonshift is already answering them on port \(port)."
            note(agentProblem ?? "")
            return
        }
        loadAgentToken()
        let tools = AgentTools(library: library)
        let token = token
        do {
            let server = try LoopbackServer(port: port) { method, path, headers, body in
                guard path == "/mcp" else { return (404, [:], nil) }
                guard method == "POST" else { return (405, ["Allow": "POST"], nil) }
                guard LoopbackServer.authorized(headers, token: token.value) else {
                    let refusal = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Moonshift needs its agent token. Copy the command in Moonshift › Settings › Agents."}}"#
                    return (401, ["Content-Type": "application/json", "WWW-Authenticate": "Bearer"], Data(refusal.utf8))
                }
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
    /// Ejecting an engine can take seconds, so it happens away from the main thread.
    func stop() async {
        agents?.stop()
        guard let runner else { return }
        await Task.detached { runner.shutdown() }.value
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

    /// What is installed and how much memory is free, read away from the main thread.
    func health() async -> Health {
        let paths = paths
        let library = library
        return await Task.detached {
            Health(root: paths.root.path, models: ["covers": paths.coversInstalled, "lookup": paths.lookupInstalled],
                   engines: Dictionary(uniqueKeysWithValues: Quality.allCases.map { ($0.rawValue, paths.installed($0.rawValue)) }),
                   memory: library?.memory() ?? Machine.memory(), unreadable: library?.unreadable.count ?? 0)
        }.value
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
    func releaseImport(_ source: String) { library?.releaseImport(source) }

    /// Checks a recording can be read and is short enough, then copies it into the
    /// library away from the main thread. Returns its path there and what it is.
    func importAudio(_ url: URL) async throws -> (source: String, details: SongDetails) {
        let library = try open()
        let details = try await SongLookup.details(of: url.resolvingSymlinksInPath(), name: url.lastPathComponent)
        let source = try await Task.detached(priority: .userInitiated) { try library.importAudio(url) }.value
        return (source, details)
    }

    func details(_ source: String, name: String) async throws -> SongDetails {
        try await SongLookup.details(of: try open().resolve(source), name: name)
    }

    func identify(_ source: String) async throws -> SongDetails {
        let file = try open().resolve(source)
        return try await SongLookup.identify(file, paths: paths)
    }
}

/// A string several threads read and one writes.
final class SharedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    var value: String {
        get { lock.withLock { text } }
        set { lock.withLock { text = newValue } }
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
