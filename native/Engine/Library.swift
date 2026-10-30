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
    /// Called, outside the lock, whenever a cover or job changes.
    var onChanged: () -> Void = {}
    /// Cover and job files that could not be read when the library opened.
    private(set) var unreadable: [String] = []

    private let lock = NSRecursiveLock()
    private var projectsByID: [String: Project] = [:]
    private var jobsByID: [String: Job] = [:]
    private var counter = 0
    /// When each job's file was last written, so live progress is saved at most every few seconds.
    private var writtenAt: [String: Date] = [:]

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
            } else {
                unreadable.append("projects/" + name)
            }
        }
        for name in (try? manager.contentsOfDirectory(atPath: data.appendingPathComponent("jobs").path)) ?? [] where !name.hasPrefix(".") {
            if let contents = manager.contents(atPath: data.appendingPathComponent("jobs/\(name)/job.json").path),
               let job = try? decoder.decode(Job.self, from: contents), job.id == name {
                jobsByID[job.id] = withResumable(job)
            } else {
                unreadable.append("jobs/\(name)/job.json")
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
        withLock { jobsByID.values.sorted { $0.created_at > $1.created_at } }
    }

    func state() -> LibraryState { withLock { LibraryState(revision: counter, jobs: jobs, projects: projects) } }

    /// A stopped render can continue from the song tokens it saved. Worked out when a job stops, not on every read.
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
            return job
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
        onChanged()
        return project
    }

    /// Removes a cover, its takes, and its recording when no other cover uses it. Returns how many jobs went with it.
    @discardableResult func deleteProject(_ id: String) throws -> Int {
        defer { onChanged() }
        return try withLock {
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
        // The recording itself, not a link to it that would point outside the library.
        let file = file.resolvingSymlinksInPath()
        let suffix = file.pathExtension.lowercased()
        guard SongLookup.audioExtensions.contains(suffix) else { throw ServiceError("Import WAV, FLAC, MP3, AIFF or M4A audio") }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 512 * 1024 * 1024 else { throw ServiceError("Choose a recording up to 512 MB.") }
        let relative = "imports/\(UUID().uuidString.lowercased()).\(suffix)"
        try FileManager.default.copyItem(at: file, to: data.appendingPathComponent(relative))
        return relative
    }

    /// Removes an imported recording once no cover or job refers to it, as after replacing a cover's song.
    func releaseImport(_ source: String) {
        guard source.hasPrefix("imports/") else { return }
        withLock {
            let used = projectsByID.values.contains { $0.cover_source == source }
                || jobsByID.values.contains { $0.request.project.cover_source == source || $0.request.source == source }
            if !used { try? FileManager.default.removeItem(at: data.appendingPathComponent(source)) }
        }
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
        // A recording already being listened to is not listened to twice.
        if request.kind == "transcribe", let listening = withLock({
            jobsByID.values.first { $0.isTranscription && $0.active && $0.request.source == request.source }
        }) {
            return listening
        }
        if request.kind == "transcribe" { _ = try resolve(request.source) }
        if request.project.hasSong { _ = try resolve(request.project.cover_source) }
        if !request.resume_from.isEmpty {
            let prior = try job(request.resume_from)
            let saved = folder(of: prior.id).appendingPathComponent("take-\(request.resume_take)/semantic-prefix.json")
            guard FileManager.default.fileExists(atPath: saved.path) else {
                throw ServiceError("This job has no saved song to resume.")
            }
            let (was, now) = (prior.request.project, request.project)
            // The words and music the saved song was written to, which writing on from it must keep.
            let music = was.lyrics == now.lyrics && was.style == now.style && was.abc == now.abc && was.tempo == now.tempo
                && was.cot == now.cot && was.language == now.language && was.vocal_prompt == now.vocal_prompt
            if request.continuing {
                if !music { throw ServiceError("Extending keeps the take's song. Keep lyrics, style, score, voice and tempo unchanged.") }
                let written = (try? MusicRender.semanticArtifact(saved).0.count) ?? 0
                if written >= now.max_tokens { throw ServiceError("Choose a length longer than the take.") }
            } else {
                // Rendering again draws the same audio noise from the take's own seed.
                let same = music && was.seed + request.resume_take - 1 == now.seed && was.cfg_scale == now.cfg_scale
                    && was.temperature == now.temperature
                if !same { throw ServiceError("Resume preserves the saved song. Keep lyrics, style, score, voice, seed, and sampling unchanged.") }
            }
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
        onChanged()
        onQueued(job.id)
        return job
    }

    /// Changes a job. Once it is cancelled or failed it stays that way: a worker
    /// finishing at the same moment cannot bring it back. A `live` change, such as
    /// progress or memory, is shown at once but written to disk at most every two seconds.
    func update(_ id: String, status: String? = nil, live: Bool = false, _ change: (inout Job) -> Void = { _ in }) {
        let changed: Bool = withLock {
            guard var job = jobsByID[id], let before = jobsByID[id] else { return false }
            if ["cancelled", "failed"].contains(job.status), status != job.status { return false }
            change(&job)
            if let status { job.status = status }
            if job.phase != before.phase { job.phase_started_at = job.phase == nil ? nil : timestamp() }
            if job.status != before.status { job = withResumable(job) }
            guard job != before else { return false }
            if !live || Date().timeIntervalSince(writtenAt[id] ?? .distantPast) >= 2 {
                try? write(job, to: folder(of: id).appendingPathComponent("job.json"))
                writtenAt[id] = Date()
            }
            jobsByID[id] = job
            counter += 1
            return true
        }
        if changed { onChanged() }
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
            writtenAt[id] = nil
            counter += 1
        }
        onChanged()
    }

    /// Jobs that were running when the app last closed cannot continue. Returns the
    /// engines they had started, which may have outlived a crash and must be stopped.
    @discardableResult func markInterrupted() -> [(pid: pid_t, started: UInt64)] {
        var engines: [(pid: pid_t, started: UInt64)] = []
        for job in jobs where job.active {
            if let pid = job.engine_pid, let started = job.engine_started { engines.append((pid, started)) }
            update(job.id, status: "failed") {
                $0.stage = "Interrupted"; $0.error = "Moonshift closed while this was being made."; $0.finished_at = timestamp()
                $0.engine_pid = nil; $0.engine_started = nil
            }
        }
        return engines
    }
}
