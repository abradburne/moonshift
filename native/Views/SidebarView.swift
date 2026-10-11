import SwiftUI

/// Every cover, most recently edited first.
struct SidebarView: View {
    @Bindable var studio: Studio
    @State private var deleting: Project?
    @State private var renaming: Project?
    @State private var newName = ""

    private var selection: Binding<String?> {
        Binding(get: { studio.project.id.isEmpty ? Self.draft : studio.project.id }, set: { id in
            guard let id, let target = studio.projects.first(where: { $0.id == id }) else { return }
            Task { await studio.open(target) }
        })
    }
    private static let draft = "draft"

    var body: some View {
        List(selection: selection) {
            Section("Covers") {
                // A cover that has not been saved yet still has a place in the list.
                if studio.project.id.isEmpty { CoverRow(studio: studio, project: studio.project).tag(Self.draft) }
                ForEach(studio.projects) { saved in
                    // The open cover shows its live edits.
                    let project = saved.id == studio.project.id ? studio.project : saved
                    CoverRow(studio: studio, project: project)
                        .tag(saved.id)
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") {
                                newName = project.title
                                renaming = project
                            }
                            Button("Duplicate", systemImage: "plus.square.on.square") { Task { await studio.duplicate(project) } }
                            Divider()
                            Button("Delete…", systemImage: "trash", role: .destructive) { deleting = project }
                                .disabled(studio.isBusy(project.id))
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let job = studio.runningJob, job.request.project.id != studio.project.id { BackgroundJobRow(studio: studio, job: job) }
        }
        .alert("Rename Cover", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { project in
            TextField("Name", text: $newName)
            Button("Rename") { Task { await studio.rename(project, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { project in
            Button("Delete Cover", role: .destructive) { Task { await studio.delete(project) } }
        } message: { project in
            let takes = studio.takeCount(project.id)
            Text(takes == 0 ? "This cover and its imported song will be removed. This cannot be undone."
                 : "This cover, its imported song and \(takes == 1 ? "its take" : "its \(takes) takes") will be removed. This cannot be undone.")
        }
    }
}

private struct CoverRow: View {
    var studio: Studio
    var project: Project

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title.trimmed.isEmpty ? Project.untitled : project.title).lineLimit(1)
                if !project.cover_preset.isEmpty || !project.songLabel.isEmpty {
                    Text(project.cover_preset.isEmpty ? project.songLabel : project.cover_preset)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if studio.isBusy(project.id) {
                ProgressView().controlSize(.small)
            } else {
                let takes = studio.takeCount(project.id)
                if takes > 0 { Text("\(takes)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 3)
    }
}

/// A cover being created while another one is open.
private struct BackgroundJobRow: View {
    var studio: Studio
    var job: Job

    var body: some View {
        Button {
            if let project = studio.projects.first(where: { $0.id == job.request.project.id }) { Task { await studio.open(project) } }
        } label: {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.request.project.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(job.isTranscription ? "Listening" : "Creating").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .help("Show this cover")
    }
}
