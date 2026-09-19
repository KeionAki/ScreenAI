import Foundation
import Combine

struct CaptionEntry: Identifiable, Equatable {
    enum Kind { case pending, success, error, status }
    let id: String
    var text: String
    var source: String
    var time: Date
    var kind: Kind
    var note: String = ""     // 进行中的补充说明（如“思考中… 300 字”“键入中 40%”）
    /// 编程题：字幕不显示代码，只显示状态
    var isCode: Bool = false
}

/// 字幕窗口的数据：最新在最上。
final class CaptionModel: ObservableObject {
    @Published var entries: [CaptionEntry] = []
    @Published var isPaused = false
    @Published var phoneConnected = false

    func apply(_ event: PipelineEvent, maxCount: Int) {
        switch event {
        case let .started(id, source, mode):
            let isCode = mode == .type
            if let i = entries.firstIndex(where: { $0.id == id }) {
                entries[i].text = ""
                entries[i].note = ""
                entries[i].kind = .pending
                entries[i].time = Date()
                entries[i].isCode = isCode
            } else {
                entries.insert(CaptionEntry(id: id, text: "", source: source, time: Date(), kind: .pending, isCode: isCode), at: 0)
            }
        case let .thinking(id, chars):
            if let i = entries.firstIndex(where: { $0.id == id }), entries[i].kind == .pending {
                entries[i].note = "思考中… \(chars) 字"
            }
        case let .partial(id, delta):
            if let i = entries.firstIndex(where: { $0.id == id }) {
                entries[i].text += delta
                entries[i].note = ""
                // 一旦出现代码围栏即判定为编程题，字幕不再显示正文
                if !entries[i].isCode, CodeExtractor.containsCodeBlock(entries[i].text) {
                    entries[i].isCode = true
                }
            }
        case let .completed(id, text, source, _, _, mode):
            let isCode = mode == .type || CodeExtractor.containsCodeBlock(text)
            if let i = entries.firstIndex(where: { $0.id == id }) {
                entries[i].text = text
                entries[i].kind = .success
                entries[i].time = Date()
                entries[i].isCode = entries[i].isCode || isCode
                entries[i].note = ""
            } else {
                entries.insert(CaptionEntry(id: id, text: text, source: source, time: Date(), kind: .success, isCode: isCode), at: 0)
            }
        case let .failed(id, message, source):
            if let i = entries.firstIndex(where: { $0.id == id }) {
                entries[i].text = message
                entries[i].kind = .error
            } else {
                entries.insert(CaptionEntry(id: id, text: message, source: source ?? "", time: Date(), kind: .error), at: 0)
            }
        case let .status(message, _):
            entries.insert(CaptionEntry(id: UUID().uuidString, text: message, source: "", time: Date(), kind: .status), at: 0)
        }
        let limit = max(1, maxCount)
        if entries.count > limit {
            // 优先保留进行中的条目
            var kept: [CaptionEntry] = []
            for e in entries where kept.count < limit || e.kind == .pending { kept.append(e) }
            entries = kept
        }
    }

    /// 更新某条目的状态说明（键入进度等）
    func setNote(_ note: String, for id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].note = note
    }

    func clear() { entries.removeAll() }
}
