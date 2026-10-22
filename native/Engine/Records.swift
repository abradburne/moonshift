import Foundation

/// A message worth showing as-is: the engine writes its errors for people.
struct ServiceError: LocalizedError, Equatable {
    var message: String
    init(message: String) { self.message = message }
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A cover: the reference song, its words, and the new sound, as saved in
/// `data/projects/<id>.json`.
struct Project: Codable, Identifiable, Equatable {
    var id = ""
    var title = Project.untitled
    var style = ""
    var lyrics = ""
    var abc = ""
    /// The score was edited by hand or by an agent, and is used instead of the transcription.
    var score_edited = false
    var voice = "velvet"
    var vocal_prompt = ""
    var language = "English"
    var cot = "melody"
    var seed = 831001
    var cfg_scale = 1.0
    var temperature = 1.0
    var max_tokens = CoverLength.balanced.rawValue
    var ode_steps = 32
    var takes = 1
    /// Speed relative to the reference song: 1 keeps its tempo.
    var tempo = 1.0
    var engine: String? = nil
    var nar_chunk_frames: Int? = 0
    var cover_source = ""
    var cover_name = ""
    var cover_job = ""
    var app_mode = "covers"
    var song_title = ""
    var song_artist = ""
    var lyrics_source = ""
    var cover_preset = ""
    var updated_at = ""

    static let untitled = "Untitled cover"

    init() {}

    // Covers and job snapshots saved by earlier builds may lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        let base = Project()
        id = value(.id, base.id); title = value(.title, base.title); style = value(.style, base.style)
        lyrics = value(.lyrics, base.lyrics); abc = value(.abc, base.abc); score_edited = value(.score_edited, false); voice = value(.voice, base.voice)
        vocal_prompt = value(.vocal_prompt, base.vocal_prompt); language = value(.language, base.language)
        cot = value(.cot, "full"); seed = value(.seed, base.seed); cfg_scale = value(.cfg_scale, base.cfg_scale)
        temperature = value(.temperature, base.temperature); max_tokens = value(.max_tokens, 9000)
        ode_steps = value(.ode_steps, base.ode_steps); takes = value(.takes, base.takes); tempo = value(.tempo, 1.0)
        engine = try? c.decodeIfPresent(String.self, forKey: .engine)
        // Covers saved by the first builds may name the retired PyTorch engine.
        if engine == "torch" { engine = "auto" }
        nar_chunk_frames = try? c.decodeIfPresent(Int.self, forKey: .nar_chunk_frames)
        cover_source = value(.cover_source, ""); cover_name = value(.cover_name, ""); cover_job = value(.cover_job, "")
        app_mode = value(.app_mode, "studio"); song_title = value(.song_title, ""); song_artist = value(.song_artist, "")
        lyrics_source = value(.lyrics_source, ""); cover_preset = value(.cover_preset, ""); updated_at = value(.updated_at, "")
    }

    var hasSong: Bool { !cover_source.isEmpty }
    var hasWords: Bool { !lyrics.trimmed.isEmpty }
    var hasStyle: Bool { !style.trimmed.isEmpty }
    var hasEditedScore: Bool { score_edited && !abc.trimmed.isEmpty }
    /// Worth keeping on disk. An untouched new cover is not.
    var hasContent: Bool { hasSong || hasWords || title != Project.untitled }
    var quality: Quality { Quality(rawValue: engine ?? "") ?? .standard }
    var keepsHarmony: Bool { cot == "full" }
    /// "Original tempo", "15% slower", "10% faster".
    var tempoLabel: String {
        let percent = Int((abs(tempo - 1) * 100).rounded())
        return percent == 0 ? "Original tempo" : "\(percent)% \(tempo < 1 ? "slower" : "faster")"
    }
    /// The song's name where known, otherwise the imported file's.
    var songLabel: String {
        if !song_title.isEmpty { return song_artist.isEmpty ? song_title : "\(song_title) · \(song_artist)" }
        return cover_name
    }
    /// The same cover ignoring fields the library assigns.
    var content: Project { var copy = self; copy.id = ""; copy.updated_at = ""; return copy }

