import Observation
import SwiftUI

/// A named sound: the style, the singer, and how they should sing.
struct CoverPreset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var style: String
    var voice: String
    var vocal: String

    var isBuiltin: Bool { CoverPreset.builtins.contains { $0.id == id } }
    var symbol: String { CoverPreset.looks[id]?.symbol ?? "slider.horizontal.3" }
    /// Built-in presets each have a colour; the user's own take the app's accent.
    var color: Color? { CoverPreset.looks[id]?.color }

    private static let looks: [String: (symbol: String, color: Color)] = [
        "jazz": ("pianokeys", .indigo), "soul": ("heart.fill", .orange), "acoustic": ("guitars.fill", .brown), "synth": ("waveform", .pink),
        "country": ("sun.dust.fill", .yellow), "punk": ("bolt.fill", .green), "cinematic": ("film.fill", .teal),
        "bossa": ("beach.umbrella.fill", .mint),
        "rnb": ("moon.stars.fill", .purple), "altrnb": ("cloud.moon.fill", .indigo), "neosoul": ("cup.and.saucer.fill", .brown),
        "gospel": ("hands.clap.fill", .yellow), "boombap": ("radio.fill", .orange), "trap": ("flame.fill", .red),
        "drill": ("building.2.fill", .gray), "phonk": ("car.fill", .pink), "jersey": ("figure.dance", .cyan),
        "glam": ("star.circle.fill", .pink), "metal": ("hammer.fill", .red), "metalcore": ("waveform.path.ecg", .orange),
        "industrial": ("gearshape.2.fill", .gray), "grunge": ("cloud.rain.fill", .brown), "shoegaze": ("cloud.fog.fill", .purple),
        "disco": ("circle.hexagongrid.fill", .purple), "funk": ("figure.socialdance", .orange), "dnb": ("hare.fill", .green),
        "hyperpop": ("bubbles.and.sparkles.fill", .pink), "sleaze": ("camera.fill", .red), "lofi": ("headphones", .teal),
        "vaporwave": ("sun.haze.fill", .mint), "chiptune": ("gamecontroller.fill", .green),
        "afrobeats": ("sun.max.fill", .orange), "amapiano": ("dot.radiowaves.left.and.right", .teal),
        "reggaeton": ("flame.circle.fill", .red), "kpop": ("sparkle", .pink), "reggae": ("leaf.fill", .green),
        "bluegrass": ("tree.fill", .brown), "mariachi": ("music.mic", .yellow),
        "shanty": ("sailboat.fill", .blue), "chant": ("building.columns.fill", .gray), "keychange": ("wind", .cyan),
        "elevator": ("arrow.up.arrow.down", .mint), "barbershop": ("person.3.fill", .red), "bardcore": ("crown.fill", .yellow),
        "western": ("sun.horizon.fill", .orange), "horror": ("theatermasks.fill", .purple), "boss": ("bolt.shield.fill", .red),
        "scifi": ("antenna.radiowaves.left.and.right", .green)
    ]

    /// A built-in sound sung by one of the singers, in their own manner unless `vocal` asks for another.
    private static func builtin(_ id: String, _ name: String, voice: String, vocal: String? = nil, _ style: String) -> CoverPreset {
        CoverPreset(id: id, name: name, style: style, voice: voice, vocal: vocal ?? Voice.named(voice)?.prompt ?? "")
    }

    static let builtins = families.flatMap(\.presets)

    /// The built-in presets by kind of music. The first family is always on show; the rest wait behind "more styles".
    static let families: [PresetFamily] = [
        PresetFamily(id: "essentials", title: "Essentials", presets: [
            builtin("jazz", "Late-night jazz", voice: "velvet", "Intimate jazz club, brushed drums, upright bass, warm piano, subtle swing, spacious live-room production"),
            builtin("soul", "Vintage soul", voice: "ember", "Vintage soul, live rhythm section, warm electric piano, expressive bass, brass accents, rich analog production"),
            builtin("acoustic", "Acoustic", voice: "atlas", "Stripped-back acoustic, fingerpicked guitar, gentle percussion, warm intimate room, natural dynamics"),
            builtin("synth", "80s synth-pop", voice: "nova", "1980s synth-pop, shimmering analog synths, pulsing bass, gated drums, wide lush chorus, polished retro production"),
            builtin("country", "Country", voice: "atlas", "Country, acoustic guitar, pedal steel, steady live drums, warm bass, storytelling intimacy, organic Nashville production"),
            builtin("punk", "Pop punk", voice: "riot", "Pop punk, driving distorted guitars, punchy live drums, energetic bass, explosive chorus, raw lively production"),
            builtin("cinematic", "Cinematic", voice: "halo", "Cinematic orchestral ballad, piano, swelling strings, deep percussion, expressive dynamics, expansive emotional production"),
            builtin("bossa", "Bossa nova", voice: "velvet", "Bossa nova, nylon-string guitar, soft percussion, upright bass, gentle syncopation, intimate sunlit production")
        ]),
        PresetFamily(id: "hiphop", title: "R&B and hip hop", presets: [
            builtin("rnb", "90s slow jam", voice: "ember",
                vocal: "Silky female R&B alto, melismatic runs, stacked close harmonies, breathy ad-libs between lines",
                "1990s slow-jam R&B, lush Rhodes chords, deep round sub bass, finger snaps and swung hi-hats, layered harmonies, smooth late-night production"),
            builtin("altrnb", "Alt R&B", voice: "nova",
                vocal: "Hazy male falsetto, half-whispered verses, drifting layered harmonies, melancholy restraint",
                "Moody alternative R&B, dark ambient pads, slow half-time trap drums, pitched vocal chops, sparse sub bass, nocturnal reverb-soaked production"),
            builtin("neosoul", "Neo-soul", voice: "velvet",
                vocal: "Warm female contralto, unhurried behind-the-beat phrasing, jazzy scatted asides",
                "Neo-soul, loose drunken-swing drums, warm Rhodes and muted guitar, round fingered bass, jazz chord extensions, organic analog production"),
            builtin("gospel", "Gospel choir", voice: "ember",
                vocal: "Powerful female gospel alto, soaring ad-libs and growls, answered by a full choir",
                "Gospel, Hammond organ, full mass choir, rousing piano, hand claps and tambourine, rising key changes, uplifting live church production"),
            builtin("funk", "Funk", voice: "nova",
                vocal: "Gritty male funk tenor, punchy rhythmic lines, falsetto squeals, crowd-hyping ad-libs",
                "Tight 1970s funk, slap bass, choppy clavinet, wah guitar, punchy horn stabs, deep-pocket groove, sweaty live band production"),
            builtin("boombap", "90s boom bap", voice: "cipher",
                "1990s East Coast boom bap hip hop, dusty sampled jazz loop, hard swung drums, vinyl crackle, deep upright bass, gritty underground production"),
            builtin("trap", "Trap", voice: "cipher",
                vocal: "Male rap voice, rapid triplet flow, melodic autotuned hook, confident ad-libs",
                "Modern trap, booming 808 bass, rolling rapid-fire hi-hats, hard claps, dark minor-key bells and plucks, heavy polished production"),
            builtin("drill", "UK drill", voice: "cipher",
                vocal: "Cold low male rap voice, clipped menacing flow, deadpan delivery, sparse ad-libs",
                "UK drill, sliding 808 bass glides, skippy syncopated hi-hats, ominous piano and choir stabs, cold menacing atmosphere, tight modern production")
        ]),
        PresetFamily(id: "rock", title: "Rock and metal", presets: [
            builtin("glam", "Glam rock", voice: "riot",
                vocal: "Flamboyant male rock tenor, theatrical swagger, falsetto whoops, stacked gang harmonies",
                "1970s glam rock, stomping beat, crunchy fuzz guitars, handclaps, pounding piano, huge chanted chorus, glittering theatrical production"),
            builtin("metal", "Heavy metal", voice: "riot",
                vocal: "Powerful male metal tenor, soaring operatic highs, gritty edge, sustained battle-cry notes",
                "Heavy metal, chugging down-tuned guitars, galloping riffs, double-kick drums, blazing twin-guitar solo, massive loud production"),
            builtin("metalcore", "Metalcore", voice: "riot",
                vocal: "Male vocalist alternating harsh screamed verses with a soaring clean melodic chorus",
                "Metalcore, drop-tuned riffs, crushing breakdowns, blast beats, atmospheric synth layers, huge anthemic chorus, tight modern production"),
            builtin("industrial", "Industrial", voice: "atlas",
                vocal: "Distorted male baritone, cold whispered verses, snarling shouted chorus",
                "Industrial rock, pounding mechanical drums, distorted synth bass, metallic clanks and noise, abrasive guitars, dark aggressive production"),
            builtin("grunge", "90s grunge", voice: "riot",
                vocal: "Weary male tenor, mumbled brooding verses, raw throat-shredding chorus",
                "Early 1990s grunge, sludgy distorted guitars, quiet verses and loud choruses, heavy live drums, murky bass, raw garage production"),
            builtin("shoegaze", "Shoegaze", voice: "halo",
                vocal: "Dreamy female voice buried in the mix, soft and wordless, floating behind the guitars",
                "Shoegaze, walls of reverb-drenched fuzz guitars, swirling feedback, driving drums, hazy wall-of-sound production")
        ]),
        PresetFamily(id: "dance", title: "Dance and electronic", presets: [
            builtin("disco", "Disco", voice: "ember",
                "1970s disco, four-on-the-floor beat, octave-jumping bassline, lush string section, funky rhythm guitar, horn stabs, glittering dancefloor production"),
            builtin("phonk", "Drift phonk", voice: "cipher",
                vocal: "Pitched-down male rap voice, chopped and repeated chants, distorted Memphis tape grit",
                "Drift phonk, distorted cowbell melodies, saturated booming 808s, fast aggressive tempo, Memphis rap vocal chops, blown-out gritty production"),
            builtin("jersey", "Jersey club", voice: "nova",
                vocal: "Bright pop vocal chopped into stuttering repeats, sped-up melodic hooks, playful energy",
                "Jersey club, bouncing kick triplets, chopped vocal samples, bed-squeak percussion, sped-up melody, relentless high-energy dance production"),
            builtin("dnb", "Drum & bass", voice: "halo",
                "Liquid drum and bass at 174 BPM, rolling breakbeats, deep reese bass, euphoric piano, atmospheric pads, crisp energetic production"),
            builtin("hyperpop", "Hyperpop", voice: "nova",
                vocal: "Pitched-up pop voice, heavy autotune, glitchy stutters, sugary chipmunk harmonies",
                "Hyperpop, maximalist distorted synths, blown-out 808s, glitch edits, bubblegum melodies, chaotic hyper-compressed production"),
            builtin("sleaze", "Indie sleaze", voice: "nova",
                vocal: "Deadpan cool vocal, half-spoken bratty verses, shouted chorus, too cool to care",
                "Indie sleaze electroclash, distorted dance-punk bass, cowbell, scuzzy analog synths, driving disco hi-hats, flash-photo party production"),
            builtin("lofi", "Lo-fi beats", voice: "velvet",
                "Lo-fi hip hop, dusty jazzy chords, lazy swung drums, vinyl crackle, tape wobble, mellow rainy-day bedroom production"),
            builtin("vaporwave", "Vaporwave", voice: "halo",
                vocal: "Slowed, pitched-down dreamy vocal, drenched in reverb, drifting in and out",
                "Vaporwave, slowed smooth-jazz and muzak samples, detuned synths, cassette warble, empty-mall reverb, nostalgic surreal production")
        ]),
        PresetFamily(id: "global", title: "Global and roots", presets: [
            builtin("afrobeats", "Afrobeats", voice: "nova",
                vocal: "Smooth male tenor, relaxed melodic flow, call-and-response hooks, easy confidence",
                "Afrobeats, bouncy syncopated percussion, log drums, warm palm-muted guitar licks, sunny synths, deep groove, polished Lagos production"),
            builtin("amapiano", "Amapiano", voice: "ember",
                "Amapiano, rolling log-drum basslines, shuffling shakers, jazzy piano chords, airy pads, unhurried hypnotic groove, deep-house warmth"),
            builtin("reggaeton", "Reggaeton", voice: "nova",
                vocal: "Male Latin pop tenor, sultry close-mic delivery, rhythmic melodic flow",
                "Reggaeton, dembow rhythm, deep sub bass, crisp snares, tropical synth plucks, sensual nightclub atmosphere, glossy modern production"),
            builtin("kpop", "K-pop", voice: "duet",
                vocal: "Bright group vocals trading lines, a rap break, then everyone together in a huge layered chorus",
                "K-pop, genre-switching sections, punchy EDM drop, slick synths and brass hits, dramatic pre-chorus build, ultra-polished high-energy production"),
            builtin("reggae", "Roots reggae", voice: "atlas",
                vocal: "Warm male baritone, relaxed laid-back phrasing, soulful backing harmonies",
                "Roots reggae, one-drop rhythm, offbeat guitar skank, deep round bass, bubbling organ, dub echoes, warm sunny production"),
            builtin("bluegrass", "Bluegrass", voice: "duet",
                vocal: "High lonesome lead voice with a close harmony partner on every chorus",
                "Bluegrass, rapid banjo rolls, flatpicked guitar, fiddle and mandolin trading breaks, upright bass, front-porch live production"),
            builtin("mariachi", "Mariachi", voice: "atlas",
                vocal: "Proud male ranchera baritone, dramatic sustained notes, joyful gritos between lines",
                "Mariachi, blazing trumpets, sweeping violins, vihuela and guitarrón, festive rhythm, triumphant open-air plaza production")
        ]),
        PresetFamily(id: "wild", title: "Wildcards", presets: [
            builtin("chiptune", "8-bit chiptune", voice: "nova",
                vocal: "Bright vocoded pop voice, robotic and cheerful, crisp syllables",
                "8-bit chiptune, square-wave leads, triangle bass, noise-channel drums, fast arpeggios, retro handheld console production"),
            builtin("shanty", "Sea shanty", voice: "duet",
                vocal: "Rowdy crew of male voices, a lead calling each line and everyone roaring back",
                "Sea shanty, stomping feet on wooden boards, accordion, fiddle, tin whistle, hearty singalong, rough tavern-room production"),
            builtin("chant", "Monastery", voice: "atlas",
                vocal: "Choir of male monks in plainchant, slow unison lines, solemn and devout",
                "Gregorian chant over ambient drones, sparse low organ, vast stone cathedral reverb, candlelit solemn atmosphere"),
            builtin("keychange", "Big key change", voice: "duet",
                vocal: "Two singers belting at full power, arms in the air, dramatic and utterly sincere",
                "Over-the-top European pop contest anthem, folk-instrument hook, pyrotechnic synths, wind-machine drama, truck-driver key change into the final chorus, stadium production"),
            builtin("elevator", "Elevator music", voice: "velvet",
                vocal: "Soft, polite crooner, barely there, never raising their voice",
                "Easy-listening elevator music, soft electric piano, muted bossa drums, mellow flute, gentle strings, smooth inoffensive lounge production"),
            builtin("barbershop", "Barbershop", voice: "duet",
                vocal: "Four-part a cappella male barbershop quartet, tight ringing harmonies, booming bass anchor",
                "A cappella barbershop, close four-part harmony, finger snaps, no instruments, vintage straw-hat charm"),
            builtin("bardcore", "Bardcore", voice: "halo",
                vocal: "Clear female folk voice, medieval minstrel phrasing, simple modal ornaments",
                "Bardcore, medieval lute, recorder, hurdy-gurdy, frame drum, tavern bustle, rustic period-instrument production"),
            builtin("western", "Desert western", voice: "atlas",
                "Spaghetti western, twangy reverb guitar, whistled melody, galloping drums, mournful trumpet, whip cracks, wide dusty desert production"),
            builtin("horror", "Horror movie", voice: "halo",
                vocal: "Eerie childlike soprano, whispered verses, unsettling hummed melodies",
                "Horror film score, detuned music box, dissonant strings, creaking drones, sudden stabs, creeping dread, haunted-house production"),
            builtin("boss", "Final boss", voice: "riot",
                vocal: "Male tenor belting like the fate of the world depends on it, with a Latin choir behind him",
                "Epic video-game final boss theme, chanting choir, shredding guitars, pounding orchestral drums, frantic strings, pipe organ, absurdly dramatic production"),
            builtin("scifi", "50s sci-fi", voice: "halo",
                vocal: "Cool female lounge voice, airy and otherworldly, gliding between notes",
                "1950s sci-fi B-movie, wobbling theremin, vibraphone, bongos, spacey reverb, retro-futurist lounge production")
        ])
    ]
}

struct PresetFamily: Identifiable {
    let id: String
    let title: String
    let presets: [CoverPreset]
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

    /// The user's own presets, in the order they were made.
    var custom: [CoverPreset] { presets.filter { !$0.isBuiltin } }

    /// A family's presets as the user has them, edits included.
    func presets(in family: PresetFamily) -> [CoverPreset] {
        family.presets.compactMap { builtin in presets.first { $0.id == builtin.id } }
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
