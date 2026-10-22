import SwiftUI

struct SettingsView: View {
    @Bindable var studio: Studio

    var body: some View {
        TabView {
            GeneralSettings(studio: studio).tabItem { Label("General", systemImage: "gearshape") }
            ModelSettings(studio: studio).tabItem { Label("Models", systemImage: "shippingbox") }
            AgentSettings(studio: studio).tabItem { Label("Agents", systemImage: "wand.and.stars") }
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
            if let unreadable = studio.health?.unreadable, unreadable > 0 {
                Section {
                    Callout(text: "\(unreadable) cover or take \(unreadable == 1 ? "file" : "files") in this folder could not be read and \(unreadable == 1 ? "is" : "are") not shown. They are listed in data/moonshift.log.")
                }
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

/// How to connect an AI agent to Moonshift over the Model Context Protocol.
private struct AgentSettings: View {
    var studio: Studio
    @State private var token = ""
    @State private var confirmingReset = false

    private var address: String { "http://127.0.0.1:\(studio.service.port)/mcp" }
    private var header: String { "Authorization: Bearer \(token)" }
    private var command: String { "claude mcp add --transport http moonshift \(address) --header \"\(header)\"" }

    var body: some View {
        Form {
            if let problem = studio.service.agentProblem {
                Section { Callout(text: problem) }
            }
            Section {
                copyable("Claude Code", command)
                copyable("Address", address)
                copyable("Header", header)
            } header: {
                Text("Connect an agent")
            } footer: {
                Text("An agent that speaks the Model Context Protocol can read your covers, edit their lyrics, style and score, and render takes, while Moonshift is open. The address only answers on this Mac, and only to agents that send this token. Changes an agent makes appear here as it makes them.")
            }
            Section {
                Button("New Token…") { confirmingReset = true }
            } footer: {
                Text("A new token disconnects every agent added with the old one.")
            }
        }
        .formStyle(.grouped)
        .onAppear { token = studio.service.agentToken }
        .confirmationDialog("Make a new agent token?", isPresented: $confirmingReset) {
            Button("New Token", role: .destructive) {
                studio.service.resetAgentToken()
                token = studio.service.agentToken
            }
        } message: {
            Text("Agents added with the current token will need to be added again.")
        }
    }

    private func copyable(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            HStack {
                Text(value).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
                .labelStyle(.iconOnly).help("Copy")
            }
        }
    }
}