    /// A three-way merge for a cover changed in two places: fields edited `local`ly since
    /// `base` keep those edits, and every other field takes the `stored` version.
    static func merge(local: Project, base: Project, stored: Project) -> Project {
        var result = stored
        func keep<T: Equatable>(_ field: WritableKeyPath<Project, T>) {
            if local[keyPath: field] != base[keyPath: field] { result[keyPath: field] = local[keyPath: field] }
        }
        keep(\.title); keep(\.style); keep(\.lyrics); keep(\.abc); keep(\.score_edited); keep(\.voice); keep(\.vocal_prompt)
        keep(\.language); keep(\.cot); keep(\.seed); keep(\.cfg_scale); keep(\.temperature); keep(\.max_tokens); keep(\.ode_steps)
        keep(\.takes); keep(\.tempo); keep(\.engine); keep(\.nar_chunk_frames); keep(\.cover_source); keep(\.cover_name)
        keep(\.cover_job); keep(\.app_mode); keep(\.song_title); keep(\.song_artist); keep(\.lyrics_source); keep(\.cover_preset)
        return result
    }

    /// The limits every save is held to, so a hand-edited file or an agent cannot ask the engine for nonsense.
    func validate() throws {
        func text(_ name: String, _ value: String, _ maximum: Int) throws {
            if value.unicodeScalars.count > maximum { throw ServiceError("\(name) can be up to \(maximum) characters.") }
        }
        func range<T: Comparable>(_ name: String, _ value: T, _ bounds: ClosedRange<T>) throws {
            if !bounds.contains(value) { throw ServiceError("\(name) must be between \(bounds.lowerBound) and \(bounds.upperBound).") }
        }
        try text("title", title, 160); try text("style", style, 6000); try text("lyrics", lyrics, 18000)
        try text("abc", abc, 30000); try text("vocal_prompt", vocal_prompt, 2000); try text("song_title", song_title, 300)
        try text("song_artist", song_artist, 300); try text("lyrics_source", lyrics_source, 1000); try text("cover_preset", cover_preset, 80)
        guard ["full", "melody", "off"].contains(cot) else { throw ServiceError("cot must be full, melody or off.") }
        try range("seed", seed, 0...(1 << 53) - 1)
        guard cfg_scale.isFinite, temperature.isFinite, tempo.isFinite else { throw ServiceError("Settings must be finite numbers.") }
        try range("cfg_scale", cfg_scale, 0...5); try range("temperature", temperature, 0...2)
        try range("max_tokens", max_tokens, 32...16000); try range("ode_steps", ode_steps, 4...64)
        try range("takes", takes, 1...8); try range("tempo", tempo, 0.5...1.5)
        if let engine, !["auto", "metal-q8", "metal-q4"].contains(engine) { throw ServiceError("engine must be auto, metal-q8 or metal-q4.") }
        if let frames = nar_chunk_frames, ![0, 512, 1024, 2048, 4096].contains(frames) { throw ServiceError("nar_chunk_frames must be 0, 512, 1024, 2048 or 4096.") }
        guard ["studio", "covers"].contains(app_mode) else { throw ServiceError("app_mode must be studio or covers.") }
    }
}

enum Quality: String, CaseIterable, Identifiable {
    case standard = "metal-q4", high = "metal-q8"
    var id: String { rawValue }
    var name: String { self == .standard ? "Standard" : "High precision" }
    var detail: String { self == .standard ? "4-bit · lighter on memory" : "8-bit · keeps more of the model" }
    var bits: String { self == .standard ? "4-bit" : "8-bit" }
    /// Passed to the setup script.
    var setupArgument: String { self == .standard ? "q4" : "q8" }
    /// The music model's weights for this quality.
    var weights: String { self == .standard ? "yue2-3b-q4_0.gguf" : "yue2-3b-q8_0.gguf" }
    static var preferred: Quality {
        get { Quality(rawValue: UserDefaults.standard.string(forKey: "CoverPreferredEngine") ?? "") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "CoverPreferredEngine") }
    }
}

/// A ceiling on the generated song, in song tokens (25 per second).
enum CoverLength: Int, CaseIterable, Identifiable {
    case sketch = 1500, balanced = 4500, full = 9000, extended = 16000
    var id: Int { rawValue }
    var seconds: Double { Double(rawValue) / 25 }
    var name: String {
        switch self {
        case .sketch: "Sketch"
        case .balanced: "Balanced"
        case .full: "Full track"
        case .extended: "Extended"
        }
    }
    var limit: String { "up to " + clockText(seconds) }
    /// The shortest length that leaves room for a song of this duration.
    static func fitting(_ duration: Double) -> CoverLength? {
        duration > 0 ? allCases.first { $0.seconds >= duration } ?? .extended : nil
    }
}

struct AudioTrack: Codable, Identifiable, Equatable {
    var id: String { audio }
    var name: String
    var audio: String
    var flac: String?
    var duration: Double
    var waveform: [Double]
    var seed: Int
    var abc: String
    var truncated: Bool
}

