import AVFoundation
import Foundation

/// One render: for each take, the music engine first writes the song as tokens,
/// which are saved, then a second process renders those tokens to audio. The
/// planning model and its cache are gone before rendering starts.
struct MusicRender {
    let runner: JobRunner
    let id: String
    let request: JobRequest
    let limit: Double
    let log: FileHandle?

    private var library: Library { runner.library }
    private var paths: Paths { library.paths }
    private var project: Project { request.project }

    static let attribution: [String: String] = [
        "model_card": "https://huggingface.co/m-a-p/YuE2-3B",
        "license": "CC BY-NC 4.0; see upstream additional creator permission",
        "license_url": "https://github.com/multimodal-art-projection/YuE/blob/main/MODEL_LICENSE",
        "decoder_card": "https://huggingface.co/m-a-p/YuE2-Vae",
        "conversion_card": "https://huggingface.co/audio-cpp/Yue2-3B-GGUF",
        "runtime": "https://github.com/0xShug0/audio.cpp",
        "runtime_license": "https://github.com/0xShug0/audio.cpp/blob/main/LICENSE",
    ]

    func run() throws -> JobResult {
        let folder = library.folder(of: id)
        try write(Self.attribution, to: folder.appendingPathComponent("model-attribution.json"))
        let engine = library.estimator.engine(for: project)
        let weights = (Quality(rawValue: engine) ?? .high).weights
        let style = [project.language, project.style, project.vocal_prompt].filter { !$0.isEmpty }.joined(separator: ", ")
        var tracks: [AudioTrack] = []
        for take in 1...project.takes {
            let out = folder.appendingPathComponent("take-\(take)")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let seed = project.seed + take - 1
            let started = Date()
            let base = ["--task", "gen", "--family", "yue2", "--model", paths.gguf.path, "--backend", "metal",
                        "--threads", String(Machine.performanceCores),
                        "--session-option", "yue2.model_gguf=\(weights)", "--session-option", "yue2.vae_gguf=yue2-vae-f16.gguf",
                        "--lyrics", project.lyrics, "--seed", String(seed), "--out-dir", out.path, "--log"]
            var options: [(String, String)] = [
                ("style", style), ("cot", project.cot), ("guidance_scale", "\(project.cfg_scale)"),
                ("semantic_temperature", "\(project.temperature)"), ("semantic_max_tokens", "\(project.max_tokens)"),
                ("semantic_min_tokens", "\(min(200, project.max_tokens))"), ("num_inference_steps", "\(project.ode_steps)"),
                ("export_semantic", "true"),
            ]
            let frames = project.nar_chunk_frames ?? 1024
            if frames > 0 { options.append(("nar_chunk_frames", "\(frames)")) }
            let score = out.appendingPathComponent("score.abc")
            if !project.abc.trimmed.isEmpty {
                try Self.retime(project.abc, project.tempo).write(to: score, atomically: true, encoding: .utf8)
                options.append(("abc_file", score.path))
            }

            let codes: [Int], meta: [String: Any]
            if !request.resume_from.isEmpty {
                let source = library.folder(of: request.resume_from).appendingPathComponent("take-1")
                (codes, meta) = try Self.semanticArtifact(source.appendingPathComponent("semantic-prefix.json"))
                if let saved = try? String(contentsOf: source.appendingPathComponent("score.abc"), encoding: .utf8) {
                    try saved.write(to: score, atomically: true, encoding: .utf8)
                }
                try write(codes, to: out.appendingPathComponent("semantic.json"))
            } else {
                try engineRun(base, options + [("stop_after", "semantic")], take: take, stage: "Loading the music model", out: out)
                (codes, meta) = try Self.semanticArtifact(out.appendingPathComponent("semantic.json"))
            }
            guard !codes.isEmpty, codes.allSatisfy({ (0..<32768).contains($0) }) else { throw ServiceError("The music engine returned invalid song tokens.") }
            guard codes.count <= project.max_tokens else { throw ServiceError("Choose a length large enough for the saved song.") }
            let checkpoint = out.appendingPathComponent("semantic-prefix.json")
            try write(codes, to: checkpoint)

            // The first process has exited: no planning model or cache survives.
            var render = options.filter { !["semantic_min_tokens", "semantic_max_tokens", "abc_file"].contains($0.0) }
            render += [("stop_after", "audio"), ("semantic_prefix_file", checkpoint.path),
                       ("semantic_min_tokens", "\(codes.count)"), ("semantic_max_tokens", "\(codes.count)")]
            if FileManager.default.fileExists(atPath: score.path) { render.append(("abc_file", score.path)) }
            try engineRun(base + ["--out", out.appendingPathComponent("audio.wav").path], render, take: take,
                          stage: "Loading the acoustic renderer", out: out)

            library.update(id) { $0.stage = "Saving your cover"; $0.phase = "finish"; $0.progress = nil }
            let audio = try Self.finish(out.appendingPathComponent("audio.wav"), lossless: out.appendingPathComponent("audio.flac"))
            let truncated = codes.count >= project.max_tokens || ["true", "1"].contains("\(meta["truncated"] ?? "false")".lowercased())
            let abc = (try? String(contentsOf: score, encoding: .utf8)) ?? ""
            tracks.append(AudioTrack(name: "Take \(take)", audio: library.relative(out.appendingPathComponent("audio.wav")),
                                     flac: library.relative(out.appendingPathComponent("audio.flac")), duration: audio.duration,
                                     waveform: audio.waveform, seed: seed, abc: abc, truncated: truncated))
            let metadata = TakeMetadata(engine: engine, weights: weights, project: project, semantic_frames: codes.count, truncated: truncated,
                                        e2e_seconds: Date().timeIntervalSince(started))
            try write(metadata, to: out.appendingPathComponent("metadata.json"))
            // Completed takes are kept if a later take fails or is cancelled.
            let finished = tracks
            library.update(id) { $0.result = JobResult(tracks: finished) }
        }
        return JobResult(tracks: tracks)
    }

