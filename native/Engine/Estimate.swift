import Foundation

/// Model selection and conservative memory forecasts. Estimates are planning
/// aids; the live guard in the job runner enforces the limit.
struct Estimator {
    var installed: (String) -> Bool
    var coversInstalled: () -> Bool

    init(paths: Paths) {
        installed = { paths.installed($0) }
        coversInstalled = { paths.coversInstalled }
    }

    init(installed: @escaping (String) -> Bool, coversInstalled: @escaping () -> Bool) {
        self.installed = installed
        self.coversInstalled = coversInstalled
    }

    /// Automatic prefers 8-bit, and falls back to whichever model is installed.
    func engine(for project: Project) -> String {
        if let choice = project.engine, choice == "metal-q4" || choice == "metal-q8" { return choice }
        return installed("metal-q8") || !installed("metal-q4") ? "metal-q8" : "metal-q4"
    }

    func estimate(_ project: Project, kind: String = "generate", memory: MemoryState) -> RenderEstimate {
        let engine = engine(for: project)
        let budget = project.max_tokens
        // Text and score prefix, with an allowance for planning the score when there is none.
        let text = [project.lyrics, project.style, project.vocal_prompt, project.abc].joined(separator: " ")
        let planning = project.cot != "off" && project.abc.trimmed.isEmpty ? 4096 : 256
        let prefix = Int(Double(text.utf8.count) / 3) + planning
        let branches = project.cfg_scale == 1 ? 1.0 : 2.0
        // Without guidance the first cache is always a full 5120-token chunk, so a short song costs as much as one.
        let cached = branches == 1 ? max(budget, 5120) : budget
        // 28 layers * 8 KV heads * 128 dimensions * K+V * fp16 bytes.
        let cache = Double(prefix + cached) * 114688 * branches / Machine.gib
        let low: Double, high: Double, label: String
        if kind == "transcribe" {
            // CPU FP32 transcription measured 2.38 GB; retain room for longer songs.
            (low, high, label) = (3.0, 6.0, "Reference transcription · CPU")
        } else {
            let base = engine == "metal-q4" ? 5.8 : 7.4
            (low, high, label) = (base + cache, base + cache + 2.5, engine == "metal-q4" ? "Metal · 4-bit" : "Metal · 8-bit")
        }
        var reasons: [String] = []
        if kind == "transcribe", !coversInstalled() { reasons.append("The transcription models are not installed yet. Install them in Settings.") }
        if kind == "generate", !installed(engine) { reasons.append("This music model is not installed yet. Install it in Settings.") }
        if high > memory.limit_gib {
            reasons.append(String(format: "Estimated peak %.1f GB exceeds the %.1f GB memory limit. Choose 4-bit or a shorter length.", high, memory.limit_gib))
        }
        if high + memory.reserve_gib > memory.available_gib {
            reasons.append(String(format: "About %.1f GB of available memory is needed, including space for macOS. Close other heavy apps or choose a shorter length.", high + memory.reserve_gib))
        }
        let words = project.lyrics.replacingPattern(#"\[[^\]]+\]"#, with: "").split(whereSeparator: { $0.isWhitespace }).count
        let seconds = Double(words) / 100 * 60 + 30
        let suggested = min(16000, max(1500, Int(seconds * 25 / 500 + 0.999) * 500))
        func rounded(_ value: Double, _ places: Double = 10) -> Double { (value * places).rounded() / places }
        let result = RenderEstimate(engine: engine, engine_label: label, memory: memory,
                                    peak_low_gib: rounded(low), peak_high_gib: rounded(high), cache_gib: rounded(cache, 100),
                                    prompt_tokens_estimate: prefix, audio_tokens: budget, duration_ceiling_seconds: Double(budget) / 25,
                                    suggested_tokens: suggested, allowed: reasons.isEmpty, reason: reasons.joined(separator: " "))
        if kind == "generate", (project.engine ?? "auto") == "auto", engine == "metal-q8", !reasons.isEmpty, installed("metal-q4") {
            var smaller = project
            smaller.engine = "metal-q4"
            var fitted = estimate(smaller, kind: kind, memory: memory)
            if fitted.allowed {
                fitted.selection_note = "Automatic chose 4-bit to fit available memory. You can choose 8-bit explicitly for more weight precision."
                return fitted
            }
        }
        return result
    }
}