struct JobResult: Codable, Equatable {
    var tracks: [AudioTrack]?
    var abc: String?
    var full_abc: String?
    /// The recording a transcription heard.
    var source: String?
    var duration: Double?
    var warnings: [String]?
}

struct JobRequest: Codable, Equatable {
    var kind: String
    var project: Project
    var source = ""
    var resume_from = ""

    init(kind: String, project: Project, source: String = "", resumeFrom: String = "") {
        self.kind = kind; self.project = project; self.source = source; resume_from = resumeFrom
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        project = try c.decode(Project.self, forKey: .project)
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? ""
        resume_from = (try? c.decodeIfPresent(String.self, forKey: .resume_from)) ?? ""
    }

    /// What a job must ask for before it is queued.
    func validate() throws {
        guard ["generate", "transcribe"].contains(kind) else { throw ServiceError("A job either transcribes a recording or generates a cover.") }
        try project.validate()
        if !resume_from.isEmpty, kind != "generate" || project.takes != 1 {
            throw ServiceError("Resume saved song tokens as a single music take.")
        }
        if kind == "generate" {
            if !project.hasStyle || !project.hasWords { throw ServiceError("Add a musical style and lyrics first.") }
            if !project.abc.trimmed.isEmpty, project.cot == "off" { throw ServiceError("A score needs Melody or Melody and harmony.") }
            if project.hasSong, project.cover_job.isEmpty || project.abc.trimmed.isEmpty || project.cot == "off" {
                throw ServiceError("Listen to the reference song before creating this cover.")
            }
        }
        if kind == "transcribe", source.isEmpty { throw ServiceError("Import a reference recording first.") }
    }
}

/// A transcription or a render, as saved in `data/jobs/<id>/job.json`.
struct Job: Codable, Identifiable, Equatable {
    var id: String
    var status: String
    var stage = ""
    var created_at: String
    var started_at: String?
    var finished_at: String?
    var request: JobRequest
    var result = JobResult()
    var error = ""
    var tokens = 0
    var take: Int?
    var phase: String?
    /// When the current phase began, for the time-remaining estimate.
    var phase_started_at: String?
    var progress: Double?
    var memory_gib: Double?
    var peak_memory_gib: Double?
    var memory_limit_gib: Double?
    var estimate: RenderEstimate?
    /// The engine process running now, so one left behind by a crash can be stopped on the next launch.
    var engine_pid: Int32?
    var engine_started: UInt64?
    /// A stopped render that can continue from its saved song tokens. Worked out on load, never stored.
    var resumable = false

    init(id: String, status: String, stage: String, created_at: String, request: JobRequest) {
        self.id = id; self.status = status; self.stage = stage; self.created_at = created_at; self.request = request
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = try c.decode(String.self, forKey: .status)
        request = try c.decode(JobRequest.self, forKey: .request)
        created_at = try c.decode(String.self, forKey: .created_at)
        stage = (try? c.decodeIfPresent(String.self, forKey: .stage)) ?? ""
        started_at = try? c.decodeIfPresent(String.self, forKey: .started_at)
        finished_at = try? c.decodeIfPresent(String.self, forKey: .finished_at)
        result = (try? c.decodeIfPresent(JobResult.self, forKey: .result)) ?? JobResult()
        error = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? ""
        tokens = (try? c.decodeIfPresent(Int.self, forKey: .tokens)) ?? 0
        take = try? c.decodeIfPresent(Int.self, forKey: .take)
        phase = try? c.decodeIfPresent(String.self, forKey: .phase)
        phase_started_at = try? c.decodeIfPresent(String.self, forKey: .phase_started_at)
        progress = try? c.decodeIfPresent(Double.self, forKey: .progress)
        memory_gib = try? c.decodeIfPresent(Double.self, forKey: .memory_gib)
        peak_memory_gib = try? c.decodeIfPresent(Double.self, forKey: .peak_memory_gib)
        memory_limit_gib = try? c.decodeIfPresent(Double.self, forKey: .memory_limit_gib)
        estimate = try? c.decodeIfPresent(RenderEstimate.self, forKey: .estimate)
        engine_pid = try? c.decodeIfPresent(Int32.self, forKey: .engine_pid)
        engine_started = try? c.decodeIfPresent(UInt64.self, forKey: .engine_started)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(status, forKey: .status); try c.encode(stage, forKey: .stage)
        try c.encode(created_at, forKey: .created_at); try c.encodeIfPresent(started_at, forKey: .started_at)
        try c.encodeIfPresent(finished_at, forKey: .finished_at); try c.encode(request, forKey: .request)
        try c.encode(result, forKey: .result); try c.encode(error, forKey: .error); try c.encode(tokens, forKey: .tokens)
        try c.encodeIfPresent(take, forKey: .take); try c.encodeIfPresent(phase, forKey: .phase)
        try c.encodeIfPresent(phase_started_at, forKey: .phase_started_at)
        // Unknown progress is stored as null, so the app shows an indeterminate bar.
        try c.encode(progress, forKey: .progress)
        try c.encodeIfPresent(memory_gib, forKey: .memory_gib); try c.encodeIfPresent(peak_memory_gib, forKey: .peak_memory_gib)
        try c.encodeIfPresent(memory_limit_gib, forKey: .memory_limit_gib); try c.encodeIfPresent(estimate, forKey: .estimate)
        try c.encodeIfPresent(engine_pid, forKey: .engine_pid); try c.encodeIfPresent(engine_started, forKey: .engine_started)
    }

