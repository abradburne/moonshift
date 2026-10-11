import SwiftUI

/// First launch: what Moonshift does, then one button to fetch what it needs.
struct OnboardingView: View {
    @Bindable var studio: Studio
    @State private var quality = Quality.preferred
    private var settingUp: Bool { studio.onboardingSetup }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Group {
                if settingUp {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Install the local models").font(.system(size: 28, weight: .bold, design: .rounded))
                        SetupPanel(studio: studio, plan: .engines(quality), quality: $quality, doneTitle: "Start Your First Cover") { studio.finishOnboarding() }
                    }
                } else {
                    welcome
                }
            }
            .frame(maxWidth: 520)
            Spacer(minLength: 24)
            // Setup can wait when the app is otherwise working.
            if studio.isReady, !studio.installer.running {
                Button("Set Up Later") { studio.finishOnboarding() }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.bottom, 22)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.3), value: settingUp)
    }

    private var welcome: some View {
        VStack(spacing: 30) {
            VStack(spacing: 16) {
                MoonMark(size: 92)
                Text("Welcome to Moonshift").font(.system(size: 34, weight: .bold, design: .rounded))
            }
            VStack(alignment: .leading, spacing: 20) {
                point("waveform", Theme.cool, "Bring a song", "Drop in a recording and its lyrics.")
                point("wand.and.stars", Theme.accent, "Give it a new sound", "Pick a style and a singer. Moonshift keeps the melody and performs the rest anew.")
                point("lock.fill", .secondary, "It stays on your Mac", "The models run locally. Your songs and covers are never uploaded.")
            }
            Button("Continue") { studio.onboardingSetup = true }.buttonStyle(.primaryLarge).keyboardShortcut(.defaultAction)
        }
    }

    private func point(_ symbol: String, _ tint: some ShapeStyle, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Installing from Settings or the Create step, after onboarding.
struct SetupSheet: View {
    var studio: Studio
    var plan: Installer.Plan
    @State private var quality: Quality
    @Environment(\.dismiss) private var dismiss

    init(studio: Studio, quality: Quality) {
        self.studio = studio
        plan = .engines(quality)
        _quality = State(initialValue: quality)
    }

    init(lookupFor studio: Studio) {
        self.studio = studio
        plan = .lookup
        _quality = State(initialValue: .preferred)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(plan == .lookup ? "Install song identification" : "Install the local models").font(.title2.weight(.semibold))
            SetupPanel(studio: studio, plan: plan == .lookup ? .lookup : .engines(quality), quality: plan == .lookup ? nil : $quality, doneTitle: "Done") { dismiss() }
            if !studio.installer.running, !studio.installer.succeeded {
                HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(studio.installer.running)
    }
}

/// What will be installed, anything standing in the way, then live progress.
struct SetupPanel: View {
    var studio: Studio
    var plan: Installer.Plan
    /// Offered as a choice before installing; nil when the plan fixes it.
    var quality: Binding<Quality>?
    var doneTitle: String
    var onDone: () -> Void

    @State private var showingLog = false
    private var installer: Installer { studio.installer }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if installer.succeeded {
                Label("Everything is installed", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(Theme.accent)
                steps
                HStack { Spacer(); Button(doneTitle, action: onDone).buttonStyle(.primaryLarge).keyboardShortcut(.defaultAction) }
            } else if !installer.steps.isEmpty {
                steps
                if let failure = installer.failure { Callout(text: failure) }
                DisclosureGroup("Details", isExpanded: $showingLog) {
                    ScrollView {
                        Text(installer.log.isEmpty ? "Waiting for output…" : installer.log)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(height: 150)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
                .font(.callout)
                HStack {
                    Spacer()
                    if installer.running {
                        Button("Stop") { installer.cancel() }.buttonStyle(.quiet)
                    } else {
                        Button("Back") { installer.reset() }.buttonStyle(.quiet)
                        Button("Try Again") { begin() }.buttonStyle(.primary)
                    }
                }
            } else {
                overview
            }
        }
        .onAppear {
            installer.reset()
            installer.checkTools()
        }
    }

    // MARK: Before installing

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            if plan == .lookup {
                Text("A small helper that can name a recording from a short audio fingerprint sent to Shazam. It is only used when you ask for it.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Moonshift downloads its music and transcription models once, and builds its engine for your Mac. After that, covers are made offline.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let quality {
                    VStack(spacing: 8) {
                        ForEach(Quality.allCases) { option in
                            Button { quality.wrappedValue = option } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.name).fontWeight(.medium)
                                        Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(Installer.downloadLabel(option)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                            }
                            .buttonStyle(TileButtonStyle(selected: quality.wrappedValue == option))
                        }
                    }
                }
                if !installer.missingTools.isEmpty { requirements }
            }
            HStack(spacing: 12) {
                if let free = installer.freeSpace, plan != .lookup {
                    let needed = Installer.downloadSize(quality?.wrappedValue ?? .standard)
                    if free < needed + 2_000_000_000 {
                        Callout(text: "Only \(free.formatted(.byteCount(style: .file))) is free on this disk.")
                    } else {
                        Text("\(Int(Double(free) / 1e9)) GB free on this disk").font(.callout).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button(plan == .lookup ? "Install" : "Download and Install") { begin() }
                    .buttonStyle(.primaryLarge)
                    .disabled(!canBegin)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Setup can start when nothing is missing, or Homebrew can supply what is.
    private var canBegin: Bool {
        plan == .lookup ? installer.tools.first { $0.id == "uv" }?.found == true || installer.homebrew != nil
            : installer.missingTools.allSatisfy { tool in installer.installableTools.contains(tool) }
    }

    private var requirements: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Needed first").font(.headline)
            ForEach(installer.missingTools) { tool in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: installer.installableTools.contains(tool) ? "arrow.down.circle" : "exclamationmark.circle.fill")
                        .foregroundStyle(installer.installableTools.contains(tool) ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).fontWeight(.medium)
                        Text(tool.purpose).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if installer.missingTools.contains(where: { $0.id == "clang" }) {
                command("Install Apple's developer tools, then check again:", "xcode-select --install")
            }
            if installer.homebrew != nil {
                if !installer.installableTools.isEmpty { Text("Moonshift will install these with Homebrew as its first step.").font(.caption).foregroundStyle(.secondary) }
            } else if installer.missingTools.contains(where: { $0.formula != nil }) {
                command("Install them with Homebrew (brew.sh), or any way you prefer:", "brew install " + installer.missingTools.compactMap(\.formula).joined(separator: " "))
            }
            Button("Check Again", systemImage: "arrow.clockwise") { installer.checkTools() }.buttonStyle(.quiet).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }

    private func command(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: While installing

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(installer.steps) { step in
                HStack(spacing: 12) {
                    Group {
                        switch step.state {
                        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                        case .running: ProgressView().controlSize(.small)
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.warning)
                        }
                    }
                    .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title).fontWeight(step.state == .running ? .semibold : .regular)
                            .foregroundStyle(step.state == .pending ? .secondary : .primary)
                        if step.state == .running {
                            Text(step.detail).font(.caption).foregroundStyle(.secondary)
                            if let fraction = step.fraction { ProgressView(value: fraction).tint(Theme.accent).padding(.top, 2) }
                        }
                    }
                    Spacer(minLength: 0)
                    if step.state == .running, let fraction = step.fraction {
                        Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .card(padding: 14)
    }

    private func begin() {
        if case .engines(let quality) = plan { Quality.preferred = quality }
        Task {
            if await installer.install(plan, installingTools: true) { await studio.installFinished() }
        }
    }
}
