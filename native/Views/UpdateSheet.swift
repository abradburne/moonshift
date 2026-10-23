import SwiftUI

/// A newer Moonshift: what changed, and installing it when the user chooses.
struct UpdateSheet: View {
    var studio: Studio
    private var updater: Updater { studio.updater }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                MoonMark(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(24)
        .frame(width: 480)
    }

    private var title: String {
        switch updater.state {
        case .available(let release): "Moonshift \(release.version) is available"
        case .upToDate: "Moonshift is up to date"
        case .failed: "The update did not finish"
        case .downloading, .installing: "Updating Moonshift"
        default: "Checking for updates"
        }
    }

    private var subtitle: String {
        if case .upToDate = updater.state { return "Version \(updater.current) is the latest." }
        return "You have version \(updater.current)."
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case .available(let release):
            if let notes = release.body?.trimmed, !notes.isEmpty {
                ScrollView {
                    Text(Self.notes(notes)).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let blocker = studio.updateBlocker { Callout(text: blocker, symbol: "clock") }
            HStack {
                Button("Skip This Version") { updater.skip(release) }.buttonStyle(.quiet)
                Spacer()
                Button("Later") { updater.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { Task { await updater.install(release) } }
                    .buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(studio.updateBlocker != nil)
            }
        case .downloading, .installing:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                Text(updater.state == .downloading ? "Downloading…" : "Checking the signature and installing…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Callout(text: message)
            HStack {
                if let release = updater.offered, let page = URL(string: release.html_url) {
                    Button("Open Release Page") { NSWorkspace.shared.open(page) }.buttonStyle(.quiet)
                }
                Spacer()
                Button("OK") { updater.dismiss() }.keyboardShortcut(.defaultAction)
            }
        case .upToDate:
            HStack {
                Spacer()
                Button("OK") { updater.dismiss() }.keyboardShortcut(.defaultAction)
            }
        default:
            ProgressView().progressViewStyle(.linear).tint(Theme.accent)
        }
    }

    /// Release notes are Markdown: bold, links and line breaks are kept.
    private static func notes(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
