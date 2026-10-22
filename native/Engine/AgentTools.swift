import Foundation

/// Model Context Protocol endpoint: lets an agent read, edit and render covers.
///
/// Served at `/mcp` on the loopback address, as plain JSON over HTTP. An agent
/// can read a cover's lyrics, style and ABC score, change any of them
/// (reharmonize, write a solo, adapt the words), and render each revision.
struct AgentTools {
    let library: Library
    /// Reads a new recording's title, artist and length.
    var details: (URL, String) async throws -> SongDetails = { try await SongLookup.details(of: $0, name: $1) }

    static let protocolVersion = "2025-06-18"

    static let instructions = """
    Moonshift turns a song into a cover in a new style, on this Mac.

    A cover has a reference recording, lyrics, a style, a singer, and a score. The
    score is ABC notation transcribed from the recording: a melody, and optionally
    chords. Rendering a take follows the score, so editing it changes the music.

    Typical work: get_cover to read the lyrics, style and score; update_cover with
    your changes (a reharmonized or extended score, adapted lyrics, a new style);
    create_take to render; get_job until it completes; then tell the user where
    the audio is. A cover needs a transcription before its first take: call
    transcribe and wait for that job. Rendering takes minutes and uses most of the
    machine's memory, so render one take at a time and only when asked.

    Keep the score valid ABC: keep the header fields (X, M, L, Q, K) and voice
    lines, and change notes, chords in quotes, or the Q tempo. Section labels in
    lyrics look like [Verse] and [Chorus].
    """

    // MARK: Tools

