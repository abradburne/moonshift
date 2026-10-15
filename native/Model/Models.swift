import SwiftUI

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