    struct TakeMetadata: Encodable {
        var engine: String
        var weights: String
        var project: Project
        var semantic_frames: Int
        var truncated: Bool
        var e2e_seconds: Double
        var model_card = "https://huggingface.co/m-a-p/YuE2-3B"
        var license = "CC-BY-NC-4.0"
        var license_url = "https://huggingface.co/m-a-p/YuE2-3B/blob/main/LICENSE"
        var conversion_card = "https://huggingface.co/audio-cpp/Yue2-3B-GGUF"
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    // MARK: The engine

    private func engineRun(_ base: [String], _ options: [(String, String)], take: Int, stage: String, out: URL) throws {
        let rendering = options.contains { $0 == ("stop_after", "audio") }
        let budget = Int(options.last { $0.0 == "semantic_max_tokens" }?.1 ?? "") ?? 0
        library.update(id) {
            $0.stage = stage; $0.take = take; $0.phase = rendering ? "render" : "compose"; $0.progress = nil; $0.tokens = rendering ? budget : 0
        }
        let arguments = base + options.flatMap { ["--request-option", "\($0.0)=\($0.1)"] }
        var tail: [String] = []
        let code = try runner.launch(id, paths.engine, arguments, limit: limit, watchProgress: true, log: log) { line, beat in
            tail = Array((tail + [line.trimmed]).suffix(12))
            if let change = Self.progress(in: line, project: project) {
                beat()
                library.update(id, live: true, change)
            }
        }
        guard (try? library.job(id))?.active == true else { throw CancellationError() }
        if code != 0 { throw ServiceError("The music engine failed: " + String(tail.joined(separator: " ").suffix(1500))) }
    }

    /// What a line of the engine's log says about its progress, as a change to the job.
    static func progress(in line: String, project: Project) -> ((inout Job) -> Void)? {
        if let tokens = line.firstCapture(#"yue2\.ar\.(?:generate|cfg)\.emitted_tokens(?:\s*[=:]\s*|\s+)(\d+)"#).flatMap({ Int($0) }) {
            return { $0.tokens = tokens }
        }
        if let groups = line.captures(#"moonwire\.progress\.(semantic|abc)\s+(\d+)"#), let count = Int(groups[1]) {
            if groups[0] == "semantic" {
                // The budget is a ceiling: the song may end well before it.
                let share = min(1, Double(count) / Double(project.max_tokens))
                return { $0.stage = "Writing the new arrangement"; $0.phase = "compose"; $0.tokens = count; $0.progress = share }
            }
            return { $0.stage = "Planning the score"; $0.phase = "compose"; $0.progress = nil }
        }
        if line.contains("yue2.nar.synthesize.codec_tokens") { return { $0.stage = "Rendering acoustic detail"; $0.phase = "render" } }
        if line.contains("yue2.nar_ms") { return { $0.stage = "Decoding stereo audio"; $0.phase = "finish"; $0.progress = nil } }
        if let step = line.firstCapture(#"moonwire\.progress\.flow\s+(\d+)"#).flatMap({ Int($0) }) {
            let share = min(1, Double(step) / Double(project.ode_steps))
            return { $0.stage = "Rendering acoustic detail"; $0.phase = "render"; $0.progress = share }
        }
        // Decoding a long song in tiles reports each one, in thousandths of the whole.
        if let permille = line.firstCapture(#"moonwire\.progress\.vae\s+(\d+)"#).flatMap({ Double($0) }) {
            return { $0.stage = "Decoding stereo audio"; $0.phase = "finish"; $0.progress = min(1, permille / 1000) }
        }
        return nil
    }

