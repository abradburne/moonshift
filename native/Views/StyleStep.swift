import SwiftUI

/// Step two: the sound of the cover, who sings it, and how closely it follows the original.
struct StyleStep: View {
    @Bindable var studio: Studio
    @State private var naming: PresetName?

    /// A preset being named: a new one, or an existing one being renamed.
    struct PresetName: Identifiable {
        var id: String { existing?.id ?? "new" }
        var existing: CoverPreset?
        var text = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            StepHeading(title: "Choose its new sound")
            if studio.activeJob != nil { LockedBanner(studio: studio) }

            Group {
                presets
                style
                singer
                fidelity
            }
            .disabled(studio.locked)

            StepFooter(hint: studio.project.hasStyle ? nil : "Describe the style") {
                Button("Back") { studio.step = .song }.buttonStyle(.quiet)
                Button("Continue") { studio.step = .create }
                    .buttonStyle(.primary)
                    .disabled(!studio.project.hasStyle)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .sheet(item: $naming) { PresetNameSheet(studio: studio, naming: $0) }
    }

    // MARK: Presets

    private var presets: some View {
        let selected = studio.selectedPreset
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 10)], spacing: 10) {
            ForEach(studio.presets.presets) { preset in
                Button { choose(preset) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: preset.symbol).font(.system(size: 15)).frame(width: 22)
                            .foregroundStyle(selected == preset ? Theme.accent : .secondary)
                        Text(preset.name).fontWeight(.medium).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).frame(height: 44)
                }
                .buttonStyle(TileButtonStyle(selected: selected == preset))
                .contextMenu {
                    Button("Rename…", systemImage: "pencil") { naming = PresetName(existing: preset, text: preset.name) }
                    Button("Update with Current Style", systemImage: "arrow.triangle.2.circlepath") {
                        studio.project.cover_preset = studio.presets.save(name: preset.name, from: studio.project, replacing: preset.id).name
                    }
                    .disabled(selected == preset || !studio.project.hasStyle)
                    if preset.isBuiltin {
                        Button("Restore Original", systemImage: "arrow.uturn.backward") { studio.presets.remove(preset) }
                            .disabled(!studio.presets.isModified(preset))
                    } else {
                        Button("Delete", systemImage: "trash", role: .destructive) { studio.presets.remove(preset) }
                    }
                }
            }
        }
    }

    private func choose(_ preset: CoverPreset) {
        studio.project.style = preset.style
        studio.project.voice = preset.voice
        studio.project.vocal_prompt = preset.vocal
        studio.project.cover_preset = preset.name
    }

    // MARK: Style

    private var style: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Style") {
                // Edits made after picking a preset can be kept as a new one.
                if studio.selectedPreset == nil, studio.project.hasStyle {
                    Button("Save as Preset…", systemImage: "plus") { naming = PresetName() }
                }
            }
            TextField("Genre, instruments, mood, production…", text: $studio.project.style, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.plain).lineSpacing(3)
                .card(padding: 14)
                .onChange(of: studio.project.style) { syncPresetName() }
        }
    }

    /// The cover remembers the preset it came from only while it still matches it.
    private func syncPresetName() {
        let name = studio.selectedPreset?.name ?? ""
        if studio.project.cover_preset != name { studio.project.cover_preset = name }
    }

    // MARK: Singer

    private var singer: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Singer")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 10)], spacing: 10) {
                ForEach(Voice.all) { voice in
                    Button {
                        studio.project.voice = voice.id
                        studio.project.vocal_prompt = voice.prompt
                        syncPresetName()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: voice.symbol).font(.system(size: 13)).foregroundStyle(voice.color)
                                .frame(width: 28, height: 28).background(voice.color.opacity(0.16), in: Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(voice.name).fontWeight(.medium)
                                Text(voice.character).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).frame(height: 50)
                    }
                    .buttonStyle(TileButtonStyle(selected: studio.project.voice == voice.id, tint: voice.color))
                }
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vocal direction").font(.caption).foregroundStyle(.secondary)
                    TextField("How they should sing", text: $studio.project.vocal_prompt, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.plain).lineSpacing(3)
                        .onChange(of: studio.project.vocal_prompt) { syncPresetName() }
                }
                .card(padding: 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Language").font(.caption).foregroundStyle(.secondary)
                    TextField("English", text: $studio.project.language).textFieldStyle(.plain)
                }
                .card(padding: 12)
                .frame(width: 150)
            }
            Text("The singer is a new voice shaped by this description, not a copy of anyone's.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: Fidelity

    private var fidelity: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Keep from the original")
            HStack(spacing: 10) {
                option("melody", symbol: "music.note", title: "Melody", detail: "New chords and accompaniment. The style has the most freedom.")
                option("full", symbol: "music.quarternote.3", title: "Melody and harmony", detail: "Follows the original chord progression as well.")
            }
        }
    }

    private func option(_ value: String, symbol: String, title: String, detail: String) -> some View {
        Button { studio.project.cot = value } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(studio.project.cot == value ? Theme.accent : .secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(TileButtonStyle(selected: studio.project.cot == value))
    }
}

private struct PresetNameSheet: View {
    var studio: Studio
    @State var naming: StyleStep.PresetName
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(naming.existing == nil ? "Save as Preset" : "Rename Preset").font(.title3.weight(.semibold))
            TextField("Preset name", text: $naming.text).textFieldStyle(.roundedBorder).onSubmit(commit)
            if naming.existing == nil {
                Text("Keeps this style, singer and vocal direction together.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: commit).buttonStyle(.primary).disabled(naming.text.trimmed.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 380)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private func commit() {
        guard !naming.text.trimmed.isEmpty else { return }
        if let existing = naming.existing {
            studio.presets.rename(existing, to: naming.text)
            if studio.project.cover_preset == existing.name { studio.project.cover_preset = naming.text.trimmed }
        } else {
            studio.project.cover_preset = studio.presets.save(name: naming.text, from: studio.project).name
        }
        dismiss()
    }
}
