import AppKit
import SwiftUI

struct HistoryView: View {
    let history: HistoryStore
    @State private var dates: [String] = []
    @State private var selectedDate: String? = nil
    @State private var query = ""
    @State private var records: [HistoryRecord] = []
    @State private var selection = Set<String>()
    @State private var loading = false
    @State private var message = ""

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("日期", selection: $selectedDate) {
                    Text("最近").tag(String?.none)
                    ForEach(dates, id: \.self) { Text($0).tag(Optional($0)) }
                }.frame(width: 180)
                TextField("搜索结果 / 来源", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
                    .onSubmit { reload() }
                Button("刷新") { reload() }
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(records.count) 条").foregroundColor(.secondary)
                Button("导出所选…") { export(records.filter { selection.contains($0.id) }) }.disabled(selection.isEmpty)
                Button("导出当前列表…") { export(records) }.disabled(records.isEmpty)
            }
            .padding(10)
            Table(records, selection: $selection) {
                TableColumn("时间") { r in Text(HistoryView.timeFormatter.string(from: r.timestamp)) }.width(150)
                TableColumn("来源") { r in Text(r.captureSource) }.width(min: 100, ideal: 160)
                TableColumn("状态") { r in
                    Text(r.status == "success" ? "成功" : "失败").foregroundColor(r.status == "success" ? .green : .red)
                }.width(50)
                TableColumn("结果") { r in Text(r.result.isEmpty ? r.errorMessage : r.result).lineLimit(1) }
                TableColumn("模型") { r in Text(r.model) }.width(min: 80, ideal: 130)
                TableColumn("耗时") { r in Text("\(r.latencyMs) ms") }.width(70)
            }
            Divider()
            detail
        }
        .onAppear { reload() }
        .onChange(of: selectedDate) { _ in reload() }
    }

    @ViewBuilder
    private var detail: some View {
        if selection.count == 1, let r = records.first(where: { selection.contains($0.id) }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(HistoryView.timeFormatter.string(from: r.timestamp)).foregroundColor(.secondary)
                        Text(r.captureSource).foregroundColor(.secondary)
                        Text("\(r.provider) / \(r.model)").foregroundColor(.secondary)
                        Spacer()
                        Button("复制结果") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(r.result.isEmpty ? r.errorMessage : r.result, forType: .string)
                        }
                    }.font(.caption)
                    Text(r.result.isEmpty ? r.errorMessage : r.result).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let p = history.prompt(forHash: r.promptHash) {
                        DisclosureGroup("本次提示词") { Text(p).font(.caption).textSelection(.enabled) }.font(.caption)
                    }
                }.padding(10)
            }
            .frame(height: 170)
        } else {
            Text(message.isEmpty ? "选择一条记录查看完整内容" : message).foregroundColor(.secondary).frame(height: 40)
        }
    }

    private func reload() {
        loading = true
        let date = selectedDate
        let q = query
        let history = self.history
        DispatchQueue.global(qos: .userInitiated).async {
            let ds = history.dates()
            let recs = history.search(query: q, dates: date.map { [$0] }, limit: 1000)
            DispatchQueue.main.async {
                dates = ds
                records = recs
                loading = false
            }
        }
    }

    private func export(_ recs: [HistoryRecord]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "screenai-history-\(selectedDate ?? "recent").csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            let csv = "\u{FEFF}" + history.exportCSV(records: recs.sorted { $0.timestamp < $1.timestamp })
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                message = "已导出 \(recs.count) 条到 \(url.lastPathComponent)"
            } catch {
                message = "导出失败：\(error.localizedDescription)"
            }
        }
    }
}

final class HistoryWindowController {
    private let window: NSWindow

    init(state: AppState) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ScreenAI 历史记录"
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.contentView = NSHostingView(rootView: HistoryView(history: state.history))
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
