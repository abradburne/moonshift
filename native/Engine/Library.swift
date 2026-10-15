import Foundation

/// Covers and jobs on disk, in the layout every build has used:
/// `data/projects/<id>.json`, `data/jobs/<id>/job.json`, and recordings in
/// `data/imports`. Safe to use from any thread: the app, the job runner and
/// the agent endpoint share one library.
final class Library: @unchecked Sendable {
    let paths: Paths
    var estimator: Estimator
    /// Free memory now. Replaceable, so tests do not depend on what else is open.
    var memory: () -> MemoryState = Machine.memory
    /// Called with a job's id once it is queued, and when it is cancelled.
    var onQueued: (String) -> Void = { _ in }
    var onCancelled: (String) -> Void = { _ in }
    /// Memory held by running jobs, which their ejection will give back to a job waiting behind them.
    var reclaimable: () -> Double = { 0 }

    private let lock = NSRecursiveLock()
    private var projectsByID: [String: Project] = [:]
    private var jobsByID: [String: Job] = [:]
    private var counter = 0

    init(paths: Paths) throws {
        self.paths = paths
        estimator = Estimator(paths: paths)
        for name in ["projects", "jobs", "imports", "exports"] {
            try FileManager.default.createDirectory(at: paths.data.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        load()
    }

    var data: URL { paths.data }

    private func load() {
        let manager = FileManager.default
        let decoder = JSONDecoder()
        for name in (try? manager.contentsOfDirectory(atPath: data.appendingPathComponent("projects").path)) ?? [] where name.hasSuffix(".json") {
            if let contents = manager.contents(atPath: data.appendingPathComponent("projects/" + name).path),
               let project = try? decoder.decode(Project.self, from: contents), !project.id.isEmpty {
                projectsByID[project.id] = project
            }
        }
        for name in (try? manager.contentsOfDirectory(atPath: data.appendingPathComponent("jobs").path)) ?? [] {
            if let contents = manager.contents(atPath: data.appendingPathComponent("jobs/\(name)/job.json").path),
               let job = try? decoder.decode(Job.self, from: contents), job.id == name {
                jobsByID[job.id] = job
            }
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    // MARK: Reading

    /// Moves whenever a cover or job changes, so the app redraws only then.
    var revision: Int { withLock { counter } }

    var projects: [Project] {
        withLock { projectsByID.values.sorted { $0.updated_at > $1.updated_at } }
    }

    var jobs: [Job] {
        withLock { jobsByID.values.map(withResumable).sorted { $0.created_at > $1.created_at } }
    }

    func state() -> LibraryState { withLock { LibraryState(revision: counter, jobs: jobs, projects: projects) } }

    /// A stopped render can continue from the song tokens it saved.
    private func withResumable(_ job: Job) -> Job {
        var job = job
        job.resumable = ["failed", "cancelled"].contains(job.status) && job.isGeneration
            && FileManager.default.fileExists(atPath: folder(of: job.id).appendingPathComponent("take-1/semantic-prefix.json").path)
        return job
    }

    func folder(of jobID: String) -> URL { data.appendingPathComponent("jobs/" + jobID) }

    func project(_ id: String) throws -> Project {
        try withLock {
            guard UUID(uuidString: id) != nil, let project = projectsByID[id] else { throw ServiceError("Unknown cover") }
            return project
        }
    }

    func job(_ id: String) throws -> Job {
        try withLock {
            guard UUID(uuidString: id) != nil, let job = jobsByID[id] else { throw ServiceError("Unknown job") }
            return withResumable(job)
        }
    }

    /// A file inside the data folder, never outside it.
    func resolve(_ relative: String) throws -> URL {
        let root = data.standardizedFileURL.path + "/"
        let file = data.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard file.path.hasPrefix(root), FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue else {
            throw ServiceError("Audio file not found")
        }
        return file
    }

    func relative(_ file: URL) -> String {
        String(file.standardizedFileURL.path.dropFirst(data.standardizedFileURL.path.count + 1))
    }

    // MARK: Covers

    @discardableResult func save(_ project: Project) throws -> Project {
        var project = project
        if project.id.isEmpty {
            project.id = UUID().uuidString.lowercased()
        } else if UUID(uuidString: project.id) == nil {
            throw ServiceError("Invalid cover identifier")
        }
        try project.validate()
        project.updated_at = timestamp()
        try withLock {
            try write(project, to: data.appendingPathComponent("projects/\(project.id).json"))
            projectsByID[project.id] = project
            counter += 1
        }
        return project
    }

    /// Removes a cover, its takes, and its recording when no other cover uses it. Returns how many jobs went with it.
    @discardableResult func deleteProject(_ id: String) throws -> Int {
        try withLock {
            let project = try self.project(id)
            let owned = jobsByID.values.filter { $0.request.project.id == id }
            if owned.contains(where: \.active) { throw ServiceError("Cancel this cover's job before deleting it.") }
            for job in owned {
                try? FileManager.default.removeItem(at: folder(of: job.id))
                jobsByID[job.id] = nil
            }
            try FileManager.default.removeItem(at: data.appendingPathComponent("projects/\(id).json"))
            projectsByID[id] = nil
            let source = project.cover_source
            if source.hasPrefix("imports/"), !projectsByID.values.contains(where: { $0.cover_source == source }) {
                try? FileManager.default.removeItem(at: data.appendingPathComponent(source))
            }
            counter += 1
            return owned.count
        }
    }

    /// Copies a recording into the library and returns its path there.
    func importAudio(_ file: URL) throws -> String {
        let suffix = file.pathExtension.lowercased()
        guard SongLookup.audioExtensions.contains(suffix) else { throw ServiceError("Import WAV, FLAC, MP3, AIFF or M4A audio") }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 512 * 1024 * 1024 else { throw ServiceError("Choose a recording up to 512 MB.") }
        let relative = "imports/\(UUID().uuidString.lowercased()).\(suffix)"
        try FileManager.default.copyItem(at: file, to: data.appendingPathComponent(relative))
        return relative
    }

    // MARK: Jobs

    /// The forecast for a job queued now: memory held by running jobs is given back before it starts.
    func queuedEstimate(_ project: Project, kind: String = "generate") -> RenderEstimate {
        let now = memory()
        let released = reclaimable()
        var result: RenderEstimate
        if released > 0 {
            var future = now
            future.available_gib = min(future.total_gib, future.available_gib + released)
            result = estimator.estimate(project, kind: kind, memory: future)
            result.memory = now
        } else {
            result = estimator.estimate(project, kind: kind, memory: now)
        }
        result.queued_reclaim_gib = (released * 10).rounded() / 10
        return result
    }

    /// Stores the exact cover snapshot and queues it; edits made while it runs never alter it.
    @discardableResult func createJob(_ request: JobRequest) throws -> Job {
        try request.validate()
        if request.kind == "transcribe" { _ = try resolve(request.source) }
        if request.project.hasSong { _ = try resolve(request.project.cover_source) }
        if !request.resume_from.isEmpty {
            let prior = try job(request.resume_from)
            guard FileManager.default.fileExists(atPath: folder(of: prior.id).appendingPathComponent("take-1/semantic-prefix.json").path) else {
                throw ServiceError("This job has no saved song to resume.")
            }
            let (was, now) = (prior.request.project, request.project)
            let same = was.lyrics == now.lyrics && was.style == now.style && was.abc == now.abc && was.tempo == now.tempo
                && was.cot == now.cot && was.language == now.language && was.vocal_prompt == now.vocal_prompt
                && was.seed == now.seed && was.cfg_scale == now.cfg_scale && was.temperature == now.temperature
            if !same { throw ServiceError("Resume preserves the saved song. Keep lyrics, style, score, voice, seed, and sampling unchanged.") }
        }
        let forecast = queuedEstimate(request.project, kind: request.kind)
        guard forecast.allowed else { throw ServiceError(forecast.reason) }
        var job = Job(id: UUID().uuidString.lowercased(), status: "queued", stage: "Queued", created_at: timestamp(), request: request)
        job.take = 1
        job.estimate = forecast
        try withLock {
            try FileManager.default.createDirectory(at: folder(of: job.id), withIntermediateDirectories: false)
            try write(job, to: folder(of: job.id).appendingPathComponent("job.json"))
            jobsByID[job.id] = job
            counter += 1
        }
        onQueued(job.id)
        return job
    }

    /// Changes a job. Once it is cancelled or failed it stays that way: a worker
    /// finishing at the same moment cannot bring it back.
    func update(_ id: String, status: String? = nil, _ change: (inout Job) -> Void = { _ in }) {
        withLock {
            guard var job = jobsByID[id] else { return }
            if ["cancelled", "failed"].contains(job.status), status != job.status { return }
            change(&job)
            if let status { job.status = status }
            guard job != jobsByID[id] else { return }
            try? write(job, to: folder(of: id).appendingPathComponent("job.json"))
            jobsByID[id] = job
            counter += 1
        }
    }

    @discardableResult func cancelJob(_ id: String) throws -> Job {
        let job = try self.job(id)
        if job.active {
            update(id, status: "cancelled") { $0.stage = "Cancelled"; $0.finished_at = timestamp() }
            onCancelled(id)
        }
        return try self.job(id)
    }

    func deleteJob(_ id: String) throws {
        try withLock {
            if try job(id).active { throw ServiceError("Cancel this job before deleting it.") }
            try FileManager.default.removeItem(at: folder(of: id))
            jobsByID[id] = nil
            counter += 1
        }
    }

    /// Jobs that were running when the app last closed cannot continue.
    func markInterrupted() {
        for job in jobs where job.active {
            update(job.id, status: "failed") {
                $0.stage = "Interrupted"; $0.error = "Moonshift closed during this job. Create it again."; $0.finished_at = timestamp()
            }
        }
    }
}