    private static func schema(_ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private static let coverID: [String: Any] = ["type": "string", "description": "The cover's id, from list_covers."]
    private static let editable: [String: [String: Any]] = [
        "title": ["type": "string", "description": "Name of the cover."],
        "lyrics": ["type": "string", "description": "The words, with section labels such as [Verse] and [Chorus]."],
        "style": ["type": "string", "description": "Genre, instruments, mood and production, as a short description."],
        "vocal_prompt": ["type": "string", "description": "Who sings and how, for example 'Smooth female jazz contralto, gentle vibrato'."],
        "language": ["type": "string", "description": "Language of the lyrics."],
        "keep": ["type": "string", "enum": ["melody", "melody_and_harmony"], "description": "What to follow from the reference: the melody alone, or its chords too."],
        "tempo": ["type": "number", "minimum": 0.5, "maximum": 1.5, "description": "Speed relative to the reference. 1 keeps its tempo; 0.8 is 20% slower."],
        "length_seconds": ["type": "number", "minimum": 20, "maximum": 640, "description": "Upper limit on the rendered length. A shorter song ends sooner."],
        "quality": ["type": "string", "enum": ["standard", "high"], "description": "standard is the 4-bit music model; high is 8-bit and needs more memory."],
        "score": ["type": "string", "description": "The full ABC score to render from, replacing the transcription. Pass an empty string to go back to the transcribed score."],
    ]

    static let tools: [[String: Any]] = {
        let started = ["title", "lyrics", "style", "vocal_prompt", "language"].reduce(into: [String: Any]()) { $0[$1] = editable[$1] }
        let jobID: [String: Any] = ["type": "string"]
        return [
            ["name": "status", "description": "Whether the models are installed, how much memory is free, and what is rendering now.",
             "inputSchema": schema([:])],
            ["name": "list_covers", "description": "Every cover, most recently edited first, with its song, style and number of takes.",
             "inputSchema": schema([:])],
            ["name": "get_cover", "description": "One cover in full: lyrics, style, singer, settings, the ABC score it will render from, and its takes with the paths of their audio files.",
             "inputSchema": schema(["cover_id": coverID], ["cover_id"])],
            ["name": "create_cover", "description": "Start a new cover from a recording on this Mac. Give lyrics and style now or with update_cover later.",
             "inputSchema": schema(started.merging(["audio_path": ["type": "string", "description": "Absolute path of a WAV, FLAC, MP3, AIFF or M4A file, up to 15 minutes."]]) { $1 }, ["audio_path"])],
            ["name": "update_cover", "description": "Change any part of a cover: lyrics, style, singer, tempo, length, or the score itself. Only the fields you pass change. Nothing is rendered until create_take.",
             "inputSchema": schema(editable.merging(["cover_id": coverID]) { $1 }, ["cover_id"])],
            ["name": "transcribe", "description": "Listen to a cover's recording and write its score. Needed once per recording, before the first take. Returns a job to follow with get_job.",
             "inputSchema": schema(["cover_id": coverID], ["cover_id"])],
            ["name": "create_take", "description": "Render the cover as it stands now. Takes several minutes; follow the returned job with get_job. Each take is a new performance.",
             "inputSchema": schema(["cover_id": coverID], ["cover_id"])],
            ["name": "get_job", "description": "Progress of a transcription or render, and its result when complete.",
             "inputSchema": schema(["job_id": jobID], ["job_id"])],
            ["name": "cancel_job", "description": "Stop a transcription or render that is queued or running.",
             "inputSchema": schema(["job_id": jobID], ["job_id"])],
            ["name": "delete_take", "description": "Delete a finished take and its audio. This cannot be undone.",
             "inputSchema": schema(["job_id": ["type": "string", "description": "The take's job id, from get_cover."]], ["job_id"])],
        ]
    }()

    // MARK: Requests

    /// Answers one JSON-RPC message. Returns nil for a notification, which gets no reply.
    func respond(to body: Data) async -> (status: Int, body: Data?) {
        func reply(_ object: [String: Any], status: Int = 200) -> (Int, Data?) {
            (status, try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: body) else {
            return reply(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]], status: 400)
        }
        guard let message = parsed as? [String: Any] else {
            return reply(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Send one request at a time."]], status: 400)
        }
        // A notification: acknowledged, never answered.
        guard let identifier = message["id"], !(identifier is NSNull) else { return (202, nil) }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: Any) -> (Int, Data?) { reply(["jsonrpc": "2.0", "id": identifier, "result": value]) }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return result(["protocolVersion": ["2024-11-05", "2025-03-26", Self.protocolVersion].contains(asked) ? asked : Self.protocolVersion,
                           "capabilities": ["tools": [String: Any]()],
                           "serverInfo": ["name": "moonshift", "title": "Moonshift", "version": "1.1.0"],
                           "instructions": Self.instructions])
        case "ping":
            return result([String: Any]())
        case "tools/list":
            return result(["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return result(Self.text(try await call(name, arguments)))
            } catch {
                // Tool failures go back as results, so the agent can read them and adjust.
                var failure = Self.text(error.localizedDescription)
                failure["isError"] = true
                return result(failure)
            }
        default:
            return reply(["jsonrpc": "2.0", "id": identifier, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    static func text(_ value: Any) -> [String: Any] {
        let body: String
        if let string = value as? String {
            body = string
        } else {
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            body = String(decoding: data, as: UTF8.self)
        }
        return ["content": [["type": "text", "text": body]]]
    }

    // MARK: Covers

    private func argument<T>(_ arguments: [String: Any], _ key: String, as type: T.Type = String.self) throws -> T {
        guard let value = arguments[key] else { throw ServiceError("Missing argument: \(key)") }
        if T.self == Double.self, let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue as! T }
        guard let typed = value as? T else { throw ServiceError("\(key) must be a \(T.self == String.self ? "string" : "number").") }
        return typed
    }

    private func cover(_ id: String) throws -> Project {
        do { return try library.project(id) } catch { throw ServiceError("Unknown cover. Use list_covers to see the ids.") }
    }

    private func jobs(of coverID: String) -> [Job] { library.jobs.filter { $0.request.project.id == coverID } }

    private func transcription(of source: String) -> Job? {
        source.isEmpty ? nil : library.jobs.first { $0.isTranscription && $0.status == "complete" && $0.request.source == source }
    }

    /// The score a take would render from, where it came from, and the job that made it.
    func score(for cover: Project) -> (score: String, origin: String, job: String) {
        if cover.hasEditedScore { return (cover.abc, "edited", cover.cover_job.isEmpty ? "edited" : cover.cover_job) }
        if let heard = transcription(of: cover.cover_source) {
            return ((cover.keepsHarmony ? heard.result.full_abc : heard.result.abc) ?? "", "transcription", heard.id)
        }
        return cover.abc.trimmed.isEmpty ? ("", "none", "") : (cover.abc, "saved", cover.cover_job)
    }

    private func describe(_ job: Job) -> [String: Any] {
        var summary: [String: Any] = ["job_id": job.id, "kind": job.isTranscription ? "transcription" : "take",
                                      "status": job.status, "stage": job.stage, "created_at": job.created_at]
        if job.active, let progress = job.progress { summary["progress"] = (progress * 100).rounded() / 100 }
        if !job.error.isEmpty { summary["error"] = job.error }
        if job.isGeneration {
            let made = job.request.project
            summary["settings"] = ["style": made.style, "vocal_prompt": made.vocal_prompt,
                                   "keep": made.keepsHarmony ? "melody_and_harmony" : "melody", "tempo": made.tempo]
            summary["audio"] = job.tracks.map { track -> [String: Any] in
                ["wav": library.data.appendingPathComponent(track.audio).path,
                 "flac": track.flac.map { library.data.appendingPathComponent($0).path } ?? NSNull(),
                 "seconds": (track.duration * 10).rounded() / 10, "reached_length_limit": track.truncated]
            }
        }
        return summary
    }

    private func describe(_ cover: Project, full: Bool = false) -> [String: Any] {
        let owned = jobs(of: cover.id)
        let takes = owned.filter { $0.isGeneration && !$0.tracks.isEmpty }
        let song = [cover.song_title, cover.song_artist].filter { !$0.isEmpty }.joined(separator: " · ")
        var summary: [String: Any] = ["cover_id": cover.id, "title": cover.title, "song": song.isEmpty ? cover.cover_name : song,
                                      "style": cover.style, "takes": takes.count, "busy": owned.contains(where: \.active),
                                      "updated_at": cover.updated_at]
        guard full else { return summary }
        let (score, origin, _) = score(for: cover)
        summary.merge([
            "lyrics": cover.lyrics, "vocal_prompt": cover.vocal_prompt, "language": cover.language,
            "keep": cover.keepsHarmony ? "melody_and_harmony" : "melody", "tempo": cover.tempo,
            "length_seconds": Double(cover.max_tokens) / 25, "quality": cover.engine == "metal-q8" ? "high" : "standard",
            "recording": cover.hasSong ? library.data.appendingPathComponent(cover.cover_source).path : NSNull(),
            "score": score, "score_source": origin, "jobs": owned.map(describe),
        ]) { $1 }
        if origin == "none" { summary["note"] = "This cover has no score yet. Call transcribe, wait for it to complete, then create_take." }
        return summary
    }

    private func apply(_ changes: [String: Any], to cover: Project) throws -> Project {
        var cover = cover
        for key in ["title", "lyrics", "style", "vocal_prompt", "language"] where changes[key] != nil {
            let value: String = try argument(changes, key)
            switch key {
            case "title": cover.title = value
            case "lyrics": cover.lyrics = value
            case "style": cover.style = value
            case "vocal_prompt": cover.vocal_prompt = value
            default: cover.language = value
            }
        }
        if changes["tempo"] != nil { cover.tempo = try argument(changes, "tempo", as: Double.self) }
        if changes["keep"] != nil { cover.cot = try argument(changes, "keep") == "melody_and_harmony" ? "full" : "melody" }
        if changes["length_seconds"] != nil {
            cover.max_tokens = max(500, min(16000, Int((try argument(changes, "length_seconds", as: Double.self) * 25).rounded())))
        }
        if changes["quality"] != nil { cover.engine = try argument(changes, "quality") == "high" ? "metal-q8" : "metal-q4" }
        if changes["score"] != nil {
            let score: String = try argument(changes, "score")
            cover.score_edited = !score.trimmed.isEmpty
            cover.abc = cover.score_edited ? score : ""
        }
        // Validated exactly as the app's own saves are.
        return try library.save(cover)
    }

    func call(_ name: String, _ arguments: [String: Any]) async throws -> Any {
        switch name {
        case "status":
            let paths = library.paths
            return ["transcription_installed": paths.coversInstalled, "standard_quality_installed": paths.installed("metal-q4"),
                    "high_quality_installed": paths.installed("metal-q8"), "memory_available_gb": library.memory().available_gib,
                    "library": paths.root.path, "working_on": library.jobs.filter(\.active).map(describe)]
        case "list_covers":
            return library.projects.filter { $0.app_mode == "covers" }.map { describe($0) }
        case "get_cover":
            return describe(try cover(try argument(arguments, "cover_id")), full: true)
        case "create_cover":
            let given = URL(fileURLWithPath: (try argument(arguments, "audio_path") as String as NSString).expandingTildeInPath)
            let source = given.resolvingSymlinksInPath()
            var directory: ObjCBool = false
            guard SongLookup.audioExtensions.contains(given.pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: source.path, isDirectory: &directory), !directory.boolValue else {
                throw ServiceError("Give the path of an existing WAV, FLAC, MP3, AIFF or M4A file.")
            }
            // Read before copying, so a recording that is refused is never copied.
            let found: SongDetails
            do {
                found = try await details(source, given.lastPathComponent)
            } catch {
                throw ServiceError("That recording could not be read, or is longer than 15 minutes.")
            }
            let relative = try library.importAudio(source)
            var cover = Project()
            cover.app_mode = "covers"; cover.cover_source = relative; cover.cover_name = given.deletingPathExtension().lastPathComponent
            cover.song_title = found.title; cover.song_artist = found.artist
            let title = arguments["title"] as? String ?? ""
            cover.title = !title.isEmpty ? title : !found.title.isEmpty ? found.title : cover.cover_name
            cover.cot = "melody"; cover.max_tokens = 4500; cover.nar_chunk_frames = 0; cover.engine = "metal-q4"
            let initial = arguments.filter { ["lyrics", "style", "vocal_prompt", "language"].contains($0.key) }
            return describe(try apply(initial, to: cover), full: true)
        case "update_cover":
            let cover = try cover(try argument(arguments, "cover_id"))
            if jobs(of: cover.id).contains(where: \.active) {
                throw ServiceError("This cover is being rendered. Wait for it, or cancel the job, before changing it.")
            }
            return describe(try apply(arguments.filter { $0.key != "cover_id" }, to: cover), full: true)
        case "transcribe":
            let cover = try cover(try argument(arguments, "cover_id"))
            guard cover.hasSong else { throw ServiceError("This cover has no recording to listen to.") }
            if let heard = transcription(of: cover.cover_source) {
                return describe(heard).merging(["note": "This recording is already transcribed."]) { $1 }
            }
            if let listening = library.jobs.first(where: { $0.isTranscription && $0.active && $0.request.source == cover.cover_source }) {
                return describe(listening).merging(["note": "This recording is already being transcribed. Follow this job."]) { $1 }
            }
            return describe(try library.createJob(JobRequest(kind: "transcribe", project: cover, source: cover.cover_source)))
        case "create_take":
            var cover = try cover(try argument(arguments, "cover_id"))
            if jobs(of: cover.id).contains(where: \.active) {
                throw ServiceError("This cover is already being worked on. Follow its job with get_job.")
            }
            let (score, _, job) = score(for: cover)
            if cover.hasSong, score.trimmed.isEmpty {
                throw ServiceError("This cover has no score yet. Call transcribe, wait for it to complete, then try again.")
            }
            cover.abc = score
            cover.cover_job = job
            // A new seed, so the same settings give a new performance.
            cover.seed = Int.random(in: 1..<2_000_000_000)
            let saved = try library.save(cover)
            return describe(try library.createJob(JobRequest(kind: "generate", project: saved)))
        case "get_job":
            return describe(try library.job(try argument(arguments, "job_id")))
        case "cancel_job":
            return describe(try library.cancelJob(try argument(arguments, "job_id")))
        case "delete_take":
            let id: String = try argument(arguments, "job_id")
            try library.deleteJob(id)
            return ["deleted": id]
        default:
            throw ServiceError("Unknown tool: \(name)")
        }
    }
}
