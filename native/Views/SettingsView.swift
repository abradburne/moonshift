import SwiftUI

struct SettingsView: View {
    @Bindable var studio: Studio

    var body: some View {
        TabView {
            GeneralSettings(studio: studio).tabItem { Label("General", systemImage: "gearshape") }
            ModelSettings(studio: studio).tabItem { Label("Models", systemImage: "shippingbox") }
        }
        .frame(width: 520)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}

private struct GeneralSettings: View {
    @Bindable var studio: Studio
    @State private var quality = Quality.preferred

    var body: some View {
        Form {
            Section {
                Picker("Quality for new covers", selection: $quality) {
                    ForEach(Quality.allCases) { Text("\($0.name) (\($0.bits))").tag($0) }
                }
                .onChange(of: quality) { _, new in Quality.preferred = new }
            } footer: {
                Text("High precision keeps more of the music model and needs more memory. Each cover can also choose its own.")
            }
            Section {
                Toggle("Look up songs online", isOn: $studio.onlineLookup)
            } footer: {
                Text("When on, Moonshift can send a song's title and artist to LRCLIB to find lyrics, and a short audio fingerprint to Shazam to name a recording. Your recordings and covers never leave your Mac.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelSettings: View {
    var studio: Studio
    @State private var installing: Quality?
    @State private var installingLookup = false

    var body: some View {
        Form {
            Section("Installed on this Mac") {
                row("Transcription", "Hears the melody and chords in a song", ready: studio.health?.transcriptionReady) { installing = .preferred }
                ForEach(Quality.allCases) { quality in
                    row("Music model · \(quality.name)", quality.detail, ready: studio.health?.ready(quality)) { installing = quality }
                }
                row("Song identification", "Optional. Names a recording using Shazam", ready: studio.health?.lookupReady) { installingLookup = true }
            }
            Section {
                LabeledContent("Location") {
                    HStack {
                        Text(studio.service.root.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Show", systemImage: "folder") { NSWorkspace.shared.open(studio.service.root) }.labelStyle(.iconOnly).help("Show in Finder")
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Models, covers and takes are kept together in this folder. The models are for personal, non-commercial use under their own terms.")
                    HStack(spacing: 14) {
                        Link("Music model terms", destination: URL(string: "https://huggingface.co/m-a-p/YuE2-3B")!)
                        Link("Transcription model terms", destination: URL(string: "https://huggingface.co/m-a-p/SheetSage2")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await studio.refreshHealth() }
        .sheet(item: $installing) { SetupSheet(studio: studio, quality: $0) }
        .sheet(isPresented: $installingLookup) { SetupSheet(lookupFor: studio) }
    }

    private func row(_ title: String, _ detail: String, ready: Bool?, install: @escaping () -> Void) -> some View {
        LabeledContent {
            if ready == true {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent).labelStyle(.titleAndIcon)
            } else {
                Button("Install…", action: install).disabled(studio.installer.running)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}