    // MARK: Scores and tokens

    /// The score at another speed: its tempo marks scaled, its notes untouched.
    static func retime(_ abc: String, _ scale: Double) -> String {
        guard abs(scale - 1) >= 0.005 else { return abc }
        let expression = try! NSRegularExpression(pattern: #"^(Q:\s*(?:\d+/\d+\s*=\s*)?)(\d+)"#, options: .anchorsMatchLines)
        var result = abc
        for match in expression.matches(in: abc, range: NSRange(abc.startIndex..., in: abc)).reversed() {
            guard let number = Range(match.range(at: 2), in: abc), let tempo = Double(abc[number]),
                  let target = Range(match.range(at: 2), in: result) else { continue }
            let scaled = max(30, min(300, Int((tempo * scale).rounded(.toNearestOrEven))))
            result.replaceSubrange(target, with: String(scaled))
        }
        return result
    }

    /// Song tokens as the engine saves them: a plain list, or hex-encoded with metadata.
    static func semanticArtifact(_ url: URL) throws -> ([Int], [String: Any]) {
        let invalid = ServiceError("The music engine returned invalid song tokens.")
        guard let data = FileManager.default.contents(atPath: url.path), let value = try? JSONSerialization.jsonObject(with: data) else { throw invalid }
        if let codes = value as? [Any] { return (try integers(codes), [:]) }
        guard let object = value as? [String: Any], let hex = object["payload_hex"] as? String, let payload = Data(hex: hex),
              let codes = try? JSONSerialization.jsonObject(with: payload) as? [Any] else { throw invalid }
        return (try integers(codes), object["meta"] as? [String: Any] ?? [:])
    }

    private static func integers(_ values: [Any]) throws -> [Int] {
        try values.map {
            guard let number = $0 as? NSNumber, CFNumberIsFloatType(number) == false, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw ServiceError("The music engine returned invalid song tokens.")
            }
            return number.intValue
        }
    }

    // MARK: Audio

    struct Finished { var duration: Double; var waveform: [Double] }

    /// Checks the engine's WAV, writes the 24-bit FLAC beside it, and draws its
    /// waveform, reading in blocks so a long song never sits in memory whole.
    static func finish(_ wav: URL, lossless flac: URL, bins: Int = 300) throws -> Finished {
        let invalid = ServiceError("The engine returned invalid audio.")
        guard let input = try? AVAudioFile(forReading: wav), input.fileFormat.sampleRate == 48000, input.length > 0 else { throw invalid }
        let format = input.processingFormat
        let channels = Int(format.channelCount)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: channels,
                                       AVEncoderBitDepthHintKey: 24]
        try? FileManager.default.removeItem(at: flac)
        let output = try AVAudioFile(forWriting: flac, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let length = Int(input.length)
        // Bin edges as numpy's array_split draws them: the first bins take one extra frame.
        let (size, extra) = (length / bins, length % bins)
        func bin(of frame: Int) -> Int {
            let wide = extra * (size + 1)
            return frame < wide ? frame / (size + 1) : extra + (frame - wide) / max(size, 1)
        }
        var peaks = [Double](repeating: 0, count: bins)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else { throw invalid }
        var frame = 0
        while input.framePosition < input.length {
            try input.read(into: buffer)
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let data = buffer.floatChannelData else { throw invalid }
            for index in 0..<count {
                var peak: Float = 0
                for channel in 0..<channels {
                    let sample = data[channel][index]
                    guard sample.isFinite else { throw invalid }
                    peak = max(peak, abs(sample))
                }
                let target = min(bins - 1, bin(of: frame + index))
                peaks[target] = max(peaks[target], Double(peak))
            }
            frame += count
            try output.write(from: buffer)
        }
        return Finished(duration: Double(length) / 48000, waveform: peaks)
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

extension String {
    /// The capture groups of the first match, or nil.
    func captures(_ pattern: String) -> [String]? {
        let expression = try! NSRegularExpression(pattern: pattern)
        guard let match = expression.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: self).map { String(self[$0]) } ?? "" }
    }

    func firstCapture(_ pattern: String) -> String? { captures(pattern)?.first }
}
