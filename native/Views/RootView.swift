import SwiftUI
import UniformTypeIdentifiers

/// The window: startup states first, then the library and the open cover.
struct RootView: View {
    @Bindable var studio: Studio

    var body: some View {
        Group {
            switch studio.phase {
            case .starting:
                StatusScreen { ProgressView().controlSize(.small) }
            case .needsAccess:
                StatusScreen(title: "Allow access to the Moonshift folder",
                             message: "Moonshift keeps its models and your covers together in \(studio.service.root.path).") {
                    Button("Choose Folder…") { Task { await studio.grantFolderAccess() } }.buttonStyle(.primary)
                }
            case .offline(let message):
                StatusScreen(title: "The local engine is not running", message: message) {
                    HStack {
                        Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([studio.service.log]) }.buttonStyle(.quiet)
                        Button("Try Again") { Task { await studio.start() } }.buttonStyle(.primary)
                    }
                }
            case .needsSetup, .ready:
                // One branch for both, so onboarding stays on screen, with its
                // progress, as a first install turns "needs setup" into "ready".
                if studio.showsOnboarding || studio.phase == .needsSetup { OnboardingView(studio: studio) } else { WorkspaceView(studio: studio) }
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .alert(studio.notice?.title ?? "", isPresented: Binding(get: { studio.notice != nil }, set: { if !$0 { studio.notice = nil } })) {
            Button("OK") { studio.notice = nil }
        } message: {
            Text(studio.notice?.message ?? "")
        }
    }
}

/// A centred message for the moments before the app is usable.
private struct StatusScreen<Actions: View>: View {
    var title: String?
    var message: String?
    @ViewBuilder var actions: Actions

    init(title: String? = nil, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 18) {
            MoonMark(size: 72)
            if let title { Text(title).font(.title2.weight(.semibold)) }
            if let message {
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440).textSelection(.enabled)
            }
            actions.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WorkspaceView: View {
    @Bindable var studio: Studio
    @State private var dropping = false

    var body: some View {
        NavigationSplitView {
            SidebarView(studio: studio)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            ScrollView {
                Group {
                    switch studio.step {
                    case .song: SongStep(studio: studio)
                    case .style: StyleStep(studio: studio)
                    case .create: CreateStep(studio: studio)
                    }
                }
                .frame(maxWidth: Theme.contentWidth, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if studio.player.isLoaded { PlayerBar(player: studio.player).transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .animation(.snappy(duration: 0.25), value: studio.player.isLoaded)
            .overlay { if dropping { DropHighlight() } }
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                guard !studio.locked, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await studio.importSong(url) }
                }
                return true
            }
            .navigationTitle(studio.project.title.trimmed.isEmpty ? Project.untitled : studio.project.title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Step", selection: $studio.step) {
                        ForEach(CoverStep.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    // The toolbar's glass capsule takes the control's own width.
                    .fixedSize()
                    .help("Move between the song, its new style, and your takes")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await studio.newCover() } } label: { Label("New Cover", systemImage: "plus") }
                        .help("Start a new cover")
                }
            }
        }
        .sheet(item: $studio.reviewing) { LyricReviewSheet(studio: studio, candidate: $0) }
    }
}

private struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { Label("Drop to use this song", systemImage: "arrow.down.circle.fill").font(.title2.weight(.semibold)).foregroundStyle(Theme.accent) }
            .padding(14)
            .allowsHitTesting(false)
    }
}

/// The step's heading, kept to a single plain line.
struct StepHeading: View {
    var title: String

    var body: some View {
        Text(title).font(.system(size: 28, weight: .bold, design: .rounded)).padding(.top, 8)
    }
}

/// The step's closing row: what is still needed, and the way forward.
struct StepFooter<Action: View>: View {
    var hint: String?
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 14) {
            if let hint { Callout(text: hint, symbol: "circle.dotted", tint: .secondary) }
            Spacer(minLength: 12)
            action
        }
        .padding(.top, 6)
    }
}
