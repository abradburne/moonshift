import Darwin
import Foundation

/// A message worth showing as-is: the service writes its errors for people.
struct ServiceError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// The loopback service that runs the models: its process and its HTTP API.
@MainActor final class Service {
    /// Must match `API_VERSION` in `studio/server.py`.
    static let apiVersion = 3

    /// Models, environments and covers. A build made for a checkout uses that
    /// folder; the packaged app uses its Application Support folder.
    private(set) var root: URL
    /// The service's Python package and the setup scripts.
    let code: URL
    /// True for the self-contained app, which carries its own service, engine and uv.
    let isPackaged: Bool
    let port: Int
    private let clientID = UUID().uuidString
    private var process: Process?
    private var revision: String?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

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

    /// Keeps models and covers somewhere else. Only before anything is installed.
    func relocate(to folder: URL) {
        guard isPackaged, process == nil else { return }
        root = folder
        UserDefaults.standard.set(folder.path, forKey: Self.libraryKey)
    }

    var data: URL { root.appendingPathComponent("data") }
    var log: URL { data.appendingPathComponent("server.log") }
    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: python.path) }
    private var python: URL { root.appendingPathComponent(".venv/bin/python") }
    private func url(_ endpoint: String) -> URL { URL(string: "http://127.0.0.1:\(port)/api/\(endpoint)")! }

    func file(_ relative: String) -> URL { data.appendingPathComponent(relative) }

    // MARK: Requests

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 304 else {
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["detail"]
            throw ServiceError(message: (detail as? String) ?? "The local engine could not complete this request.")
        }
        return (data, http)
    }

    private func request(_ endpoint: String, method: String, body: Data? = nil, timeout: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url(endpoint))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    func get<T: Decodable>(_ endpoint: String, timeout: TimeInterval = 30) async throws -> T {
        try JSONDecoder().decode(T.self, from: await perform(request(endpoint, method: "GET", timeout: timeout)).0)
    }

    func post<Body: Encodable, T: Decodable>(_ endpoint: String, _ body: Body, timeout: TimeInterval = 30) async throws -> T {
        let payload = try JSONEncoder().encode(body)
        return try JSONDecoder().decode(T.self, from: await perform(request(endpoint, method: "POST", body: payload, timeout: timeout)).0)
    }

    func send(_ method: String, _ endpoint: String) async throws {
        _ = try await perform(request(endpoint, method: method))
    }

    /// Covers and jobs, or nil when nothing changed since the last call.
    func state() async throws -> ServiceState? {
        var request = request("state?client=\(clientID)", method: "GET", timeout: 10)
        if let revision { request.setValue(revision, forHTTPHeaderField: "If-None-Match") }
        // The service's ETag is the cache; URLSession must not answer for it.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await perform(request)
        if response.statusCode == 304 { return nil }
        let state = try JSONDecoder().decode(ServiceState.self, from: data)
        revision = response.value(forHTTPHeaderField: "ETag")
        return state
    }

    /// Streams the file from disk and returns its path inside the data folder.
    func upload(_ file: URL) async throws -> String {
        var request = request("import", method: "POST", timeout: 300)
        // Only the extension matters to the service; names may not be ASCII.
        request.setValue("audio." + file.pathExtension.lowercased(), forHTTPHeaderField: "x-filename")
        let (data, response) = try await session.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let source = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["source"] else {
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["detail"] as? String
            throw ServiceError(message: detail ?? "This audio could not be imported.")
        }
        return source
    }

    // MARK: Lifecycle

    private func health() async -> Health? {
        // The service reports its folder with symlinks resolved; compare like with like.
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        guard let health: Health = try? await get("health", timeout: 2), resolved(health.root) == resolved(root.path) else { return nil }
        return health
    }

    /// Connects to the service for this folder, starting or replacing it as needed.
    func connect() async throws -> Health {
        revision = nil
        if let running = await health() {
            if running.api == Self.apiVersion { return running }
            // Left behind by an older build. Ask it to leave, then start ours.
            try? await send("POST", "shutdown")
            for _ in 0..<40 where await health() != nil { try? await Task.sleep(for: .milliseconds(250)) }
        }
        try launch()
        for _ in 0..<75 {
            if let health = await health(), health.api == Self.apiVersion { return health }
            if process?.isRunning == false { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw ServiceError(message: "The local engine did not start.")
    }

    private func launch() throws {
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = python
        process.arguments = ["-m", "uvicorn", "studio.server:app", "--host", "127.0.0.1", "--port", String(port), "--log-level", "warning"]
        process.currentDirectoryURL = code
        var environment = ProcessInfo.processInfo.environment
        environment["MOONSHIFT_HOME"] = root.path
        // Nothing is written beside the code: inside the app it is sealed by the signature.
        if code != root { environment["PYTHONDONTWRITEBYTECODE"] = "1" }
        environment["HF_HOME"] = root.appendingPathComponent(".cache/huggingface").path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent(".cache").path
        environment["PYTHONUNBUFFERED"] = "1"
        environment["MOONSHIFT_MANAGED"] = "1"
        process.environment = environment
        // Append directly: the log may still be open in a service that is leaving.
        let descriptor = Darwin.open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        process.standardOutput = output
        process.standardError = output
        try process.run()
        self.process = process
    }

    /// Releases this app's claim; the service exits once no app is using it.
    func disconnect() async {
        struct Clients: Decodable { var remaining: Int }
        var request = request("clients/\(clientID)", method: "DELETE", timeout: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let clients = try? JSONDecoder().decode(Clients.self, from: await perform(request).0)
        if clients == nil { process?.terminate() }
    }
}
