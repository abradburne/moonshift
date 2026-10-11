import Foundation
import Observation

/// A named sound: the style, the singer, and how they should sing.
struct CoverPreset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var style: String
    var voice: String
    var vocal: String

    var isBuiltin: Bool { CoverPreset.builtins.contains { $0.id == id } }
    var symbol: String { CoverPreset.symbols[id] ?? "slider.horizontal.3" }

    private static let symbols = [
        "jazz": "pianokeys", "soul": "heart.fill", "acoustic": "guitars.fill", "synth": "waveform",
        "country": "sun.dust.fill", "punk": "bolt.fill", "cinematic": "film.fill", "bossa": "beach.umbrella.fill"
    ]

    private static func builtin(_ id: String, _ name: String, voice: String, _ style: String) -> CoverPreset {
        CoverPreset(id: id, name: name, style: style, voice: voice, vocal: Voice.named(voice)?.prompt ?? "")
    }

    static let builtins: [CoverPreset] = [
        builtin("jazz", "Late-night jazz", voice: "velvet", "Intimate jazz club, brushed drums, upright bass, warm piano, subtle swing, spacious live-room production"),
        builtin("soul", "Vintage soul", voice: "ember", "Vintage soul, live rhythm section, warm electric piano, expressive bass, brass accents, rich analog production"),
        builtin("acoustic", "Acoustic", voice: "atlas", "Stripped-back acoustic, fingerpicked guitar, gentle percussion, warm intimate room, natural dynamics"),
        builtin("synth", "80s synth-pop", voice: "nova", "1980s synth-pop, shimmering analog synths, pulsing bass, gated drums, wide lush chorus, polished retro production"),
        builtin("country", "Country", voice: "atlas", "Country, acoustic guitar, pedal steel, steady live drums, warm bass, storytelling intimacy, organic Nashville production"),
        builtin("punk", "Pop punk", voice: "riot", "Pop punk, driving distorted guitars, punchy live drums, energetic bass, explosive chorus, raw lively production"),
        builtin("cinematic", "Cinematic", voice: "halo", "Cinematic orchestral ballad, piano, swelling strings, deep percussion, expressive dynamics, expansive emotional production"),
        builtin("bossa", "Bossa nova", voice: "velvet", "Bossa nova, nylon-string guitar, soft percussion, upright bass, gentle syncopation, intimate sunlit production")
    ]
}

/// Built-in presets plus the user's own. Only the user's changes are stored,
/// so presets added in a later version still appear.
@MainActor @Observable final class PresetStore {
    private(set) var presets: [CoverPreset] = []
    private static let key = "CoverStylePresets"

    init() {
        let saved = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([CoverPreset].self, from: $0) } ?? []
        presets = Self.merged(saved)
    }

    private static func merged(_ saved: [CoverPreset]) -> [CoverPreset] {
        let edited = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return CoverPreset.builtins.map { edited[$0.id] ?? $0 } + saved.filter { !$0.isBuiltin }
    }

    func preset(matching project: Project) -> CoverPreset? {
        presets.first { $0.style == project.style && $0.vocal == project.vocal_prompt && $0.voice == project.voice }
    }

    func isModified(_ preset: CoverPreset) -> Bool {
        CoverPreset.builtins.first { $0.id == preset.id }.map { $0 != preset } ?? false
    }

    @discardableResult func save(name: String, from project: Project, replacing id: String? = nil) -> CoverPreset {
        let preset = CoverPreset(id: id ?? UUID().uuidString, name: String(name.trimmed.prefix(80)),
                                 style: project.style, voice: project.voice, vocal: project.vocal_prompt)
        if let index = presets.firstIndex(where: { $0.id == preset.id }) { presets[index] = preset } else { presets.append(preset) }
        persist()
        return preset
    }

    func rename(_ preset: CoverPreset, to name: String) {
        guard let index = presets.firstIndex(of: preset), !name.trimmed.isEmpty else { return }
        presets[index].name = String(name.trimmed.prefix(80))
        persist()
    }

    /// Removes a custom preset, or restores a built-in one to its original sound.
    func remove(_ preset: CoverPreset) {
        if let original = CoverPreset.builtins.first(where: { $0.id == preset.id }) {
            if let index = presets.firstIndex(of: preset) { presets[index] = original }
        } else {
            presets.removeAll { $0.id == preset.id }
        }
        persist()
    }

    private func persist() {
        let changed = presets.filter { preset in !CoverPreset.builtins.contains(preset) }
        if let data = try? JSONEncoder().encode(changed) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
