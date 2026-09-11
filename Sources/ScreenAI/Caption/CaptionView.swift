import SwiftUI

struct CaptionView: View {
    @ObservedObject var model: CaptionModel
    @ObservedObject var settings: SettingsStore

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if model.entries.isEmpty {
                Text("按 \(settings.hotkey.displayString) 截图并分析")
                    .font(.system(size: settings.captionFontSize - 1))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.vertical, 4)
            }
            ForEach(Array(model.entries.prefix(settings.captionHistoryCount).enumerated()), id: \.element.id) { index, entry in
                row(entry, index: index)
            }
        }
        .padding(10)
        .frame(width: settings.captionWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.82 * settings.captionOpacity)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12 * settings.captionOpacity), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(model.phoneConnected ? Color.green : Color.gray).frame(width: 7, height: 7)
            Text("ScreenAI").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.7))
            Spacer()
            if settings.captionMode == .marquee {
                Button(action: { model.isPaused.toggle() }) {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.plain).foregroundColor(.white.opacity(0.7))
                .help(model.isPaused ? "继续滚动" : "暂停滚动")
            }
            Button(action: { model.clear() }) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundColor(.white.opacity(0.7)).help("清空")
        }
    }

    @ViewBuilder
    private func row(_ entry: CaptionEntry, index: Int) -> some View {
        let opacity = index == 0 ? 1.0 : max(0.35, 1.0 - Double(index) * 0.15)
        let base = settings.captionFontSize
        let size = index == 0 ? base : max(9, base - 2)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                icon(for: entry.kind)
                Text(CaptionView.timeFormatter.string(from: entry.time))
                Spacer(minLength: 0)
            }
            .font(.system(size: max(9, size - 3)))
            .foregroundColor(.white.opacity(0.6))

            if entry.kind == .pending && entry.text.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(entry.note.isEmpty ? "分析中…" : entry.note).font(.system(size: size)).foregroundColor(.white.opacity(0.8))
                }
            } else if index == 0 && settings.captionMode == .marquee && entry.kind == .success {
                MarqueeText(text: entry.text, font: .system(size: size, weight: .medium), paused: model.isPaused)
                    .foregroundColor(.white)
                    .frame(height: size * 1.5)
            } else {
                Text(entry.text)
                    .font(.system(size: size, weight: index == 0 ? .medium : .regular))
                    .foregroundColor(color(for: entry.kind))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(index == 0 && entry.kind != .status ? RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.10)) : nil)
        .opacity(opacity)
    }

    private func icon(for kind: CaptionEntry.Kind) -> some View {
        Group {
            switch kind {
            case .pending: Image(systemName: "hourglass")
            case .success: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .error: Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
            case .status: Image(systemName: "info.circle.fill").foregroundColor(.orange)
            }
        }
    }

    private func color(for kind: CaptionEntry.Kind) -> Color {
        switch kind {
        case .error: return Color(red: 1, green: 0.5, blue: 0.5)
        case .status: return Color(red: 1, green: 0.75, blue: 0.4)
        default: return .white
        }
    }
}

/// 跑马灯文本：从右向左匀速滚动，文本短于宽度时静态显示。
struct MarqueeText: View {
    let text: String
    let font: Font
    var paused: Bool
    var speed: CGFloat = 30
    @State private var textWidth: CGFloat = 0
    @State private var startDate = Date()
    @State private var pausedOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            if textWidth <= width {
                measured.frame(width: width, alignment: .leading)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { ctx in
                    let elapsed = ctx.date.timeIntervalSince(startDate)
                    let total = textWidth + width
                    let offset = width - CGFloat(elapsed * Double(speed)).truncatingRemainder(dividingBy: total)
                    measured.offset(x: offset)
                }
            }
        }
        .clipped()
        .onChange(of: text) { _ in startDate = Date() }
    }

    private var measured: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .background(GeometryReader { g in
                Color.clear.preference(key: WidthKey.self, value: g.size.width)
            })
            .onPreferenceChange(WidthKey.self) { textWidth = $0 }
    }

    private struct WidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }
}