    enum CodingKeys: String, CodingKey {
        case id, status, stage, created_at, started_at, finished_at, request, result, error, tokens, take, phase, phase_started_at, progress
        case memory_gib, peak_memory_gib, memory_limit_gib, estimate, engine_pid, engine_started
    }

    static let activeStatuses: Set<String> = ["queued", "running"]
    var active: Bool { Job.activeStatuses.contains(status) }
    var isTranscription: Bool { request.kind == "transcribe" }
    var isGeneration: Bool { request.kind == "generate" }
    var tracks: [AudioTrack] { result.tracks ?? [] }
    var created: Date? { serviceDate(created_at) }
    var started: Date? { started_at.flatMap(serviceDate) }
    var finished: Date? { finished_at.flatMap(serviceDate) }
    var phaseStarted: Date? { phase_started_at.flatMap(serviceDate) }
}

/// Everything the app lists, and a counter that moves whenever any of it changes.
struct LibraryState {
    var revision: Int
    var jobs: [Job]
    var projects: [Project]
}

struct Health: Equatable {
    var root: String
    var models: [String: Bool]
    var engines: [String: Bool]
    var memory: MemoryState
    /// Cover and job files in the library that could not be read.
    var unreadable = 0

    var transcriptionReady: Bool { models["covers"] == true }
    var lookupReady: Bool { models["lookup"] == true }
    func ready(_ quality: Quality) -> Bool { engines[quality.rawValue] == true }
    /// Everything a first cover needs, at either quality.
    var canCreate: Bool { transcriptionReady && Quality.allCases.contains(where: ready) }
}

struct MemoryState: Codable, Equatable {
    var total_gib: Double
    var available_gib: Double
    var free_gib: Double
    var limit_gib: Double
    var reserve_gib: Double
    /// The kernel's pressure level when it was read: 1 normal, 2 warning, 4 critical.
    var pressure: Int? = nil
}

struct RenderEstimate: Codable, Equatable {
    var engine: String
    var engine_label: String
    var memory: MemoryState
    var peak_low_gib: Double
    var peak_high_gib: Double
    var cache_gib: Double
    var prompt_tokens_estimate: Int
    var audio_tokens: Int
    var duration_ceiling_seconds: Double
    var suggested_tokens: Int
    var allowed: Bool
    var reason: String
    var selection_note: String?
    var queued_reclaim_gib: Double?
}

struct SongDetails: Codable, Equatable {
    var title: String
    var artist: String
    var duration: Double?
    var method: String?
    var note: String?
}

struct LyricCandidate: Codable, Identifiable, Equatable {
    var id: Int
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var lyrics: String
    var source: String
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

func clockText(_ value: Double) -> String {
    guard value.isFinite else { return "0:00" }
    let seconds = max(0, Int(value.rounded()))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

private let serviceDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

/// Timestamps keep the shape earlier builds wrote, microseconds and all, so they still sort as text.
func serviceDate(_ text: String) -> Date? {
    serviceDateFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}

func timestamp(_ date: Date = Date()) -> String {
    var seconds = date.timeIntervalSince1970
    let whole = floor(seconds)
    seconds -= whole
    let micros = min(999_999, Int((seconds * 1_000_000).rounded()))
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate, .withFullTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
    formatter.timeZone = TimeZone(identifier: "UTC")
    // "2026-10-15T01:02:03Z" → "2026-10-15T01:02:03.123456+00:00"
    let base = formatter.string(from: Date(timeIntervalSince1970: whole)).replacingOccurrences(of: "Z", with: "")
    return base + String(format: ".%06d+00:00", micros)
}
