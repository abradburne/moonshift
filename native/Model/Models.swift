import Foundation
import SwiftUI

/// A cover: the reference song, its words, and the new sound. Mirrors `studio/models.py`.
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
    /// The same cover ignoring fields the service assigns.
    var content: Project { var copy = self; copy.id = ""; copy.updated_at = ""; return copy }
}

enum Quality: String, CaseIterable, Identifiable {
    case standard = "metal-q4", high = "metal-q8"
    var id: String { rawValue }
    var name: String { self == .standard ? "Standard" : "High precision" }
    var detail: String { self == .standard ? "4-bit · lighter on memory" : "8-bit · keeps more of the model" }
    var bits: String { self == .standard ? "4-bit" : "8-bit" }
    /// Passed to the setup script.
    var setupArgument: String { self == .standard ? "q4" : "q8" }
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
}

struct Job: Decodable, Identifiable, Equatable {
    var id: String
    var status: String
    var stage: String
    var created_at: String
    var started_at: String?
    var finished_at: String?
    var request: JobRequest
    var result: JobResult
    var error: String
    var tokens: Int
    var phase: String?
    var progress: Double?
    var memory_gib: Double?
    var resumable: Bool

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
        phase = try? c.decodeIfPresent(String.self, forKey: .phase)
        progress = try? c.decodeIfPresent(Double.self, forKey: .progress)
        memory_gib = try? c.decodeIfPresent(Double.self, forKey: .memory_gib)
        resumable = (try? c.decodeIfPresent(Bool.self, forKey: .resumable)) ?? false
    }
    enum CodingKeys: String, CodingKey {
        case id, status, stage, created_at, started_at, finished_at, request, result, error, tokens, phase, progress, memory_gib, resumable
    }

    var active: Bool { status == "running" || status == "queued" }
    var isTranscription: Bool { request.kind == "transcribe" }
    var isGeneration: Bool { request.kind == "generate" }
    var tracks: [AudioTrack] { result.tracks ?? [] }
    var created: Date? { serviceDate(created_at) }
    var started: Date? { started_at.flatMap(serviceDate) }
}

/// One undecodable record should not hide every other cover.
struct Lossy<Element: Decodable>: Decodable {
    var elements: [Element]
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) { result.append(value) }
            else { _ = try? container.decode(Skipped.self) }
        }
        elements = result
    }
    private struct Skipped: Decodable {}
}

struct ServiceState: Decodable {
    var jobs: Lossy<Job>
    var projects: Lossy<Project>
}

struct Health: Decodable, Equatable {
    var api: Int?
    var root: String
    var models: [String: Bool]
    var engines: [String: Bool]?
    var memory: MemoryState?

    var transcriptionReady: Bool { models["covers"] == true }
    var lookupReady: Bool { models["lookup"] == true }
    func ready(_ quality: Quality) -> Bool { engines?[quality.rawValue] == true }
    /// Everything a first cover needs, at either quality.
    var canCreate: Bool { transcriptionReady && Quality.allCases.contains(where: ready) }
}

struct MemoryState: Decodable, Equatable {
    var total_gib: Double
    var available_gib: Double
    var limit_gib: Double
}

struct RenderEstimate: Decodable, Equatable {
    var memory: MemoryState
    var peak_low_gib: Double
    var peak_high_gib: Double
    var allowed: Bool
    var reason: String
}

struct SongDetails: Decodable {
    var title: String
    var artist: String
    var duration: Double?
    var method: String?
    var note: String?
}

struct LyricCandidate: Decodable, Identifiable, Equatable {
    var id: Int
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var lyrics: String
    var source: String
}

struct Voice: Identifiable, Equatable {
    let id: String
    let name: String
    let character: String
    let symbol: String
    let color: Color
    let prompt: String

    static let all: [Voice] = [
        .init(id: "ember", name: "Ember", character: "Soulful alto", symbol: "flame.fill", color: .orange,
              prompt: "Warm female alto, intimate breathy verses, powerful clear chorus, soulful phrasing"),
        .init(id: "atlas", name: "Atlas", character: "Deep baritone", symbol: "mountain.2.fill", color: .blue,
              prompt: "Deep male baritone, warm resonant chest voice, textured edge, understated emotional delivery"),
        .init(id: "halo", name: "Halo", character: "Airy soprano", symbol: "sparkles", color: .mint,
              prompt: "Airy female soprano, luminous head voice, delicate breathy phrasing, floating harmonies"),
        .init(id: "riot", name: "Riot", character: "Raspy rock tenor", symbol: "bolt.fill", color: .red,
              prompt: "Male rock tenor, gritty raspy timbre, explosive belted chorus, raw energetic delivery"),
        .init(id: "velvet", name: "Velvet", character: "Jazz contralto", symbol: "moon.fill", color: .purple,
              prompt: "Smooth female jazz contralto, intimate close-mic singing, gentle vibrato, subtle swing phrasing"),
        .init(id: "nova", name: "Nova", character: "Bright pop tenor", symbol: "star.fill", color: .pink,
              prompt: "Bright male pop tenor, clean agile voice, crisp diction, melodic runs and layered chorus harmonies"),
        .init(id: "cipher", name: "Cipher", character: "Rhythmic rap", symbol: "waveform", color: .yellow,
              prompt: "Low male rap voice, articulate rhythmic flow, confident delivery, tightly locked to the beat"),
        .init(id: "duet", name: "Two of Us", character: "Harmonising duet", symbol: "person.2.fill", color: .cyan,
              prompt: "Male and female vocal duet, alternating verses, blended harmonies in the chorus, call and response")
    ]
    static func named(_ id: String) -> Voice? { all.first { $0.id == id } }
}

enum CoverStep: Int, CaseIterable, Identifiable {
    case song, style, create
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .song: "Song"
        case .style: "Style"
        case .create: "Create"
        }
    }
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

/// The service writes Python `isoformat()` timestamps with microseconds.
func serviceDate(_ text: String) -> Date? {
    serviceDateFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}
