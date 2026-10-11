import AppKit
import SwiftUI

/// The mark from the app icon: a warm crescent whose dark side is a waveform.
struct MoonMark: View {
    var size: CGFloat = 64

    var body: some View {
        Canvas { context, canvas in
            // Drawn on the icon's 1024-point grid, cropped to the moon.
            let scale = canvas.width / 700
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: (x - 162) * scale, y: (y - 162) * scale, width: w * scale, height: h * scale)
            }
            var crescent = Path(ellipseIn: rect(182, 182, 660, 660))
            crescent = crescent.subtracting(Path(ellipseIn: rect(360, 150, 580, 580)))
            context.fill(crescent, with: .linearGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.91, blue: 0.66), Theme.accent, Color(red: 0.96, green: 0.54, blue: 0.31)]),
                startPoint: rect(230, 250, 0, 0).origin, endPoint: rect(640, 840, 0, 0).origin))
            var wave = Path()
            for (x, y, height) in [(433.0, 380.0, 200.0), (511, 290, 380), (589, 340, 280), (667, 280, 400), (745, 390, 180)] {
                wave.addRoundedRect(in: rect(x, y, 44, height), cornerSize: CGSize(width: 22 * scale, height: 22 * scale))
            }
            context.fill(wave, with: .linearGradient(
                Gradient(colors: [Color(red: 0.84, green: 0.89, blue: 1.0), Color(red: 0.47, green: 0.59, blue: 0.95)]),
                startPoint: rect(430, 280, 0, 0).origin, endPoint: rect(800, 690, 0, 0).origin))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A recording drawn as bars, optionally filled up to the playhead and scrubbable.
struct WaveformView: View {
    var samples: [Double]
    var progress: Double? = nil
    var tint = Theme.accent
    var onSeek: ((Double) -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let pitch: CGFloat = 3.5, bar: CGFloat = 2
                let count = max(1, Int(size.width / pitch))
                let peak = max(samples.max() ?? 1, 0.05)
                let played = progress.map { Int((Double(count) * $0).rounded()) } ?? count
                var past = Path(), future = Path()
                for index in 0..<count {
                    // Each bar is the loudest sample in its slice.
                    var level = 0.12
                    if !samples.isEmpty {
                        let start = index * samples.count / count
                        let end = min(samples.count, max(start + 1, (index + 1) * samples.count / count))
                        level = samples[start..<end].max() ?? 0
                    }
                    let height = max(2, CGFloat(level / peak) * size.height)
                    let rect = CGRect(x: CGFloat(index) * pitch, y: (size.height - height) / 2, width: bar, height: height)
                    if index < played { past.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1)) }
                    else { future.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1)) }
                }
                context.fill(past, with: .color(progress == nil ? tint.opacity(0.55) : tint))
                context.fill(future, with: .color(.white.opacity(0.2)))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onSeek?(min(1, max(0, value.location.x / max(1, proxy.size.width))))
            }, including: onSeek == nil ? .none : .all)
        }
        .accessibilityHidden(true)
    }
}

struct SectionTitle<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            trailing
        }
    }
}

/// A short status line: what is missing, or what went wrong.
struct Callout: View {
    var text: String
    var symbol = "exclamationmark.circle.fill"
    var tint = Theme.warning

    var body: some View {
        Label { Text(text).foregroundStyle(.primary.opacity(0.9)).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}

/// A plain-text editor for lyrics, tinting `[Section]` labels, or for an ABC
/// score, set in a fixed-width face with its header fields and chords tinted.
struct LyricsEditor: NSViewRepresentable {
    @Binding var text: String
    var score = false
    var onEdit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 14, height: 16)
        view.font = font
        view.textColor = Self.textColor
        view.insertionPointColor = Theme.nsAccent
        view.defaultParagraphStyle = Self.paragraph
        view.typingAttributes = [.font: font, .foregroundColor: Self.textColor, .paragraphStyle: Self.paragraph]
        view.delegate = context.coordinator
        view.string = text
        context.coordinator.highlight(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = context.environment.isEnabled
        if view.string != text {
            view.string = text
            context.coordinator.highlight(view)
        }
    }

    fileprivate var font: NSFont { score ? .monospacedSystemFont(ofSize: 12.5, weight: .regular) : .systemFont(ofSize: 14) }
    fileprivate var accentFont: NSFont { score ? .monospacedSystemFont(ofSize: 12.5, weight: .semibold) : .systemFont(ofSize: 14, weight: .semibold) }
    fileprivate static let textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
    fileprivate static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        return style
    }()
    fileprivate static let sectionLabel = try? NSRegularExpression(pattern: "\\[[^\\]\\n]+\\]")
    /// Header fields such as `K:F` at the start of a line, and chord names in quotes.
    fileprivate static let scoreMarks = try? NSRegularExpression(pattern: "^[A-Za-z]:.*$|\"[^\"\\n]*\"", options: .anchorsMatchLines)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LyricsEditor
        init(_ parent: LyricsEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.onEdit()
            highlight(view)
        }

        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: parent.font, .foregroundColor: LyricsEditor.textColor, .paragraphStyle: LyricsEditor.paragraph], range: whole)
            let accent = parent.accentFont
            (parent.score ? LyricsEditor.scoreMarks : LyricsEditor.sectionLabel)?.enumerateMatches(in: storage.string, range: whole) { match, _, _ in
                if let range = match?.range {
                    storage.addAttributes([.foregroundColor: Theme.nsAccent, .font: accent], range: range)
                }
            }
            storage.endEditing()
        }
    }
}

/// Elapsed time that ticks without redrawing anything else.
struct ElapsedText: View {
    var since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(clockText(context.date.timeIntervalSince(since))).monospacedDigit()
        }
    }
}

extension Date {
    /// "Today 14:05", "Yesterday", or a short date.
    var friendly: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today " + formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(self) { return "Yesterday " + formatted(date: .omitted, time: .shortened) }
        return formatted(date: .abbreviated, time: .omitted)
    }
}
